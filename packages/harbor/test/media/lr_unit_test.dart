import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 loop-restoration unit dispatch (libaom restoration.c):
//   rtype 0 (RESTORE_NONE)    -> copy post-CDEF body pixels through unchanged.
//   rtype 1 (RESTORE_WIENER)  -> _wienerConvolve (round_0 horz then round_1 vert).
//   rtype 2 (RESTORE_SGRPROJ) -> _sgrProcUnit (fast+full passes then projection).
//
// Geometry: an 8x8 output block over a 14x14 padded source region (body (0,0)
// at padded (3,3)), packed row-major LSB-first 8b pixels, the same convention
// HarborSgrProcUnit uses. Wiener output (i,j) is the centre of the 7x7 window
// whose pixel (r,c) is padded (i+r, j+c).

const _width = 8;
const _height = 8;
const _pw = _width + 6; // 14
const _ph = _height + 6; // 14

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

int _wiener2d(List<List<int>> r, List<int> h, List<int> v) {
  final mid = [
    for (var row = 0; row < 7; row++) _horz(r[row], h[0], h[1], h[2]),
  ];
  return _vert(mid, v[0], v[1], v[2]);
}

int _round2(int x, int n) => (x + (1 << (n - 1))) >> n;
int _clip255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

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

List<int> _goldLr(
  List<int> padded,
  int rtype,
  List<int> h,
  List<int> v,
  int s0,
  int s1,
  int xq0,
  int xq1,
) {
  if (rtype == 0) {
    // RESTORE_NONE: copy post-CDEF body pixel (i+3, j+3) through.
    final out = <int>[];
    for (var i = 0; i < _height; i++) {
      for (var j = 0; j < _width; j++) {
        out.add(padded[(i + 3) * _pw + (j + 3)]);
      }
    }
    return out;
  } else if (rtype == 1) {
    // RESTORE_WIENER: output (i,j) is the Wiener centre of the 7x7 window
    // whose pixel (r,c) is padded (i+r, j+c).
    final out = <int>[];
    for (var i = 0; i < _height; i++) {
      for (var j = 0; j < _width; j++) {
        final win = [
          for (var r = 0; r < 7; r++)
            [for (var c = 0; c < 7; c++) padded[(i + r) * _pw + (j + c)]],
        ];
        out.add(_wiener2d(win, h, v));
      }
    }
    return out;
  } else {
    return _goldProc(padded, _width, _height, s0, s1, xq0, xq1);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborLrUnit dispatches NONE/WIENER/SGRPROJ bit-exact', () async {
    final unit = HarborLrUnit(width: _width, height: _height);
    final clk = SimpleClockGenerator(10).clk;
    final padded = Logic(name: 'padded', width: _pw * _ph * 8);
    final h0 = Logic(name: 'h0', width: 8);
    final h1 = Logic(name: 'h1', width: 8);
    final h2 = Logic(name: 'h2', width: 8);
    final v0 = Logic(name: 'v0', width: 8);
    final v1 = Logic(name: 'v1', width: 8);
    final v2 = Logic(name: 'v2', width: 8);
    final s0 = Logic(name: 's0', width: 12);
    final s1 = Logic(name: 's1', width: 12);
    final xq0 = Logic(name: 'xq0', width: 8);
    final xq1 = Logic(name: 'xq1', width: 8);
    final rtype = Logic(name: 'rtype', width: 2);

    unit.input('padded').srcConnection! <= padded;
    unit.input('h0').srcConnection! <= h0;
    unit.input('h1').srcConnection! <= h1;
    unit.input('h2').srcConnection! <= h2;
    unit.input('v0').srcConnection! <= v0;
    unit.input('v1').srcConnection! <= v1;
    unit.input('v2').srcConnection! <= v2;
    unit.input('s0').srcConnection! <= s0;
    unit.input('s1').srcConnection! <= s1;
    unit.input('xq0').srcConnection! <= xq0;
    unit.input('xq1').srcConnection! <= xq1;
    unit.input('rtype').srcConnection! <= rtype;
    await unit.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    final rng = Random(0xA11);
    final sVals = [25, 56, 95, 140, 169, 200, 925, 1618, 2589, 3236];
    final xq0Vals = [-96, -64, -32, 0, 16, 31];
    final xq1Vals = [-32, 0, 16, 48, 95];
    // Wiener tap ranges: [-5,10], [-23,8], [-17,46].
    int wt0() => rng.nextInt(16) - 5;
    int wt1() => rng.nextInt(32) - 23;
    int wt2() => rng.nextInt(64) - 17;

    for (final rt in [0, 1, 2]) {
      for (var iter = 0; iter < 8; iter++) {
        final px = [for (var i = 0; i < _pw * _ph; i++) rng.nextInt(256)];
        final h = [wt0(), wt1(), wt2()];
        final vt = [wt0(), wt1(), wt2()];
        final sv0 = sVals[rng.nextInt(sVals.length)];
        final sv1 = sVals[rng.nextInt(sVals.length)];
        final x0 = xq0Vals[rng.nextInt(xq0Vals.length)];
        final x1 = xq1Vals[rng.nextInt(xq1Vals.length)];

        var packed = BigInt.zero;
        for (var i = 0; i < px.length; i++) {
          packed |= BigInt.from(px[i]) << (i * 8);
        }
        padded.put(packed);
        h0.put(BigInt.from(h[0]).toUnsigned(8));
        h1.put(BigInt.from(h[1]).toUnsigned(8));
        h2.put(BigInt.from(h[2]).toUnsigned(8));
        v0.put(BigInt.from(vt[0]).toUnsigned(8));
        v1.put(BigInt.from(vt[1]).toUnsigned(8));
        v2.put(BigInt.from(vt[2]).toUnsigned(8));
        s0.put(sv0);
        s1.put(sv1);
        xq0.put(BigInt.from(x0).toUnsigned(8));
        xq1.put(BigInt.from(x1).toUnsigned(8));
        rtype.put(rt);
        await clk.nextPosedge;

        final gold = _goldLr(px, rt, h, vt, sv0, sv1, x0, x1);
        final out = unit.output('out').value;
        for (var k = 0; k < _width * _height; k++) {
          expect(
            out.getRange(k * 8, k * 8 + 8).toInt(),
            equals(gold[k]),
            reason: 'rtype=$rt iter=$iter k=$k',
          );
        }
      }
    }
    await Simulator.endSimulation();
  });
}
