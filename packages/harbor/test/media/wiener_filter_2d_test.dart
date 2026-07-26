import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 Wiener convolve (libaom _wienerConvolve), bd8: round_0
// horizontal (clamp [0, 8191]) then round_1 vertical (clip [0, 255]).
const _filterBits = 7;
const _round0 = 3;
const _round1 = 11; // 2*7 - 3
const _clampLimit = 8192; // 1 << (8 + 1 + 7 - 3)

int _horz(List<int> p, int t0, int t1, int t2) {
  final tc = -2 * (t0 + t1 + t2);
  final sum =
      t0 * (p[0] + p[6]) + t1 * (p[1] + p[5]) + t2 * (p[2] + p[4]) + tc * p[3];
  final rounding = (p[3] << _filterBits) + (1 << (8 + _filterBits - 1));
  var val = (sum + rounding + (1 << (_round0 - 1))) >> _round0;
  if (val < 0) val = 0;
  if (val > _clampLimit - 1) val = _clampLimit - 1;
  return val;
}

int _vert(List<int> m, int t0, int t1, int t2) {
  final tc = -2 * (t0 + t1 + t2);
  final sum =
      t0 * (m[0] + m[6]) + t1 * (m[1] + m[5]) + t2 * (m[2] + m[4]) + tc * m[3];
  final rounding = (m[3] << _filterBits) - (1 << (8 + _round1 - 1));
  final val = (sum + rounding + (1 << (_round1 - 1))) >> _round1;
  return val < 0 ? 0 : (val > 255 ? 255 : val);
}

int _wiener2d(List<List<int>> r, List<int> h, List<int> v) {
  final mid = [
    for (var row = 0; row < 7; row++) _horz(r[row], h[0], h[1], h[2]),
  ];
  return _vert(mid, v[0], v[1], v[2]);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborWienerFilter2D', () {
    late HarborWienerFilter2D wf;
    late Logic clk, region, h0, h1, h2, v0, v1, v2;

    Future<void> setUpDut() async {
      wf = HarborWienerFilter2D();
      clk = SimpleClockGenerator(10).clk;
      region = Logic(name: 'region', width: 7 * 7 * 8);
      h0 = Logic(name: 'h0', width: 8);
      h1 = Logic(name: 'h1', width: 8);
      h2 = Logic(name: 'h2', width: 8);
      v0 = Logic(name: 'v0', width: 8);
      v1 = Logic(name: 'v1', width: 8);
      v2 = Logic(name: 'v2', width: 8);
      wf.input('region').srcConnection! <= region;
      wf.input('h0').srcConnection! <= h0;
      wf.input('h1').srcConnection! <= h1;
      wf.input('h2').srcConnection! <= h2;
      wf.input('v0').srcConnection! <= v0;
      wf.input('v1').srcConnection! <= v1;
      wf.input('v2').srcConnection! <= v2;
      await wf.build();
      region.inject(0);
      for (final t in [h0, h1, h2, v0, v1, v2]) {
        t.inject(0);
      }
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packRegion(List<List<int>> r) {
      var pv = BigInt.zero;
      for (var i = 0; i < 7; i++) {
        for (var j = 0; j < 7; j++) {
          pv |= BigInt.from(r[i][j] & 0xFF) << ((i * 7 + j) * 8);
        }
      }
      return pv;
    }

    // (name, region-builder, h-taps, v-taps).
    final cases = <(String, List<List<int>>, List<int>, List<int>)>[
      (
        'identity (taps 0)',
        [
          for (var i = 0; i < 7; i++)
            [for (var j = 0; j < 7; j++) 40 + i * 7 + j],
        ],
        [0, 0, 0],
        [0, 0, 0],
      ),
      (
        'sharpen both axes',
        [
          for (var i = 0; i < 7; i++)
            [for (var j = 0; j < 7; j++) 60 + (i * 11 + j * 5) % 90],
        ],
        [-5, 12, -20],
        [-3, 9, -15],
      ),
      (
        'diagonal edge',
        [
          for (var i = 0; i < 7; i++)
            [for (var j = 0; j < 7; j++) (i + j) < 6 ? 50 : 200],
        ],
        [-2, 8, -14],
        [-2, 8, -14],
      ),
      (
        'flat field',
        [
          for (var i = 0; i < 7; i++) [for (var j = 0; j < 7; j++) 128],
        ],
        [-4, 10, -16],
        [4, -6, 10],
      ),
      (
        'clamps high',
        [
          for (var i = 0; i < 7; i++)
            [for (var j = 0; j < 7; j++) 240 + (i + j) % 16],
        ],
        [0, 20, 30],
        [0, 18, 24],
      ),
    ];

    for (final c in cases) {
      test('matches the reference: ${c.$1}', () async {
        await setUpDut();
        region.inject(packRegion(c.$2));
        h0.inject(c.$3[0] & 0xFF);
        h1.inject(c.$3[1] & 0xFF);
        h2.inject(c.$3[2] & 0xFF);
        v0.inject(c.$4[0] & 0xFF);
        v1.inject(c.$4[1] & 0xFF);
        v2.inject(c.$4[2] & 0xFF);
        await clk.nextPosedge;
        final got = wf.output('out').value.toInt();
        expect(got, equals(_wiener2d(c.$2, c.$3, c.$4)), reason: c.$1);
        await Simulator.endSimulation();
      });
    }

    test('matches the reference on random regions/taps', () async {
      await setUpDut();
      final rng = Random(0x71E9E5);
      // Valid AV1 Wiener tap ranges: [-5,10], [-23,8], [-17,46].
      int t0() => rng.nextInt(16) - 5;
      int t1() => rng.nextInt(32) - 23;
      int t2() => rng.nextInt(64) - 17;
      for (var iter = 0; iter < 400; iter++) {
        final r = [
          for (var i = 0; i < 7; i++)
            [for (var j = 0; j < 7; j++) rng.nextInt(256)],
        ];
        final h = [t0(), t1(), t2()];
        final v = [t0(), t1(), t2()];
        region.inject(packRegion(r));
        h0.inject(h[0] & 0xFF);
        h1.inject(h[1] & 0xFF);
        h2.inject(h[2] & 0xFF);
        v0.inject(v[0] & 0xFF);
        v1.inject(v[1] & 0xFF);
        v2.inject(v[2] & 0xFF);
        await clk.nextPosedge;
        expect(
          wf.output('out').value.toInt(),
          equals(_wiener2d(r, h, v)),
          reason: 'iter=$iter h=$h v=$v',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
