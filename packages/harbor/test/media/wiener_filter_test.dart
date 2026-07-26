import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 Wiener convolve stages (libaom _wienerConvolve), bd8.
const _filterBits = 7;
const _round0 = 3;
const _round1 = 11;
const _clampLimit = 8192;

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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborWienerHorz matches round_0 pass', () async {
    final h = HarborWienerHorz();
    final clk = SimpleClockGenerator(10).clk;
    final line = Logic(name: 'line', width: 7 * 8);
    final t0 = Logic(name: 't0', width: 8);
    final t1 = Logic(name: 't1', width: 8);
    final t2 = Logic(name: 't2', width: 8);
    h.input('line').srcConnection! <= line;
    h.input('t0').srcConnection! <= t0;
    h.input('t1').srcConnection! <= t1;
    h.input('t2').srcConnection! <= t2;
    await h.build();
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    final rng = Random(0x1AA1);
    for (var iter = 0; iter < 1000; iter++) {
      final p = [for (var i = 0; i < 7; i++) rng.nextInt(256)];
      final a = rng.nextInt(16) - 5,
          b = rng.nextInt(32) - 23,
          c = rng.nextInt(64) - 17;
      var packed = BigInt.zero;
      for (var i = 0; i < 7; i++) {
        packed |= BigInt.from(p[i]) << (i * 8);
      }
      line.put(packed);
      t0.put(a & 0xFF);
      t1.put(b & 0xFF);
      t2.put(c & 0xFF);
      await clk.nextPosedge;
      expect(
        h.output('mid').value.toInt(),
        equals(_horz(p, a, b, c)),
        reason: 'iter=$iter p=$p t=$a,$b,$c',
      );
    }
    await Simulator.endSimulation();
  });

  test('HarborWienerVert matches round_1 pass', () async {
    final v = HarborWienerVert();
    final clk = SimpleClockGenerator(10).clk;
    final col = Logic(name: 'col', width: 7 * 14);
    final t0 = Logic(name: 't0', width: 8);
    final t1 = Logic(name: 't1', width: 8);
    final t2 = Logic(name: 't2', width: 8);
    v.input('col').srcConnection! <= col;
    v.input('t0').srcConnection! <= t0;
    v.input('t1').srcConnection! <= t1;
    v.input('t2').srcConnection! <= t2;
    await v.build();
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    final rng = Random(0x2BB2);
    for (var iter = 0; iter < 1000; iter++) {
      final m = [for (var i = 0; i < 7; i++) rng.nextInt(8192)];
      final a = rng.nextInt(16) - 5,
          b = rng.nextInt(32) - 23,
          c = rng.nextInt(64) - 17;
      var packed = BigInt.zero;
      for (var i = 0; i < 7; i++) {
        packed |= BigInt.from(m[i]) << (i * 14);
      }
      col.put(packed);
      t0.put(a & 0xFF);
      t1.put(b & 0xFF);
      t2.put(c & 0xFF);
      await clk.nextPosedge;
      expect(
        v.output('out').value.toInt(),
        equals(_vert(m, a, b, c)),
        reason: 'iter=$iter m=$m t=$a,$b,$c',
      );
    }
    await Simulator.endSimulation();
  });
}
