import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 loop-restoration FRAME-WALK golden for the shipped scope:
//   a SINGLE horizontal stripe of N units (each width x height) tiled across a
//   plane region planeW = N*width by planeH = height. The stripe is treated as
//   an interior stripe (not first, not last in the plane), so both the above
//   and below stripe boundaries are active: the +/-RESTORATION_BORDER (=3) rows
//   outside the stripe are SWAPPED for the saved deblock boundary lines before
//   each unit is filtered (setup_processing_stripe_boundary), then the unit is
//   filtered by HarborLrUnit, then they would be swapped back (no-op here since
//   we rebuild each unit's padded region from scratch).
//
// Boundary-line context mapping (mirrors _setupStripeBoundary, CTX_VERT=2):
//   above: padded row 0 (body -3) -> ctx0, row 1 (body -2) -> ctx0,
//          row 2 (body -1) -> ctx1.
//   below: padded row height+3 (body height)   -> ctx0,
//          row height+4 (body height+1)        -> ctx1,
//          row height+5 (body height+2)        -> ctx1.
// Horizontal direction replicates at the plane edges (no swap), exactly as the
// padded plane buffer + boundary-line _col() replicate do.

const _width = 8;
const _height = 8;
const _units = 2;
const _planeW = _units * _width; // 16
const _planeH = _height; // 8
const _pw = _width + 6; // 14 padded unit width
const _ph = _height + 6; // 14 padded unit height
const _border = 3; // RESTORATION_BORDER

// Wiener golden (mirrors lr_unit_test.dart)
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

// SGR golden (mirrors lr_unit_test.dart)
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

// Per-unit dispatch golden over a single padded (14x14) region.
List<int> _goldUnit(
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
    final out = <int>[];
    for (var i = 0; i < _height; i++) {
      for (var j = 0; j < _width; j++) {
        out.add(padded[(i + 3) * _pw + (j + 3)]);
      }
    }
    return out;
  } else if (rtype == 1) {
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

// Horizontal replicate of a plane column index into [0, planeW).
int _hclamp(int c) => c < 0 ? 0 : (c >= _planeW ? _planeW - 1 : c);

// Build the (14x14) padded region for unit `u` from the plane body and the
// swapped-in boundary lines. Body rows come from `body` (height x planeW),
// border rows (-3..-1 and height..height+2) come from above/below lines with
// the CTX_VERT=2 context mapping.
List<int> _buildUnitPadded(
  List<List<int>> body,
  List<List<int>> above,
  List<List<int>> below,
  int u,
) {
  final padded = List<int>.filled(_pw * _ph, 0);
  for (var r = 0; r < _ph; r++) {
    final bodyRow = r - _border; // -3..height+2
    for (var c = 0; c < _pw; c++) {
      final planeCol = _hclamp(u * _width + c - _border);
      int val;
      if (bodyRow < 0) {
        // above boundary: rows -3,-2 -> ctx0, row -1 -> ctx1.
        final ctx = (bodyRow + _restCtxVert) <= 0 ? 0 : 1; // max(i+2,0)>0?
        val = above[ctx][planeCol];
      } else if (bodyRow >= _height) {
        // below boundary: row height -> ctx0, height+1,+2 -> ctx1.
        final i = bodyRow - _height; // 0,1,2
        final ctx = i < 1 ? 0 : 1; // min(i, CTX_VERT-1)
        val = below[ctx][planeCol];
      } else {
        val = body[bodyRow][planeCol];
      }
      padded[r * _pw + c] = val;
    }
  }
  return padded;
}

const _restCtxVert = 2;

// Whole golden frame-walk: returns restored plane (planeH x planeW) flattened
// row-major.
List<int> _goldWalk(
  List<List<int>> body,
  List<List<int>> above,
  List<List<int>> below,
  List<int> rtypes,
  List<List<int>> hf,
  List<List<int>> vf,
  List<int> s0,
  List<int> s1,
  List<int> xq0,
  List<int> xq1,
) {
  final out = List<int>.filled(_planeH * _planeW, 0);
  for (var u = 0; u < _units; u++) {
    final padded = _buildUnitPadded(body, above, below, u);
    final uo = _goldUnit(
      padded,
      rtypes[u],
      hf[u],
      vf[u],
      s0[u],
      s1[u],
      xq0[u],
      xq1[u],
    );
    for (var i = 0; i < _height; i++) {
      for (var j = 0; j < _width; j++) {
        out[i * _planeW + (u * _width + j)] = uo[i * _width + j];
      }
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborLrFrameWalk tiles a stripe of units bit-exact', () async {
    final walk = HarborLrFrameWalk(
      width: _width,
      height: _height,
      units: _units,
    );
    final clk = SimpleClockGenerator(10).clk;

    final body = Logic(name: 'body', width: _planeW * _planeH * 8);
    final above = Logic(name: 'above', width: _planeW * 2 * 8);
    final below = Logic(name: 'below', width: _planeW * 2 * 8);
    final rtypeP = [
      for (var u = 0; u < _units; u++) Logic(name: 'rt$u', width: 2),
    ];
    final h0 = [
      for (var u = 0; u < _units; u++) Logic(name: 'h0_$u', width: 8),
    ];
    final h1 = [
      for (var u = 0; u < _units; u++) Logic(name: 'h1_$u', width: 8),
    ];
    final h2 = [
      for (var u = 0; u < _units; u++) Logic(name: 'h2_$u', width: 8),
    ];
    final v0 = [
      for (var u = 0; u < _units; u++) Logic(name: 'v0_$u', width: 8),
    ];
    final v1 = [
      for (var u = 0; u < _units; u++) Logic(name: 'v1_$u', width: 8),
    ];
    final v2 = [
      for (var u = 0; u < _units; u++) Logic(name: 'v2_$u', width: 8),
    ];
    final s0 = [
      for (var u = 0; u < _units; u++) Logic(name: 's0_$u', width: 12),
    ];
    final s1 = [
      for (var u = 0; u < _units; u++) Logic(name: 's1_$u', width: 12),
    ];
    final xq0 = [
      for (var u = 0; u < _units; u++) Logic(name: 'xq0_$u', width: 8),
    ];
    final xq1 = [
      for (var u = 0; u < _units; u++) Logic(name: 'xq1_$u', width: 8),
    ];

    walk.input('body').srcConnection! <= body;
    walk.input('above').srcConnection! <= above;
    walk.input('below').srcConnection! <= below;
    for (var u = 0; u < _units; u++) {
      walk.input('rtype$u').srcConnection! <= rtypeP[u];
      walk.input('h0_$u').srcConnection! <= h0[u];
      walk.input('h1_$u').srcConnection! <= h1[u];
      walk.input('h2_$u').srcConnection! <= h2[u];
      walk.input('v0_$u').srcConnection! <= v0[u];
      walk.input('v1_$u').srcConnection! <= v1[u];
      walk.input('v2_$u').srcConnection! <= v2[u];
      walk.input('s0_$u').srcConnection! <= s0[u];
      walk.input('s1_$u').srcConnection! <= s1[u];
      walk.input('xq0_$u').srcConnection! <= xq0[u];
      walk.input('xq1_$u').srcConnection! <= xq1[u];
    }
    await walk.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    final rng = Random(0xF1A);
    final sVals = [25, 56, 95, 140, 169, 200, 925, 1618, 2589, 3236];
    final xq0Vals = [-96, -64, -32, 0, 16, 31];
    final xq1Vals = [-32, 0, 16, 48, 95];
    int wt0() => rng.nextInt(16) - 5;
    int wt1() => rng.nextInt(32) - 23;
    int wt2() => rng.nextInt(64) - 17;

    void putRows(Logic sig, List<List<int>> rows, int cols) {
      var packed = BigInt.zero;
      var k = 0;
      for (var r = 0; r < rows.length; r++) {
        for (var c = 0; c < cols; c++) {
          packed |= BigInt.from(rows[r][c]) << (k * 8);
          k++;
        }
      }
      sig.put(packed);
    }

    for (var iter = 0; iter < 6; iter++) {
      final bodyRows = [
        for (var r = 0; r < _planeH; r++)
          [for (var c = 0; c < _planeW; c++) rng.nextInt(256)],
      ];
      final aboveRows = [
        for (var ctx = 0; ctx < 2; ctx++)
          [for (var c = 0; c < _planeW; c++) rng.nextInt(256)],
      ];
      final belowRows = [
        for (var ctx = 0; ctx < 2; ctx++)
          [for (var c = 0; c < _planeW; c++) rng.nextInt(256)],
      ];
      final rtypes = [for (var u = 0; u < _units; u++) rng.nextInt(3)];
      final hf = [
        for (var u = 0; u < _units; u++) [wt0(), wt1(), wt2()],
      ];
      final vf = [
        for (var u = 0; u < _units; u++) [wt0(), wt1(), wt2()],
      ];
      final sv0 = [
        for (var u = 0; u < _units; u++) sVals[rng.nextInt(sVals.length)],
      ];
      final sv1 = [
        for (var u = 0; u < _units; u++) sVals[rng.nextInt(sVals.length)],
      ];
      final x0 = [
        for (var u = 0; u < _units; u++) xq0Vals[rng.nextInt(xq0Vals.length)],
      ];
      final x1 = [
        for (var u = 0; u < _units; u++) xq1Vals[rng.nextInt(xq1Vals.length)],
      ];

      putRows(body, bodyRows, _planeW);
      putRows(above, aboveRows, _planeW);
      putRows(below, belowRows, _planeW);
      for (var u = 0; u < _units; u++) {
        rtypeP[u].put(rtypes[u]);
        h0[u].put(BigInt.from(hf[u][0]).toUnsigned(8));
        h1[u].put(BigInt.from(hf[u][1]).toUnsigned(8));
        h2[u].put(BigInt.from(hf[u][2]).toUnsigned(8));
        v0[u].put(BigInt.from(vf[u][0]).toUnsigned(8));
        v1[u].put(BigInt.from(vf[u][1]).toUnsigned(8));
        v2[u].put(BigInt.from(vf[u][2]).toUnsigned(8));
        s0[u].put(sv0[u]);
        s1[u].put(sv1[u]);
        xq0[u].put(BigInt.from(x0[u]).toUnsigned(8));
        xq1[u].put(BigInt.from(x1[u]).toUnsigned(8));
      }
      await clk.nextPosedge;

      final gold = _goldWalk(
        bodyRows,
        aboveRows,
        belowRows,
        rtypes,
        hf,
        vf,
        sv0,
        sv1,
        x0,
        x1,
      );
      final out = walk.output('out').value;
      for (var k = 0; k < _planeW * _planeH; k++) {
        expect(
          out.getRange(k * 8, k * 8 + 8).toInt(),
          equals(gold[k]),
          reason: 'iter=$iter k=$k (row=${k ~/ _planeW} col=${k % _planeW})',
        );
      }
    }
    await Simulator.endSimulation();
  });
}
