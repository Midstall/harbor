import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 SGR full pass (libaom _sgrFull): boxsum -> calc_ab -> cross-sum
// (mode 0), bd8. The golden mirrors HarborSgrPass over the padded region using
// the same public LUTs the hardware bakes in.
int _round2(int x, int n) => (x + (1 << (n - 1))) >> n;

List<int> _goldFull(List<int> padded, int r, int width, int height, int s) {
  final gw = width + 2, gh = height + 2;
  final pw = width + 2 * (r + 1);
  final win = 2 * r + 1;
  final n = win * win;
  final recip = HarborSgrCalcAb.oneByX[n - 1];

  int padAt(int row, int col) => padded[row * pw + col];

  // A/B grid over positions (ci,cj). Grid (ci,cj) box window = padded rows
  // ci..ci+2r, cols cj..cj+2r (matches HarborSgrBoxsum body of gw x gh).
  final a = List.generate(gh, (_) => List<int>.filled(gw, 0));
  final b = List.generate(gh, (_) => List<int>.filled(gw, 0));
  for (var ci = 0; ci < gh; ci++) {
    for (var cj = 0; cj < gw; cj++) {
      var av = 0, bv = 0;
      for (var dr = 0; dr < win; dr++) {
        for (var dc = 0; dc < win; dc++) {
          final p = padAt(ci + dr, cj + dc);
          bv += p;
          av += p * p;
        }
      }
      final pp = (av * n < bv * bv) ? 0 : av * n - bv * bv;
      final z = _round2(pp * s, 20);
      final ai = HarborSgrCalcAb.xByXPlus1[z > 255 ? 255 : z];
      a[ci][cj] = ai;
      b[ci][cj] = _round2((256 - ai) * bv * recip, 12);
    }
  }

  final out = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      // 3x3 neighbourhood = grid (i..i+2, j..j+2), centre grid (i+1,j+1).
      int ag(int dr, int dc) => a[i + dr][j + dc];
      int bg(int dr, int dc) => b[i + dr][j + dc];
      final av =
          (ag(1, 1) + ag(1, 0) + ag(1, 2) + ag(0, 1) + ag(2, 1)) * 4 +
          (ag(0, 0) + ag(0, 2) + ag(2, 0) + ag(2, 2)) * 3;
      final bv =
          (bg(1, 1) + bg(1, 0) + bg(1, 2) + bg(0, 1) + bg(2, 1)) * 4 +
          (bg(0, 0) + bg(0, 2) + bg(2, 0) + bg(2, 2)) * 3;
      final center = padAt(i + r + 1, j + r + 1);
      final v = av * center + bv;
      out.add(_round2(v, 9));
    }
  }
  return out;
}

List<int> _goldFast(List<int> padded, int r, int width, int height, int s) {
  final gw = width + 2, gh = height + 2;
  final pw = width + 2 * (r + 1);
  final win = 2 * r + 1;
  final n = win * win;
  final recip = HarborSgrCalcAb.oneByX[n - 1];

  int padAt(int row, int col) => padded[row * pw + col];

  final a = List.generate(gh, (_) => List<int>.filled(gw, 0));
  final b = List.generate(gh, (_) => List<int>.filled(gw, 0));
  for (var ci = 0; ci < gh; ci++) {
    for (var cj = 0; cj < gw; cj++) {
      var av = 0, bv = 0;
      for (var dr = 0; dr < win; dr++) {
        for (var dc = 0; dc < win; dc++) {
          final p = padAt(ci + dr, cj + dc);
          bv += p;
          av += p * p;
        }
      }
      final pp = (av * n < bv * bv) ? 0 : av * n - bv * bv;
      final z = _round2(pp * s, 20);
      final ai = HarborSgrCalcAb.xByXPlus1[z > 255 ? 255 : z];
      a[ci][cj] = ai;
      b[ci][cj] = _round2((256 - ai) * bv * recip, 12);
    }
  }

  final out = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      int ag(int dr, int dc) => a[i + dr][j + dc];
      int bg(int dr, int dc) => b[i + dr][j + dc];
      final center = padAt(i + r + 1, j + r + 1);
      if (i.isEven) {
        // mode 1: vertical neighbours, weights 6/5, nb 5.
        final av =
            (ag(0, 1) + ag(2, 1)) * 6 +
            (ag(0, 0) + ag(0, 2) + ag(2, 0) + ag(2, 2)) * 5;
        final bv =
            (bg(0, 1) + bg(2, 1)) * 6 +
            (bg(0, 0) + bg(0, 2) + bg(2, 0) + bg(2, 2)) * 5;
        out.add(_round2(av * center + bv, 9));
      } else {
        // mode 2: centre row only, weights 6/5, nb 4.
        final av = ag(1, 1) * 6 + (ag(1, 0) + ag(1, 2)) * 5;
        final bv = bg(1, 1) * 6 + (bg(1, 0) + bg(1, 2)) * 5;
        out.add(_round2(av * center + bv, 8));
      }
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final r in [1, 2]) {
    test('HarborSgrPass matches libaom _sgrFull (r=$r)', () async {
      const width = 8, height = 8;
      final pw = width + 2 * (r + 1);
      final ph = height + 2 * (r + 1);
      final pass = HarborSgrPass(radius: r, width: width, height: height);
      final clk = SimpleClockGenerator(10).clk;
      final padded = Logic(name: 'padded', width: pw * ph * 8);
      final s = Logic(name: 's', width: 12);
      pass.input('padded').srcConnection! <= padded;
      pass.input('s').srcConnection! <= s;
      await pass.build();
      Simulator.setMaxSimTime(120000000);
      unawaited(Simulator.run());

      final rng = Random(0x5A + r);
      // s values used by AV1 SGR params (a representative spread).
      final sVals = [0, 1, 9, 56, 95, 140, 169, 200, 255, 2047];
      for (var iter = 0; iter < 40; iter++) {
        final px = [for (var i = 0; i < pw * ph; i++) rng.nextInt(256)];
        final sv = sVals[rng.nextInt(sVals.length)];
        var packed = BigInt.zero;
        for (var i = 0; i < px.length; i++) {
          packed |= BigInt.from(px[i]) << (i * 8);
        }
        padded.put(packed);
        s.put(sv);
        await clk.nextPosedge;
        final gold = _goldFull(px, r, width, height, sv);
        final flt = pass.output('flt').value;
        for (var k = 0; k < width * height; k++) {
          expect(
            flt.getRange(k * 18, k * 18 + 18).toInt(),
            equals(gold[k]),
            reason: 'r=$r iter=$iter s=$sv k=$k',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }

  for (final r in [1, 2]) {
    test('HarborSgrPass matches libaom _sgrFast (r=$r)', () async {
      const width = 8, height = 8;
      final pw = width + 2 * (r + 1);
      final ph = height + 2 * (r + 1);
      final pass = HarborSgrPass(
        radius: r,
        width: width,
        height: height,
        fast: true,
      );
      final clk = SimpleClockGenerator(10).clk;
      final padded = Logic(name: 'padded', width: pw * ph * 8);
      final s = Logic(name: 's', width: 12);
      pass.input('padded').srcConnection! <= padded;
      pass.input('s').srcConnection! <= s;
      await pass.build();
      Simulator.setMaxSimTime(120000000);
      unawaited(Simulator.run());

      final rng = Random(0x77 + r);
      final sVals = [0, 1, 9, 56, 95, 140, 169, 200, 255, 2047];
      for (var iter = 0; iter < 40; iter++) {
        final px = [for (var i = 0; i < pw * ph; i++) rng.nextInt(256)];
        final sv = sVals[rng.nextInt(sVals.length)];
        var packed = BigInt.zero;
        for (var i = 0; i < px.length; i++) {
          packed |= BigInt.from(px[i]) << (i * 8);
        }
        padded.put(packed);
        s.put(sv);
        await clk.nextPosedge;
        final gold = _goldFast(px, r, width, height, sv);
        final flt = pass.output('flt').value;
        for (var k = 0; k < width * height; k++) {
          expect(
            flt.getRange(k * 18, k * 18 + 18).toInt(),
            equals(gold[k]),
            reason: 'fast r=$r iter=$iter s=$sv k=$k',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }
}
