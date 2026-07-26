@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/inter_convolve.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Filter tables, copied EXACTLY from the SW reference interp filters
// (kSubpelFilters8 / Smooth / Sharp). The golden below mirrors
// the SW tile decode `_convolve` for bd8.
const List<List<int>> _regular = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, -6, 126, 8, -2, 0, 0],
  [0, 2, -10, 122, 18, -4, 0, 0],
  [0, 2, -12, 116, 28, -8, 2, 0],
  [0, 2, -14, 110, 38, -10, 2, 0],
  [0, 2, -14, 102, 48, -12, 2, 0],
  [0, 2, -16, 94, 58, -12, 2, 0],
  [0, 2, -14, 84, 66, -12, 2, 0],
  [0, 2, -14, 76, 76, -14, 2, 0],
  [0, 2, -12, 66, 84, -14, 2, 0],
  [0, 2, -12, 58, 94, -16, 2, 0],
  [0, 2, -12, 48, 102, -14, 2, 0],
  [0, 2, -10, 38, 110, -14, 2, 0],
  [0, 2, -8, 28, 116, -12, 2, 0],
  [0, 0, -4, 18, 122, -10, 2, 0],
  [0, 0, -2, 8, 126, -6, 2, 0],
];

const List<List<int>> _smooth = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, 28, 62, 34, 2, 0, 0],
  [0, 0, 26, 62, 36, 4, 0, 0],
  [0, 0, 22, 62, 40, 4, 0, 0],
  [0, 0, 20, 60, 42, 6, 0, 0],
  [0, 0, 18, 58, 44, 8, 0, 0],
  [0, 0, 16, 56, 46, 10, 0, 0],
  [0, -2, 16, 54, 48, 12, 0, 0],
  [0, -2, 14, 52, 52, 14, -2, 0],
  [0, 0, 12, 48, 54, 16, -2, 0],
  [0, 0, 10, 46, 56, 16, 0, 0],
  [0, 0, 8, 44, 58, 18, 0, 0],
  [0, 0, 6, 42, 60, 20, 0, 0],
  [0, 0, 4, 40, 62, 22, 0, 0],
  [0, 0, 4, 36, 62, 26, 0, 0],
  [0, 0, 2, 34, 62, 28, 2, 0],
];

const List<List<int>> _sharp = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [-2, 2, -6, 126, 8, -2, 2, 0],
  [-2, 6, -12, 124, 16, -6, 4, -2],
  [-2, 8, -18, 120, 26, -10, 6, -2],
  [-4, 10, -22, 116, 38, -14, 6, -2],
  [-4, 10, -22, 108, 48, -18, 8, -2],
  [-4, 10, -24, 100, 60, -20, 8, -2],
  [-4, 10, -24, 90, 70, -22, 10, -2],
  [-4, 12, -24, 80, 80, -24, 12, -4],
  [-2, 10, -22, 70, 90, -24, 10, -4],
  [-2, 8, -20, 60, 100, -24, 10, -4],
  [-2, 8, -18, 48, 108, -22, 10, -4],
  [-2, 6, -14, 38, 116, -22, 10, -4],
  [-2, 6, -10, 26, 120, -18, 8, -2],
  [-2, 4, -6, 16, 124, -12, 6, -2],
  [0, 2, -2, 8, 126, -6, 2, -2],
];

const _bd = 8;
const _pixMax = (1 << _bd) - 1; // 255

int _clip(int v) => v < 0 ? 0 : (v > _pixMax ? _pixMax : v);

// Golden, a direct copy of tile_decode.dart `_convolve` (bd8) restricted to
// the pure-prediction path. `ref` is the already edge-replicated patch, the
// caller addresses it with the convention that output (0,0) at frac 0 reads
// ref[3][3] (the 8-tap support extends 3 left/up, 4 right/down). So we set
// x0 = y0 = 3 and access ref directly (no further replication needed because
// the patch is sized (h+7)x(w+7) and is already replicated by the caller).
List<List<int>> _golden(
  List<List<int>> ref,
  int subX,
  int subY,
  int w,
  int h,
  List<List<int>> fx,
  List<List<int>> fy,
) {
  const filterBits = 7, round0 = 3, round1 = 11;
  const x0 = 3, y0 = 3;
  final dst = [for (var y = 0; y < h; y++) List<int>.filled(w, 0)];

  if (subX == 0 && subY == 0) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        dst[y][x] = ref[y0 + y][x0 + x];
      }
    }
    return dst;
  }
  if (subX != 0 && subY == 0) {
    final xf = fx[subX];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var res = 0;
        for (var k = 0; k < 8; k++) {
          res += xf[k] * ref[y0 + y][x0 + x - 3 + k];
        }
        res = (res + (1 << (round0 - 1))) >> round0;
        final bits = filterBits - round0; // 4
        dst[y][x] = _clip((res + (1 << (bits - 1))) >> bits);
      }
    }
    return dst;
  }
  if (subX == 0 && subY != 0) {
    final yf = fy[subY];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var res = 0;
        for (var k = 0; k < 8; k++) {
          res += yf[k] * ref[y0 + y - 3 + k][x0 + x];
        }
        dst[y][x] = _clip((res + (1 << (filterBits - 1))) >> filterBits);
      }
    }
    return dst;
  }
  // 2D separable.
  final xf = fx[subX], yf = fy[subY];
  final imH = h + 7;
  final im = List<int>.filled(imH * w, 0);
  const bd = _bd;
  for (var y = 0; y < imH; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 1 << (bd + filterBits - 1); // 1<<14
      for (var k = 0; k < 8; k++) {
        sum += xf[k] * ref[y0 + y - 3][x0 + x - 3 + k];
      }
      im[y * w + x] = (sum + (1 << (round0 - 1))) >> round0;
    }
  }
  final offsetBits = bd + 2 * filterBits - round0; // 19
  final sub = (1 << (offsetBits - round1)) + (1 << (offsetBits - round1 - 1));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 1 << offsetBits;
      for (var k = 0; k < 8; k++) {
        sum += yf[k] * im[(y + k) * w + x];
      }
      final res = ((sum + (1 << (round1 - 1))) >> round1) - sub;
      dst[y][x] = _clip(res);
    }
  }
  return dst;
}

List<List<int>> _filterTable(InterConvolveFilter f) {
  switch (f) {
    case InterConvolveFilter.regular:
      return _regular;
    case InterConvolveFilter.smooth:
      return _smooth;
    case InterConvolveFilter.sharp:
      return _sharp;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Patch geometry: output WxH needs (W+7)x(H+7) replicated samples. Output
  // (0,0) at frac 0 maps to patch[3][3].
  for (final family in InterConvolveFilter.values) {
    test(
      'HarborInterConvolve matches _convolve all 4 cases (${family.name})',
      () async {
        const w = 4, h = 4;
        final ph = h + 7, pw = w + 7;
        final dut = HarborInterConvolve(width: w, height: h, filter: family);
        final clk = SimpleClockGenerator(10).clk;
        final patch = Logic(name: 'patch', width: pw * ph * 8);
        final fracX = Logic(name: 'frac_x', width: 4);
        final fracY = Logic(name: 'frac_y', width: 4);
        dut.input('patch').srcConnection! <= patch;
        dut.input('frac_x').srcConnection! <= fracX;
        dut.input('frac_y').srcConnection! <= fracY;
        await dut.build();
        Simulator.setMaxSimTime(600000000);
        unawaited(Simulator.run());

        final table = _filterTable(family);
        final rng = Random(0xC0 + family.index);

        // Phase set covering all four (subX, subY) quadrants and a spread.
        final phases = <List<int>>[
          [0, 0], // copy
          [4, 0], [8, 0], [1, 0], [15, 0], // horizontal only
          [0, 4], [0, 8], [0, 1], [0, 15], // vertical only
          [4, 4], [8, 8], [1, 15], [15, 1], [6, 10], [11, 3], // 2D
        ];

        var vectors = 0;
        final caseSeen = <String, bool>{
          '00': false,
          'x0': false,
          '0y': false,
          'xy': false,
        };
        for (final phase in phases) {
          final fx = phase[0], fy = phase[1];
          // A few random patches per phase.
          for (var iter = 0; iter < 3; iter++) {
            final px = [
              for (var r = 0; r < ph; r++)
                [for (var c = 0; c < pw; c++) rng.nextInt(256)],
            ];
            var packed = BigInt.zero;
            for (var r = 0; r < ph; r++) {
              for (var c = 0; c < pw; c++) {
                packed |= BigInt.from(px[r][c]) << ((r * pw + c) * 8);
              }
            }
            patch.put(packed);
            fracX.put(fx);
            fracY.put(fy);
            await clk.nextPosedge;

            final gold = _golden(px, fx, fy, w, h, table, table);
            final out = dut.output('pred').value;
            for (var y = 0; y < h; y++) {
              for (var x = 0; x < w; x++) {
                final idx = y * w + x;
                expect(
                  out.getRange(idx * 8, idx * 8 + 8).toInt(),
                  equals(gold[y][x]),
                  reason: '${family.name} fx=$fx fy=$fy iter=$iter ($x,$y)',
                );
              }
            }
            vectors++;
            if (fx == 0 && fy == 0) {
              caseSeen['00'] = true;
            } else if (fx != 0 && fy == 0) {
              caseSeen['x0'] = true;
            } else if (fx == 0 && fy != 0) {
              caseSeen['0y'] = true;
            } else {
              caseSeen['xy'] = true;
            }
          }
        }
        // Confirm all four (subX, subY) cases were exercised.
        expect(
          caseSeen.values.every((v) => v),
          isTrue,
          reason: 'all four convolve cases covered: $caseSeen',
        );
        expect(vectors, greaterThanOrEqualTo(30));
        await Simulator.endSimulation();
      },
    );
  }
}
