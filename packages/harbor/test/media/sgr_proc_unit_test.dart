import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 SGR restoration unit (libaom _sgrProcUnit), bd8:
//   flt0 = fast cross-sum, radius 2, flt1 = full cross-sum, radius 1,
//   out  = project(pre, flt0, flt1, xq0, xq1).
int _round2(int x, int n) => (x + (1 << (n - 1))) >> n;
int _clip255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// Per-pixel A/B grid over a padded region with body (0,0) at padded (r+1,r+1).
({List<List<int>> a, List<List<int>> b}) _ab(
  List<int> padded,
  int pw,
  int r,
  int width,
  int height,
  int s,
) {
  final gw = width + 2, gh = height + 2;
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
  return (a: a, b: b);
}

List<int> _goldFast(
  List<int> padded,
  int pw,
  int r,
  int width,
  int height,
  int s,
) {
  final g = _ab(padded, pw, r, width, height, s);
  final a = g.a, b = g.b;
  final out = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      int ag(int dr, int dc) => a[i + dr][j + dc];
      int bg(int dr, int dc) => b[i + dr][j + dc];
      final center = padded[(i + r + 1) * pw + (j + r + 1)];
      if (i.isEven) {
        final av =
            (ag(0, 1) + ag(2, 1)) * 6 +
            (ag(0, 0) + ag(0, 2) + ag(2, 0) + ag(2, 2)) * 5;
        final bv =
            (bg(0, 1) + bg(2, 1)) * 6 +
            (bg(0, 0) + bg(0, 2) + bg(2, 0) + bg(2, 2)) * 5;
        out.add(_round2(av * center + bv, 9));
      } else {
        final av = ag(1, 1) * 6 + (ag(1, 0) + ag(1, 2)) * 5;
        final bv = bg(1, 1) * 6 + (bg(1, 0) + bg(1, 2)) * 5;
        out.add(_round2(av * center + bv, 8));
      }
    }
  }
  return out;
}

List<int> _goldFull(
  List<int> padded,
  int pw,
  int r,
  int width,
  int height,
  int s,
) {
  final g = _ab(padded, pw, r, width, height, s);
  final a = g.a, b = g.b;
  final out = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      int ag(int dr, int dc) => a[i + dr][j + dc];
      int bg(int dr, int dc) => b[i + dr][j + dc];
      final av =
          (ag(1, 1) + ag(1, 0) + ag(1, 2) + ag(0, 1) + ag(2, 1)) * 4 +
          (ag(0, 0) + ag(0, 2) + ag(2, 0) + ag(2, 2)) * 3;
      final bv =
          (bg(1, 1) + bg(1, 0) + bg(1, 2) + bg(0, 1) + bg(2, 1)) * 4 +
          (bg(0, 0) + bg(0, 2) + bg(2, 0) + bg(2, 2)) * 3;
      final center = padded[(i + r + 1) * pw + (j + r + 1)];
      out.add(_round2(av * center + bv, 9));
    }
  }
  return out;
}

List<int> _goldProc(
  List<int> padded,
  int width,
  int height,
  int s0,
  int s1,
  int xq0,
  int xq1,
) {
  final pw = width + 6;
  final flt0 = _goldFast(padded, pw, 2, width, height, s0);
  // flt1: radius-1 full pass over the inner (width+4)x(height+4) sub-region.
  final sw = width + 4, sh = height + 4;
  final sub = <int>[
    for (var r = 1; r < 1 + sh; r++)
      for (var c = 1; c < 1 + sw; c++) padded[r * pw + c],
  ];
  final flt1 = _goldFull(sub, sw, 1, width, height, s1);
  final out = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      final k = i * width + j;
      final pre = padded[(i + 3) * pw + (j + 3)];
      final u = pre << 4;
      var v = pre << 11;
      v += xq0 * (flt0[k] - u);
      v += xq1 * (flt1[k] - u);
      out.add(_clip255(_round2(v, 11)));
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborSgrProcUnit matches libaom _sgrProcUnit', () async {
    const width = 8, height = 8;
    final pw = width + 6, ph = height + 6;
    final unit = HarborSgrProcUnit(width: width, height: height);
    final clk = SimpleClockGenerator(10).clk;
    final padded = Logic(name: 'padded', width: pw * ph * 8);
    final s0 = Logic(name: 's0', width: 12);
    final s1 = Logic(name: 's1', width: 12);
    final xq0 = Logic(name: 'xq0', width: 8);
    final xq1 = Logic(name: 'xq1', width: 8);
    unit.input('padded').srcConnection! <= padded;
    unit.input('s0').srcConnection! <= s0;
    unit.input('s1').srcConnection! <= s1;
    unit.input('xq0').srcConnection! <= xq0;
    unit.input('xq1').srcConnection! <= xq1;
    await unit.build();
    Simulator.setMaxSimTime(240000000);
    unawaited(Simulator.run());

    final rng = Random(0x59C);
    final sVals = [25, 56, 95, 140, 169, 200, 925, 1618, 2589, 3236];
    // decode_xq weight ranges: xq0 in [-96,31], xq1 in [-32,95], plus disabled.
    final xq0Vals = [-96, -64, -32, 0, 16, 31];
    final xq1Vals = [-32, 0, 16, 48, 95];
    for (var iter = 0; iter < 14; iter++) {
      final px = [for (var i = 0; i < pw * ph; i++) rng.nextInt(256)];
      final sv0 = sVals[rng.nextInt(sVals.length)];
      final sv1 = sVals[rng.nextInt(sVals.length)];
      final x0 = xq0Vals[rng.nextInt(xq0Vals.length)];
      final x1 = xq1Vals[rng.nextInt(xq1Vals.length)];
      var packed = BigInt.zero;
      for (var i = 0; i < px.length; i++) {
        packed |= BigInt.from(px[i]) << (i * 8);
      }
      padded.put(packed);
      s0.put(sv0);
      s1.put(sv1);
      xq0.put(BigInt.from(x0).toUnsigned(8));
      xq1.put(BigInt.from(x1).toUnsigned(8));
      await clk.nextPosedge;
      final gold = _goldProc(px, width, height, sv0, sv1, x0, x1);
      final out = unit.output('out').value;
      for (var k = 0; k < width * height; k++) {
        expect(
          out.getRange(k * 8, k * 8 + 8).toInt(),
          equals(gold[k]),
          reason: 'iter=$iter s0=$sv0 s1=$sv1 xq0=$x0 xq1=$x1 k=$k',
        );
      }
    }
    await Simulator.endSimulation();
  });
}
