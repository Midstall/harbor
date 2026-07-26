@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/compound_blend.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact goldens copied from the SW reference tile decoder, bd8.
//
// CONV_BUF d16 semantics: each prediction is a 16-bit intermediate value
// res = roundOffset(6144) + (signed prediction in the DIST domain). The combine
// subtracts roundOffset, rounds by roundBits=4 and clips to [0,255]. We sweep
// res over a realistic band [0, 16383] that covers the libaom bd8 CONV_BUF
// range and forces clipping at both ends (negative-after-offset and overshoot).

const _offsetBits = 19, _round1 = 7;
const _roundOffset =
    (1 << (_offsetBits - _round1)) + (1 << (_offsetBits - _round1 - 1)); // 6144
const _roundBits = 2 * 7 - 3 - _round1; // 4

int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// _avgDistWtdBlend for a single pixel. useDistWtd!=0 uses fwd/bck weights,
// else plain average.
int _goldAvgDistWtd(
  int src0,
  int src1,
  int fwdOff,
  int bckOff,
  int useDistWtd,
) {
  int tmp;
  if (useDistWtd != 0) {
    tmp = (src0 * fwdOff + src1 * bckOff) >> 4;
  } else {
    tmp = (src0 + src1) >> 1;
  }
  tmp -= _roundOffset;
  return _clip((tmp + (1 << (_roundBits - 1))) >> _roundBits);
}

// _maskedBlend for a single pixel given the already-resolved 6-bit mask m.
int _goldMaskBlend(int src0, int src1, int m) {
  var res = (m * src0 + (64 - m) * src1) >> 6;
  res -= _roundOffset;
  return _clip((res + (1 << (_roundBits - 1))) >> _roundBits);
}

// _diffwtdMask for a single pixel.
int _goldDiffwtd(int src0, int src1, int type) {
  const round = 2 * 7 - 3 - 7 + 0; // 4
  var diff = (src0 - src1).abs();
  diff = (diff + (1 << (round - 1))) >> round;
  var m = 38 + (diff >> 4);
  if (m < 0) m = 0;
  if (m > 64) m = 64;
  return type != 0 ? 64 - m : m;
}

BigInt _pack(List<int> vals, int bits) {
  var packed = BigInt.zero;
  for (var i = 0; i < vals.length; i++) {
    packed |= BigInt.from(vals[i]) << (i * bits);
  }
  return packed;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Realistic dist-weight pairs (fwd,bck) sum to 16: average {8,8} plus the
  // av1 dist-wtd LUT entries.
  const weightPairs = [
    [8, 8],
    [9, 7],
    [11, 5],
    [12, 4],
    [13, 3],
    [7, 9],
    [5, 11],
    [4, 12],
    [3, 13],
  ];

  test('HarborCompoundBlend average/dist-wtd + mask blend bit-exact', () async {
    const w = 8, h = 8, n = w * h;
    final blend = HarborCompoundBlend(width: w, height: h);
    final clk = SimpleClockGenerator(10).clk;

    final src0 = Logic(name: 'src0', width: n * 16);
    final src1 = Logic(name: 'src1', width: n * 16);
    final mask = Logic(name: 'mask', width: n * 7);
    final fwd = Logic(name: 'fwd', width: 5);
    final bck = Logic(name: 'bck', width: 5);
    final useDistWtd = Logic(name: 'useDistWtd');
    final mode = Logic(name: 'mode', width: 2);

    blend.input('src0').srcConnection! <= src0;
    blend.input('src1').srcConnection! <= src1;
    blend.input('mask').srcConnection! <= mask;
    blend.input('fwd').srcConnection! <= fwd;
    blend.input('bck').srcConnection! <= bck;
    blend.input('use_dist_wtd').srcConnection! <= useDistWtd;
    blend.input('mode').srcConnection! <= mode;
    await blend.build();
    Simulator.setMaxSimTime(200000000);
    unawaited(Simulator.run());

    final rng = Random(0xC0FFEE);
    var passes = 0;
    for (var iter = 0; iter < 600; iter++) {
      final s0 = [for (var i = 0; i < n; i++) rng.nextInt(16384)];
      final s1 = [for (var i = 0; i < n; i++) rng.nextInt(16384)];
      final mk = [for (var i = 0; i < n; i++) rng.nextInt(65)]; // 0..64
      final wp = weightPairs[rng.nextInt(weightPairs.length)];
      // mode: 0=avg/dist-wtd, 1=mask blend.
      final selMask = rng.nextBool();
      final udw = rng.nextBool();

      src0.put(_pack(s0, 16));
      src1.put(_pack(s1, 16));
      mask.put(_pack(mk, 7));
      fwd.put(wp[0]);
      bck.put(wp[1]);
      useDistWtd.put(udw ? 1 : 0);
      mode.put(selMask ? 1 : 0);
      await clk.nextPosedge;

      final outv = blend.output('out').value;
      for (var k = 0; k < n; k++) {
        final got = outv.getRange(k * 8, k * 8 + 8).toInt();
        final exp = selMask
            ? _goldMaskBlend(s0[k], s1[k], mk[k])
            : _goldAvgDistWtd(s0[k], s1[k], wp[0], wp[1], udw ? 1 : 0);
        expect(
          got,
          equals(exp),
          reason:
              'iter=$iter k=$k mask=$selMask udw=$udw '
              'src0=${s0[k]} src1=${s1[k]} m=${mk[k]} wp=$wp',
        );
        passes++;
      }
    }
    print('compound blend checks passed: $passes');
    await Simulator.endSimulation();
  });

  test('HarborDiffwtdMask bit-exact vs _diffwtdMask', () async {
    const w = 8, h = 8, n = w * h;
    final dm = HarborDiffwtdMask(width: w, height: h);
    final clk = SimpleClockGenerator(10).clk;

    final src0 = Logic(name: 'src0', width: n * 16);
    final src1 = Logic(name: 'src1', width: n * 16);
    final type = Logic(name: 'type');

    dm.input('src0').srcConnection! <= src0;
    dm.input('src1').srcConnection! <= src1;
    dm.input('inv_type').srcConnection! <= type;
    await dm.build();
    Simulator.setMaxSimTime(200000000);
    unawaited(Simulator.run());

    final rng = Random(0xD1FF);
    var passes = 0;
    for (var iter = 0; iter < 600; iter++) {
      final s0 = [for (var i = 0; i < n; i++) rng.nextInt(16384)];
      final s1 = [for (var i = 0; i < n; i++) rng.nextInt(16384)];
      final ty = rng.nextBool();

      src0.put(_pack(s0, 16));
      src1.put(_pack(s1, 16));
      type.put(ty ? 1 : 0);
      await clk.nextPosedge;

      final outv = dm.output('mask').value;
      for (var k = 0; k < n; k++) {
        final got = outv.getRange(k * 7, k * 7 + 7).toInt();
        final exp = _goldDiffwtd(s0[k], s1[k], ty ? 1 : 0);
        expect(
          got,
          equals(exp),
          reason: 'iter=$iter k=$k type=$ty s0=${s0[k]} s1=${s1[k]}',
        );
        passes++;
      }
    }
    print('diffwtd mask checks passed: $passes');
    await Simulator.endSimulation();
  });
}
