import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/deblock_luma_frame.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden model: a luma-only intra-keyframe port of `deblockFrame` from
// the SW reference deblock model. subX=subY=0, miSkip all-zero, no miLevel /
// miBlockW (so puEdge==1 and the skip suppression collapses). The walk is
// vertical edges across the whole plane first, then horizontal edges on the
// vertically-filtered result. Edge positions come from the per-4x4 miTx grid,
// the filter length per edge is min tx size across the edge.

const int _kMaxLoopFilter = 63;
const int _kMiSizeLog2 = 2;
const int _kMiSize = 4;
const int _kTx4x4 = 0;
const int _kTxInvalid = 255;
const int _kVertEdge = 0;
const int _kHorzEdge = 1;

const List<int> _kTxSizeWide = [
  4, 8, 16, 32, 64, 4, 8, 8, 16, 16, 32, 32, 64, 4, 16, 8, 32, 16, 64, //
];
const List<int> _kTxSizeHigh = [
  4, 8, 16, 32, 64, 8, 4, 16, 8, 32, 16, 64, 32, 16, 4, 32, 8, 64, 16, //
];
const List<int> _kTxSizeWideUnit = [
  1, 2, 4, 8, 16, 1, 2, 2, 4, 4, 8, 8, 16, 1, 4, 2, 8, 4, 16, //
];
const List<int> _kTxSizeHighUnit = [
  1, 2, 4, 8, 16, 2, 1, 4, 2, 8, 4, 16, 8, 4, 1, 8, 2, 16, 4, //
];
const List<int> _kTxSizeWideUnitLog2 = [
  0, 1, 2, 3, 4, 0, 1, 1, 2, 2, 3, 3, 4, 0, 2, 1, 3, 2, 4, //
];
const List<int> _kTxSizeHighUnitLog2 = [
  0, 1, 2, 3, 4, 1, 0, 2, 1, 3, 2, 4, 3, 2, 0, 3, 1, 4, 2, //
];
const List<int> _kTxDimToFilterLength = [4, 8, 14, 14, 14];

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
int _roundPow2(int value, int n) => (value + ((1 << n) >> 1)) >> n;
int _signedCharClamp(int t) => _clampInt(t, -128, 127);

class _Thresh {
  final int mblim;
  final int lim;
  final int hevThr;
  const _Thresh(this.mblim, this.lim, this.hevThr);
}

List<_Thresh> _buildThresholds(int sharpness) {
  final out = <_Thresh>[];
  for (int lvl = 0; lvl <= _kMaxLoopFilter; lvl++) {
    int bil = lvl >> ((sharpness > 0 ? 1 : 0) + (sharpness > 4 ? 1 : 0));
    if (sharpness > 0) {
      if (bil > (9 - sharpness)) bil = 9 - sharpness;
    }
    if (bil < 1) bil = 1;
    out.add(_Thresh(2 * (lvl + 2) + bil, bil, lvl >> 4));
  }
  return out;
}

typedef _Get = int Function(int tap);
typedef _Set = void Function(int tap, int val);

int _filterMask2(int limit, int blimit, int p1, int p0, int q0, int q1) {
  int mask = 0;
  if ((p1 - p0).abs() > limit) mask = -1;
  if ((q1 - q0).abs() > limit) mask = -1;
  if ((p0 - q0).abs() * 2 + (p1 - q1).abs() ~/ 2 > blimit) mask = -1;
  return (~mask) & 0xFF;
}

int _filterMask(
  int limit,
  int blimit,
  int p3,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int q3,
) {
  int mask = 0;
  if ((p3 - p2).abs() > limit) mask = -1;
  if ((p2 - p1).abs() > limit) mask = -1;
  if ((p1 - p0).abs() > limit) mask = -1;
  if ((q1 - q0).abs() > limit) mask = -1;
  if ((q2 - q1).abs() > limit) mask = -1;
  if ((q3 - q2).abs() > limit) mask = -1;
  if ((p0 - q0).abs() * 2 + (p1 - q1).abs() ~/ 2 > blimit) mask = -1;
  return (~mask) & 0xFF;
}

int _flatMask4(
  int thresh,
  int p3,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int q3,
) {
  int mask = 0;
  if ((p1 - p0).abs() > thresh) mask = -1;
  if ((q1 - q0).abs() > thresh) mask = -1;
  if ((p2 - p0).abs() > thresh) mask = -1;
  if ((q2 - q0).abs() > thresh) mask = -1;
  if ((p3 - p0).abs() > thresh) mask = -1;
  if ((q3 - q0).abs() > thresh) mask = -1;
  return (~mask) & 0xFF;
}

int _hevMask(int thresh, int p1, int p0, int q0, int q1) {
  int hev = 0;
  if ((p1 - p0).abs() > thresh) hev = -1;
  if ((q1 - q0).abs() > thresh) hev = -1;
  return hev & 0xFF;
}

void _filter4(int mask, int thresh, _Get get, _Set set) {
  final op1 = get(-2), op0 = get(-1), oq0 = get(0), oq1 = get(1);
  final ps1 = op1 - 128, ps0 = op0 - 128, qs0 = oq0 - 128, qs1 = oq1 - 128;
  final hev = _hevMask(thresh, op1, op0, oq0, oq1);
  final hevOn = hev != 0;
  final maskOn = mask != 0;
  int filter = hevOn ? _signedCharClamp(ps1 - qs1) : 0;
  filter = maskOn ? _signedCharClamp(filter + 3 * (qs0 - ps0)) : 0;
  final filter1 = _signedCharClamp(filter + 4) >> 3;
  final filter2 = _signedCharClamp(filter + 3) >> 3;
  set(0, _signedCharClamp(qs0 - filter1) + 128);
  set(-1, _signedCharClamp(ps0 + filter2) + 128);
  final f = hevOn ? 0 : _roundPow2(filter1, 1);
  set(1, _signedCharClamp(qs1 - f) + 128);
  set(-2, _signedCharClamp(ps1 + f) + 128);
}

void _filter8(int mask, int thresh, int flat, _Get get, _Set set) {
  if (flat != 0 && mask != 0) {
    final p3 = get(-4), p2 = get(-3), p1 = get(-2), p0 = get(-1);
    final q0 = get(0), q1 = get(1), q2 = get(2), q3 = get(3);
    set(-3, _roundPow2(p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0, 3));
    set(-2, _roundPow2(p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1, 3));
    set(-1, _roundPow2(p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2, 3));
    set(0, _roundPow2(p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3, 3));
    set(1, _roundPow2(p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3, 3));
    set(2, _roundPow2(p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3, 3));
  } else {
    _filter4(mask, thresh, get, set);
  }
}

void _filter14(int mask, int thresh, int flat, int flat2, _Get get, _Set set) {
  if (flat2 != 0 && flat != 0 && mask != 0) {
    final p6 = get(-7),
        p5 = get(-6),
        p4 = get(-5),
        p3 = get(-4),
        p2 = get(-3),
        p1 = get(-2),
        p0 = get(-1);
    final q0 = get(0),
        q1 = get(1),
        q2 = get(2),
        q3 = get(3),
        q4 = get(4),
        q5 = get(5),
        q6 = get(6);
    set(-6, _roundPow2(p6 * 7 + p5 * 2 + p4 * 2 + p3 + p2 + p1 + p0 + q0, 4));
    set(
      -5,
      _roundPow2(p6 * 5 + p5 * 2 + p4 * 2 + p3 * 2 + p2 + p1 + p0 + q0 + q1, 4),
    );
    set(
      -4,
      _roundPow2(
        p6 * 4 + p5 + p4 * 2 + p3 * 2 + p2 * 2 + p1 + p0 + q0 + q1 + q2,
        4,
      ),
    );
    set(
      -3,
      _roundPow2(
        p6 * 3 + p5 + p4 + p3 * 2 + p2 * 2 + p1 * 2 + p0 + q0 + q1 + q2 + q3,
        4,
      ),
    );
    set(
      -2,
      _roundPow2(
        p6 * 2 +
            p5 +
            p4 +
            p3 +
            p2 * 2 +
            p1 * 2 +
            p0 * 2 +
            q0 +
            q1 +
            q2 +
            q3 +
            q4,
        4,
      ),
    );
    set(
      -1,
      _roundPow2(
        p6 +
            p5 +
            p4 +
            p3 +
            p2 +
            p1 * 2 +
            p0 * 2 +
            q0 * 2 +
            q1 +
            q2 +
            q3 +
            q4 +
            q5,
        4,
      ),
    );
    set(
      0,
      _roundPow2(
        p5 +
            p4 +
            p3 +
            p2 +
            p1 +
            p0 * 2 +
            q0 * 2 +
            q1 * 2 +
            q2 +
            q3 +
            q4 +
            q5 +
            q6,
        4,
      ),
    );
    set(
      1,
      _roundPow2(
        p4 +
            p3 +
            p2 +
            p1 +
            p0 +
            q0 * 2 +
            q1 * 2 +
            q2 * 2 +
            q3 +
            q4 +
            q5 +
            q6 * 2,
        4,
      ),
    );
    set(
      2,
      _roundPow2(
        p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 * 2 + q3 * 2 + q4 + q5 + q6 * 3,
        4,
      ),
    );
    set(
      3,
      _roundPow2(
        p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 * 2 + q4 * 2 + q5 + q6 * 4,
        4,
      ),
    );
    set(
      4,
      _roundPow2(p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 * 2 + q5 * 2 + q6 * 5, 4),
    );
    set(5, _roundPow2(p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 * 2 + q6 * 7, 4));
  } else {
    _filter8(mask, thresh, flat, get, set);
  }
}

void _applyEdgeSample(int filterLength, _Thresh t, _Get get, _Set set) {
  switch (filterLength) {
    case 4:
      {
        final p1 = get(-2), p0 = get(-1), q0 = get(0), q1 = get(1);
        final mask = _filterMask2(t.lim, t.mblim, p1, p0, q0, q1);
        _filter4(mask, t.hevThr, get, set);
        break;
      }
    case 8:
      {
        final p3 = get(-4), p2 = get(-3), p1 = get(-2), p0 = get(-1);
        final q0 = get(0), q1 = get(1), q2 = get(2), q3 = get(3);
        final mask = _filterMask(
          t.lim,
          t.mblim,
          p3,
          p2,
          p1,
          p0,
          q0,
          q1,
          q2,
          q3,
        );
        final flat = _flatMask4(1, p3, p2, p1, p0, q0, q1, q2, q3);
        _filter8(mask, t.hevThr, flat, get, set);
        break;
      }
    case 14:
      {
        final p6 = get(-7),
            p5 = get(-6),
            p4 = get(-5),
            p3 = get(-4),
            p2 = get(-3),
            p1 = get(-2),
            p0 = get(-1);
        final q0 = get(0),
            q1 = get(1),
            q2 = get(2),
            q3 = get(3),
            q4 = get(4),
            q5 = get(5),
            q6 = get(6);
        final mask = _filterMask(
          t.lim,
          t.mblim,
          p3,
          p2,
          p1,
          p0,
          q0,
          q1,
          q2,
          q3,
        );
        final flat = _flatMask4(1, p3, p2, p1, p0, q0, q1, q2, q3);
        final flat2 = _flatMask4(1, p6, p5, p4, p0, q0, q4, q5, q6);
        _filter14(mask, t.hevThr, flat, flat2, get, set);
        break;
      }
    default:
      break;
  }
}

// Luma-only intra-keyframe deblockFrame. Mutates [buf] (h rows x w cols).
void goldenDeblockLuma({
  required List<List<int>> buf,
  required int width,
  required int height,
  required int miRows,
  required int miCols,
  required List<List<int>> miTxY,
  required int level,
  required int sharpness,
}) {
  final thr = _buildThresholds(sharpness);

  int txSizeAt(int miRow, int miCol) => miTxY[miRow][miCol];

  // set_lpf_parameters, luma intra. Returns [txSize, filterLength, levelOut].
  // filterLength==0 means no edge. txSize==kTxInvalid signals skip with step 1.
  List<int> setLpf(int edgeDir, int x, int y) {
    if (width <= x || height <= y) return [_kTx4x4, 0, 0];
    final miRow = y >> _kMiSizeLog2;
    final miCol = x >> _kMiSizeLog2;
    if (miRow >= miRows || miCol >= miCols) return [_kTxInvalid, 0, 0];
    final ts = txSizeAt(miRow, miCol);
    final coord = (edgeDir == _kVertEdge) ? x : y;
    final transformMasks = edgeDir == _kVertEdge
        ? _kTxSizeWide[ts] - 1
        : _kTxSizeHigh[ts] - 1;
    final tuEdge = (coord & transformMasks) == 0;
    if (!tuEdge) return [ts, 0, 0];

    final currLevel = level; // uniform
    int filterLength = 0;
    int levelOut = currLevel;
    if (coord != 0) {
      final pvRow = (edgeDir == _kVertEdge) ? miRow : (miRow - 1);
      final pvCol = (edgeDir == _kVertEdge) ? (miCol - 1) : miCol;
      if (pvRow < 0 || pvCol < 0) return [_kTxInvalid, 0, 0];
      final pvTs = txSizeAt(pvRow, pvCol);
      // pvLvl == currLevel (uniform), puEdge==1, skips all 0.
      if (currLevel != 0) {
        final dim = (edgeDir == _kVertEdge)
            ? (_kTxSizeWideUnitLog2[ts] < _kTxSizeWideUnitLog2[pvTs]
                  ? _kTxSizeWideUnitLog2[ts]
                  : _kTxSizeWideUnitLog2[pvTs])
            : (_kTxSizeHighUnitLog2[ts] < _kTxSizeHighUnitLog2[pvTs]
                  ? _kTxSizeHighUnitLog2[ts]
                  : _kTxSizeHighUnitLog2[pvTs]);
        filterLength = _kTxDimToFilterLength[dim];
        levelOut = currLevel;
      }
    }
    return [ts, filterLength, levelOut];
  }

  void filterVert(int x, int y, int filterLength, _Thresh t) {
    if (filterLength == 0) return;
    for (int i = 0; i < _kMiSize; i++) {
      final row = y + i;
      if (row >= height) break;
      final r = buf[row];
      _applyEdgeSample(
        filterLength,
        t,
        (tap) => r[x + tap],
        (tap, val) => r[x + tap] = val,
      );
    }
  }

  void filterHorz(int x, int y, int filterLength, _Thresh t) {
    if (filterLength == 0) return;
    for (int i = 0; i < _kMiSize; i++) {
      final col = x + i;
      if (col >= width) break;
      _applyEdgeSample(
        filterLength,
        t,
        (tap) => buf[y + tap][col],
        (tap, val) => buf[y + tap][col] = val,
      );
    }
  }

  // Single superblock assumed (miRows, miCols <= 32). yRange/xRange in 4x4.
  final yRange = miRows;
  final xRange = miCols;

  // Vertical edges across the whole plane.
  for (int yu = 0; yu < yRange; yu++) {
    int xu = 0;
    while (xu < xRange) {
      final currX = xu * _kMiSize;
      final currY = yu * _kMiSize;
      final p = setLpf(_kVertEdge, currX, currY);
      var txSize = p[0];
      var fl = p[1];
      if (txSize == _kTxInvalid) {
        fl = 0;
        txSize = _kTx4x4;
      }
      if (fl != 0) filterVert(currX, currY, fl, thr[p[2]]);
      xu += _kTxSizeWideUnit[txSize];
    }
  }

  // Horizontal edges on the vertically-filtered result.
  for (int xu = 0; xu < xRange; xu++) {
    int yu = 0;
    while (yu < yRange) {
      final currX = xu * _kMiSize;
      final currY = yu * _kMiSize;
      final p = setLpf(_kHorzEdge, currX, currY);
      var txSize = p[0];
      var fl = p[1];
      if (txSize == _kTxInvalid) {
        fl = 0;
        txSize = _kTx4x4;
      }
      if (fl != 0) filterHorz(currX, currY, fl, thr[p[2]]);
      yu += _kTxSizeHighUnit[txSize];
    }
  }
}

Future<void> runCase({
  required String label,
  required int width,
  required int height,
  required List<List<int>> miTx,
  required int level,
  required int sharpness,
  required int iters,
  required int seed,
}) async {
  final dut = HarborDeblockLumaFrame(
    width: width,
    height: height,
    miTx: miTx,
    level: level,
    sharpness: sharpness,
  );
  final clk = SimpleClockGenerator(10).clk;
  final frame = Logic(name: 'frame', width: width * height * 8);
  dut.input('frame').srcConnection! <= frame;
  await dut.build();
  Simulator.setMaxSimTime(200000000);
  unawaited(Simulator.run());

  final rng = Random(seed);
  var totalChanged = 0;
  for (var iter = 0; iter < iters; iter++) {
    // Build a random pixel frame, biased toward locally-flat regions so the
    // wide kernels engage some of the time.
    final pix = List.generate(height, (_) => List<int>.filled(width, 0));
    final mode = iter % 3;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (mode == 0) {
          // Fully random: stresses every mask/clamp path.
          pix[y][x] = rng.nextInt(256);
        } else if (mode == 1) {
          // Locally flat plateaus with a small step at each tx boundary so the
          // filter (mask + flat) actually engages and rewrites pixels.
          final plateau = 100 + 6 * ((x ~/ 8) + (y ~/ 8));
          pix[y][x] = (plateau + rng.nextInt(3) - 1).clamp(0, 255);
        } else {
          // Smooth ramp: low gradients keep masks on across wider spans.
          pix[y][x] = (60 + (x + y)).clamp(0, 255) + rng.nextInt(3) - 1;
          pix[y][x] = pix[y][x].clamp(0, 255);
        }
      }
    }

    // Pack LSB-first row-major.
    var packed = BigInt.zero;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final idx = y * width + x;
        packed |= BigInt.from(pix[y][x]) << (idx * 8);
      }
    }
    frame.put(packed);
    await clk.nextPosedge;

    // Golden.
    final gold = List.generate(height, (y) => List<int>.from(pix[y]));
    goldenDeblockLuma(
      buf: gold,
      width: width,
      height: height,
      miRows: miTx.length,
      miCols: miTx[0].length,
      miTxY: miTx,
      level: level,
      sharpness: sharpness,
    );

    final outVal = dut.output('out').value;
    final got = List.generate(height, (y) => List<int>.filled(width, 0));
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final idx = y * width + x;
        got[y][x] = outVal.getRange(idx * 8, idx * 8 + 8).toInt();
      }
    }

    for (var y = 0; y < height; y++) {
      expect(
        got[y],
        equals(gold[y]),
        reason: '$label iter=$iter row=$y\nin =${pix[y]}',
      );
      for (var x = 0; x < width; x++) {
        if (gold[y][x] != pix[y][x]) totalChanged++;
      }
    }
  }
  // Guard against vacuous (identity) passes: the chosen frames must actually
  // exercise the filter so bit-exactness is meaningful.
  expect(
    totalChanged,
    greaterThan(0),
    reason: '$label never modified any pixel',
  );
  await Simulator.endSimulation();
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('all TX_4X4 16x16 (filter4 every 4px edge)', () async {
    final miTx = List.generate(4, (_) => List.filled(4, 0)); // TX_4X4
    await runCase(
      label: 'tx4x4',
      width: 16,
      height: 16,
      miTx: miTx,
      level: 24,
      sharpness: 0,
      iters: 12,
      seed: 0xA1,
    );
  });

  test('all TX_8X8 16x16 (filter8 at 8px boundaries)', () async {
    final miTx = List.generate(4, (_) => List.filled(4, 1)); // TX_8X8
    await runCase(
      label: 'tx8x8',
      width: 16,
      height: 16,
      miTx: miTx,
      level: 32,
      sharpness: 0,
      iters: 12,
      seed: 0xB2,
    );
  });

  test('all TX_16X16 32x32 (filter14 fires at interior boundary)', () async {
    final miTx = List.generate(8, (_) => List.filled(8, 2)); // TX_16X16
    await runCase(
      label: 'tx16_32',
      width: 32,
      height: 32,
      miTx: miTx,
      level: 40,
      sharpness: 0,
      iters: 10,
      seed: 0xE5,
    );
  });

  test('rectangular tx (TX_8X16 / TX_16X8) 32x32', () async {
    // TX_8X16 = 7 (wide 8, high 16), TX_16X8 = 8 (wide 16, high 8). Mixes
    // vertical vs horizontal filter lengths per edge.
    final miTx = [
      [7, 7, 8, 8, 7, 7, 8, 8],
      [7, 7, 8, 8, 7, 7, 8, 8],
      [8, 8, 7, 7, 8, 8, 7, 7],
      [8, 8, 7, 7, 8, 8, 7, 7],
      [7, 7, 8, 8, 7, 7, 8, 8],
      [7, 7, 8, 8, 7, 7, 8, 8],
      [8, 8, 7, 7, 8, 8, 7, 7],
      [8, 8, 7, 7, 8, 8, 7, 7],
    ];
    await runCase(
      label: 'rect',
      width: 32,
      height: 32,
      miTx: miTx,
      level: 36,
      sharpness: 1,
      iters: 8,
      seed: 0xF6,
    );
  });

  test('mixed tx grid 16x16', () async {
    // Row of mi: col0 TX_8X8, col1 TX_8X8, col2 TX_4X4, col3 TX_4X4 ->
    // mixes edge spacing and filter lengths (min across edge).
    final miTx = [
      [1, 1, 0, 0],
      [1, 1, 0, 0],
      [0, 0, 2, 2],
      [0, 0, 2, 2],
    ];
    await runCase(
      label: 'mixed',
      width: 16,
      height: 16,
      miTx: miTx,
      level: 28,
      sharpness: 0,
      iters: 12,
      seed: 0xD4,
    );
  });
}
