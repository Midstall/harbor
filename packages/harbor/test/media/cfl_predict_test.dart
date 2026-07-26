@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/cfl_predict.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden = exact Dart copy of `_cflApply` + `_cflAlpha` from the SW
// reference tile decode (bd8, tw==cflW==width, th==cflH==height).

const _pixMax = 255; // bd8

int _clip(int v) => v < 0 ? 0 : (v > _pixMax ? _pixMax : v);

int _roundSigned(int v, int n) =>
    v >= 0 ? (v + (1 << (n - 1))) >> n : -((-v + (1 << (n - 1))) >> n);

int _log2(int v) {
  var n = 0;
  while ((1 << n) < v) {
    n++;
  }
  return n;
}

int _cflAlpha(int idx, int js, int predType) {
  final signU = (js + 1) ~/ 3, signV = (js + 1) - 3 * signU;
  final sign = predType == 0 ? signU : signV;
  if (sign == 0) return 0;
  final absA = predType == 0 ? (idx >> 4) : (idx & 0xf);
  return sign == 2 ? absA + 1 : -absA - 1;
}

List<int> _cflApply(
  List<int> dcPred,
  List<int> recon,
  int w,
  int h,
  int alphaIdx,
  int signs,
  int plane,
) {
  // plane here is predType directly (0=>U, 1=>V) per the module spec
  // (the SW passes plane-1, here we pass predType to _cflAlpha).
  final pred = List<int>.from(dcPred);
  final cflW = w, cflH = h, tw = w, th = h;
  final numPel = _log2(cflW) + _log2(cflH);
  var sum = 1 << (numPel - 1);
  for (var i = 0; i < cflW * cflH; i++) {
    sum += recon[i];
  }
  final avg = sum >> numPel;
  final alpha = _cflAlpha(alphaIdx, signs, plane);
  for (var j = 0; j < th && j < cflH; j++) {
    for (var i = 0; i < tw && i < cflW; i++) {
      final ac = recon[j * cflW + i] - avg;
      final scaled = _roundSigned(alpha * ac, 6);
      pred[j * tw + i] = _clip(scaled + pred[j * tw + i]);
    }
  }
  return pred;
}

BigInt _pack(List<int> block) {
  var packed = BigInt.zero;
  for (var i = 0; i < block.length; i++) {
    packed |= BigInt.from(block[i]) << (i * 8);
  }
  return packed;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final dim in [
    [8, 8],
    [4, 4],
    [16, 16],
    [4, 8],
    [8, 4],
  ]) {
    final w = dim[0], h = dim[1];
    test('HarborCflPredict matches _cflApply (w=$w h=$h)', () async {
      final dut = HarborCflPredict(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;
      final dcPred = Logic(name: 'dc_pred', width: w * h * 8);
      final recon = Logic(name: 'recon', width: w * h * 8);
      final alphaIdx = Logic(name: 'alpha_idx', width: 8);
      final signs = Logic(name: 'signs', width: 3);
      final plane = Logic(name: 'plane', width: 1);
      dut.input('dc_pred').srcConnection! <= dcPred;
      dut.input('recon').srcConnection! <= recon;
      dut.input('alpha_idx').srcConnection! <= alphaIdx;
      dut.input('signs').srcConnection! <= signs;
      dut.input('plane').srcConnection! <= plane;
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      final rng = Random(0xCF + w * 100 + h);
      for (var iter = 0; iter < 400; iter++) {
        final dc = [for (var i = 0; i < w * h; i++) rng.nextInt(256)];
        final rc = [for (var i = 0; i < w * h; i++) rng.nextInt(256)];
        final idx = rng.nextInt(256);
        final sg = rng.nextInt(8);
        final pl = rng.nextInt(2);

        dcPred.put(_pack(dc));
        recon.put(_pack(rc));
        alphaIdx.put(idx);
        signs.put(sg);
        plane.put(pl);
        await clk.nextPosedge;

        final gold = _cflApply(dc, rc, w, h, idx, sg, pl);
        final out = dut.output('pred').value;
        for (var k = 0; k < w * h; k++) {
          expect(
            out.getRange(k * 8, k * 8 + 8).toInt(),
            equals(gold[k]),
            reason: 'w=$w h=$h iter=$iter k=$k idx=$idx sg=$sg pl=$pl',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }
}
