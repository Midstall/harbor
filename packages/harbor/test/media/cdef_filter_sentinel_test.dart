import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/cdef_filter.dart';
import 'package:harbor/src/media/cdef_filter_sentinel.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference libaom CDEF per-pixel filter WITH CDEF_VERY_LARGE sentinel handling,
// mirroring the reference `_cdefFilterBlock` per-pixel logic reduced
// to one pixel. Neighbour samples are 15-bit: in-frame pixels are 0..255, while
// out-of-frame neighbours are cdefVeryLarge (0x4000). The centre is always
// in-frame (0..255).
//
// Sentinel rules from the SW:
//   - The constrain contribution of a VERY_LARGE neighbour is naturally 0
//     (threshold - (|diff| >> shift) goes negative -> 0), which we replicate by
//     gating the constrain term to 0 when the tap is VERY_LARGE.
//   - maxV folds a tap only when `tap != cdefVeryLarge`.
//   - minV is written unconditionally in the SW, but cdefVeryLarge (0x4000) can
//     never lower the running minimum (centre + in-frame taps are <= 255), so
//     skipping VERY_LARGE taps for minV is bit-identical.
const int cdefVeryLarge = 0x4000;

const _dirs = [
  [
    [-1, 1],
    [-2, 2],
  ],
  [
    [0, 1],
    [-1, 2],
  ],
  [
    [0, 1],
    [0, 2],
  ],
  [
    [0, 1],
    [1, 2],
  ],
  [
    [1, 1],
    [2, 2],
  ],
  [
    [1, 0],
    [2, 1],
  ],
  [
    [1, 0],
    [2, 0],
  ],
  [
    [1, 0],
    [2, -1],
  ],
];
const _priTaps = [
  [4, 2],
  [3, 3],
];
const _secTaps = [2, 1];

int _msb(int x) {
  var n = 0;
  while (x > 1) {
    n++;
    x >>= 1;
  }
  return n;
}

int _constrain(int diff, int thr, int damp) {
  if (thr == 0) return 0;
  final shift = (damp - _msb(thr)) < 0 ? 0 : damp - _msb(thr);
  final ad = diff.abs();
  var inner = thr - (ad >> shift);
  if (inner < 0) inner = 0;
  final mag = ad < inner ? ad : inner;
  return diff < 0 ? -mag : mag;
}

/// Single-pixel CDEF with sentinel handling. `nb` is a 5x5 grid of 15-bit
/// samples (centre at [2][2], always 0..255). Mirrors `_cdefFilterBlock`.
int _cdefPixelSentinel(
  List<List<int>> nb,
  int dir,
  int pri,
  int sec,
  int pd,
  int sd,
) {
  final cur = nb[2][2];
  final clip = pri != 0 && sec != 0;
  var sum = 0;
  var minV = cur, maxV = cur;

  void foldMax(int v) {
    if (v != cdefVeryLarge && v > maxV) maxV = v;
  }

  void foldMin(int v) {
    // SW writes minV unconditionally, VERY_LARGE never wins so equivalently
    // skip it.
    if (v != cdefVeryLarge && v < minV) minV = v;
  }

  for (var k = 0; k < 2; k++) {
    final tap = _priTaps[pri & 1][k];
    final dy = _dirs[dir][k][0], dx = _dirs[dir][k][1];
    final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
    final pc = p == cdefVeryLarge ? 0 : _constrain(p - cur, pri, pd);
    final qc = q == cdefVeryLarge ? 0 : _constrain(q - cur, pri, pd);
    sum += tap * (pc + qc);
    if (clip) {
      foldMax(p);
      foldMax(q);
      foldMin(p);
      foldMin(q);
    }
  }
  for (var k = 0; k < 2; k++) {
    final tap = _secTaps[k];
    for (final s in [(dir + 2) & 7, (dir + 6) & 7]) {
      final dy = _dirs[s][k][0], dx = _dirs[s][k][1];
      final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
      final pc = p == cdefVeryLarge ? 0 : _constrain(p - cur, sec, sd);
      final qc = q == cdefVeryLarge ? 0 : _constrain(q - cur, sec, sd);
      sum += tap * (pc + qc);
      if (clip) {
        foldMax(p);
        foldMax(q);
        foldMin(p);
        foldMin(q);
      }
    }
  }
  final out = cur + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4);
  if (clip) return out < minV ? minV : (out > maxV ? maxV : out);
  return out & 0xff;
}

// Interior reference (no sentinels), copy of cdef_filter_test.dart, to confirm
// the sentinel module agrees with the existing interior datapath when no tap is
// VERY_LARGE.
int _cdefPixelInterior(
  List<List<int>> nb,
  int dir,
  int pri,
  int sec,
  int pd,
  int sd,
) {
  final cur = nb[2][2];
  final clip = pri != 0 && sec != 0;
  var sum = 0;
  var minV = cur, maxV = cur;
  for (var k = 0; k < 2; k++) {
    final tap = _priTaps[pri & 1][k];
    final dy = _dirs[dir][k][0], dx = _dirs[dir][k][1];
    final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
    sum += tap * (_constrain(p - cur, pri, pd) + _constrain(q - cur, pri, pd));
    if (p < minV) minV = p;
    if (p > maxV) maxV = p;
    if (q < minV) minV = q;
    if (q > maxV) maxV = q;
  }
  for (var k = 0; k < 2; k++) {
    final tap = _secTaps[k];
    for (final s in [(dir + 2) & 7, (dir + 6) & 7]) {
      final dy = _dirs[s][k][0], dx = _dirs[s][k][1];
      final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
      sum +=
          tap * (_constrain(p - cur, sec, sd) + _constrain(q - cur, sec, sd));
      if (p < minV) minV = p;
      if (p > maxV) maxV = p;
      if (q < minV) minV = q;
      if (q > maxV) maxV = q;
    }
  }
  final out = cur + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4);
  if (clip) return out < minV ? minV : (out > maxV ? maxV : out);
  return out & 0xff;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdefFilterSentinel', () {
    late HarborCdefFilterSentinel cd;
    late Logic clk, nb, dir, pri, sec, priDamp, secDamp;

    Future<void> setUpDut() async {
      cd = HarborCdefFilterSentinel();
      clk = SimpleClockGenerator(10).clk;
      nb = Logic(name: 'nb', width: 5 * 5 * 15);
      dir = Logic(name: 'dir', width: 3);
      pri = Logic(name: 'pri', width: 8);
      sec = Logic(name: 'sec', width: 8);
      priDamp = Logic(name: 'pri_damp', width: 8);
      secDamp = Logic(name: 'sec_damp', width: 8);
      cd.input('nb').srcConnection! <= nb;
      cd.input('dir').srcConnection! <= dir;
      cd.input('pri').srcConnection! <= pri;
      cd.input('sec').srcConnection! <= sec;
      cd.input('pri_damp').srcConnection! <= priDamp;
      cd.input('sec_damp').srcConnection! <= secDamp;
      await cd.build();
      nb.inject(0);
      dir.inject(0);
      pri.inject(0);
      sec.inject(0);
      priDamp.inject(3);
      secDamp.inject(3);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    // Pack 5x5 grid, 15 bits per sample, LSB-first (pixel (r,c) at bit
    // (r*5+c)*15).
    BigInt packNb(List<List<int>> g) {
      var v = BigInt.zero;
      for (var r = 0; r < 5; r++) {
        for (var c = 0; c < 5; c++) {
          v |= BigInt.from(g[r][c] & 0x7FFF) << ((r * 5 + c) * 15);
        }
      }
      return v;
    }

    // Apply an edge pattern: mark out-of-frame cells as VERY_LARGE. `pattern`
    // is a predicate on (r,c) in [0,4]x[0,4] (frame-relative, centre at 2,2).
    List<List<int>> applyEdge(
      List<List<int>> g,
      bool Function(int r, int c) outside,
    ) {
      return [
        for (var r = 0; r < 5; r++)
          [for (var c = 0; c < 5; c++) outside(r, c) ? cdefVeryLarge : g[r][c]],
      ];
    }

    // Random in-frame 5x5 (0..255 each).
    List<List<int>> randGrid(Random rng) => [
      for (var r = 0; r < 5; r++)
        [for (var c = 0; c < 5; c++) rng.nextInt(256)],
    ];

    Future<void> checkOne(
      List<List<int>> g,
      int dv,
      int pv,
      int sv,
      int pdv,
      int sdv,
      int iter,
    ) async {
      nb.inject(packNb(g));
      dir.inject(dv);
      pri.inject(pv);
      sec.inject(sv);
      priDamp.inject(pdv);
      secDamp.inject(sdv);
      await clk.nextPosedge;
      final got = cd.output('out').value.toInt();
      final exp = _cdefPixelSentinel(g, dv, pv, sv, pdv, sdv);
      expect(
        got,
        equals(exp),
        reason: 'iter=$iter dir=$dv pri=$pv sec=$sv pd=$pdv sd=$sdv g=$g',
      );
    }

    // 1) Interior (no sentinel): sentinel module must equal the interior golden
    //    AND the existing HarborCdefFilter, proving the no-sentinel datapath is
    //    unchanged.
    test('interior matches both sentinel and interior goldens', () async {
      await setUpDut();
      final rng = Random(0x5E47);
      for (var iter = 0; iter < 30; iter++) {
        final g = randGrid(rng);
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
        final sv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        final sgold = _cdefPixelSentinel(g, dv, pv, sv, pdv, sdv);
        final igold = _cdefPixelInterior(g, dv, pv, sv, pdv, sdv);
        expect(
          sgold,
          equals(igold),
          reason: 'goldens disagree on interior iter=$iter',
        );
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });

    // Cross-check the interior golden against the EXISTING HarborCdefFilter
    // module (8-bit nb), so the sentinel module's no-sentinel path is anchored
    // to the shipped interior module.
    test('interior golden equals existing HarborCdefFilter module', () async {
      final hf = HarborCdefFilter();
      final hclk = SimpleClockGenerator(10).clk;
      final hnb = Logic(name: 'nb', width: 200);
      final hdir = Logic(name: 'dir', width: 3);
      final hpri = Logic(name: 'pri', width: 8);
      final hsec = Logic(name: 'sec', width: 8);
      final hpd = Logic(name: 'pri_damp', width: 8);
      final hsd = Logic(name: 'sec_damp', width: 8);
      hf.input('nb').srcConnection! <= hnb;
      hf.input('dir').srcConnection! <= hdir;
      hf.input('pri').srcConnection! <= hpri;
      hf.input('sec').srcConnection! <= hsec;
      hf.input('pri_damp').srcConnection! <= hpd;
      hf.input('sec_damp').srcConnection! <= hsd;
      await hf.build();
      hnb.inject(0);
      hdir.inject(0);
      hpri.inject(0);
      hsec.inject(0);
      hpd.inject(3);
      hsd.inject(3);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await hclk.nextPosedge;

      BigInt pack8(List<List<int>> g) {
        var v = BigInt.zero;
        for (var r = 0; r < 5; r++) {
          for (var c = 0; c < 5; c++) {
            v |= BigInt.from(g[r][c] & 0xFF) << ((r * 5 + c) * 8);
          }
        }
        return v;
      }

      final rng = Random(0xA11CE);
      for (var iter = 0; iter < 25; iter++) {
        final g = [
          for (var r = 0; r < 5; r++)
            [for (var c = 0; c < 5; c++) rng.nextInt(256)],
        ];
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
        final sv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        hnb.inject(pack8(g));
        hdir.inject(dv);
        hpri.inject(pv);
        hsec.inject(sv);
        hpd.inject(pdv);
        hsd.inject(sdv);
        await hclk.nextPosedge;
        expect(
          hf.output('out').value.toInt(),
          equals(_cdefPixelInterior(g, dv, pv, sv, pdv, sdv)),
          reason: 'iter=$iter',
        );
      }
      await Simulator.endSimulation();
    });

    // 2) Top row out of frame (centre on the frame's top edge: rows 0,1 above
    //    centre are outside).
    test('top edge sentinel', () async {
      await setUpDut();
      final rng = Random(0x70BE);
      for (var iter = 0; iter < 25; iter++) {
        final g = applyEdge(randGrid(rng), (r, c) => r < 2);
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(16);
        final sv = rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });

    // 3) Left column out of frame.
    test('left edge sentinel', () async {
      await setUpDut();
      final rng = Random(0x1EF7);
      for (var iter = 0; iter < 25; iter++) {
        final g = applyEdge(randGrid(rng), (r, c) => c < 2);
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(16);
        final sv = rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });

    // 4) Top-left corner out of frame (rows<2 OR cols<2).
    test('top-left corner sentinel', () async {
      await setUpDut();
      final rng = Random(0xC02E7);
      for (var iter = 0; iter < 25; iter++) {
        final g = applyEdge(randGrid(rng), (r, c) => r < 2 || c < 2);
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(16);
        final sv = rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });

    // 5) Bottom-right corner out of frame (rows>2 OR cols>2).
    test('bottom-right corner sentinel', () async {
      await setUpDut();
      final rng = Random(0xB07E7);
      for (var iter = 0; iter < 25; iter++) {
        final g = applyEdge(randGrid(rng), (r, c) => r > 2 || c > 2);
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(16);
        final sv = rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });

    // 6) Fully random sentinel mask: each non-centre cell independently outside
    //    with ~40% probability. Stresses arbitrary frame-edge geometries.
    test('random sentinel mask', () async {
      await setUpDut();
      final rng = Random(0xDEADBEE);
      for (var iter = 0; iter < 40; iter++) {
        final base = randGrid(rng);
        final g = [
          for (var r = 0; r < 5; r++)
            [
              for (var c = 0; c < 5; c++)
                (r == 2 && c == 2)
                    ? base[r][c]
                    : (rng.nextInt(5) < 2 ? cdefVeryLarge : base[r][c]),
            ],
        ];
        final dv = rng.nextInt(8);
        final pv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
        final sv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        await checkOne(g, dv, pv, sv, pdv, sdv, iter);
      }
      await Simulator.endSimulation();
    });
  });
}
