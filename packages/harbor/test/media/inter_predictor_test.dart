import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
int _bilerp(int a, int b, int f) => ((16 - f) * a + f * b + 8) >> 4;

// Reference: separable bilinear MC + reconstruct (residual stride-8).
List<int> _interPredict(
  List<List<int>> patch,
  int fx,
  int fy,
  int n,
  List<int> res,
) {
  final h = [
    for (var r = 0; r < 9; r++)
      [for (var c = 0; c < 8; c++) _bilerp(patch[r][c], patch[r][c + 1], fx)],
  ];
  final out = List.filled(64, 0);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      out[r * 8 + c] = _clampPx(
        _bilerp(h[r][c], h[r + 1][c], fy) + res[r * 8 + c],
      );
    }
  }
  return out;
}

BigInt _packRef(List<List<int>> patch) {
  var v = BigInt.zero;
  for (var r = 0; r < 9; r++) {
    for (var c = 0; c < 9; c++) {
      v |= BigInt.from(patch[r][c] & 0xFF) << ((r * 9 + c) * 8);
    }
  }
  return v;
}

BigInt _packRes(List<int> r) {
  var v = BigInt.zero;
  for (var i = 0; i < 64; i++) {
    v |= BigInt.from(r[i] & 0xFFFF) << (i * 16);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborInterPredictor', () {
    late HarborInterPredictor pred;
    late Logic clk, fracX, fracY, refIn, residual;

    Future<void> setUpDut() async {
      pred = HarborInterPredictor();
      clk = SimpleClockGenerator(10).clk;
      fracX = Logic(name: 'fx', width: 4);
      fracY = Logic(name: 'fy', width: 4);
      refIn = Logic(name: 'ref_in', width: 81 * 8);
      residual = Logic(name: 'residual', width: 64 * 16);

      pred.input('frac_x').srcConnection! <= fracX;
      pred.input('frac_y').srcConnection! <= fracY;
      pred.input('ref_patch').srcConnection! <= refIn;
      pred.input('residual').srcConnection! <= residual;

      await pred.build();
      fracX.inject(0);
      fracY.inject(0);
      refIn.inject(0);
      residual.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    List<int> readRecon() {
      final v = pred.output('recon').value.toBigInt();
      return [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
    }

    final patch = [
      for (var r = 0; r < 9; r++)
        [for (var c = 0; c < 9; c++) (r * 17 + c * 23 + 40) & 0xFF],
    ];
    final res = [for (var i = 0; i < 64; i++) (i * 5 - 80)];

    for (final n in [4, 8]) {
      for (final mv in [(0, 0), (8, 8), (5, 11), (12, 3)]) {
        test(
          '${n}x$n motion comp frac (${mv.$1},${mv.$2}) matches reference',
          () async {
            await setUpDut();
            fracX.inject(mv.$1);
            fracY.inject(mv.$2);
            refIn.inject(_packRef(patch));
            residual.inject(_packRes(res));
            await clk.nextPosedge;

            final got = readRecon();
            final expected = _interPredict(patch, mv.$1, mv.$2, n, res);
            for (var r = 0; r < n; r++) {
              for (var c = 0; c < n; c++) {
                expect(
                  got[r * 8 + c],
                  equals(expected[r * 8 + c]),
                  reason: 'pixel ($r,$c)',
                );
              }
            }
            await Simulator.endSimulation();
          },
        );
      }
    }
  });

  group('HarborInterPredictor 8-tap', () {
    late HarborInterPredictor pred;
    late Logic clk, fracX, fracY, refIn, residual, filterType;

    Future<void> setUpDut() async {
      pred = HarborInterPredictor(taps: 8);
      clk = SimpleClockGenerator(10).clk;
      fracX = Logic(name: 'fx', width: 4);
      fracY = Logic(name: 'fy', width: 4);
      refIn = Logic(name: 'ref_in', width: 15 * 15 * 8);
      residual = Logic(name: 'residual', width: 64 * 16);
      filterType = Logic(name: 'filter_type', width: 2);

      pred.input('frac_x').srcConnection! <= fracX;
      pred.input('frac_y').srcConnection! <= fracY;
      pred.input('ref_patch').srcConnection! <= refIn;
      pred.input('residual').srcConnection! <= residual;
      pred.input('filter_type').srcConnection! <= filterType;

      await pred.build();
      fracX.inject(0);
      fracY.inject(0);
      refIn.inject(0);
      residual.inject(0);
      filterType.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    List<int> readRecon() {
      final v = pred.output('recon').value.toBigInt();
      return [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
    }

    // The AV1 8-tap luma kernels (mirroring the constants in inter_predictor).
    const reg = [
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
    const smooth = [
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
    const sharp = [
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
    final tables = [reg, smooth, sharp];

    int _conv8(List<int> s, List<int> coef) {
      var acc = 0;
      for (var k = 0; k < 8; k++) {
        acc += s[k] * coef[k];
      }
      return (acc + 64) >> 7;
    }

    List<int> _predict8(
      List<List<int>> patch,
      int fx,
      int fy,
      int filt,
      int n,
      List<int> res,
    ) {
      final coefX = tables[filt][fx];
      final coefY = tables[filt][fy];
      final h = [
        for (var r = 0; r < 15; r++)
          [
            for (var c = 0; c < 8; c++)
              _conv8([for (var k = 0; k < 8; k++) patch[r][c + k]], coefX),
          ],
      ];
      final out = List.filled(64, 0);
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          final p = _conv8([for (var k = 0; k < 8; k++) h[r + k][c]], coefY);
          out[r * 8 + c] = _clampPx(p + res[r * 8 + c]);
        }
      }
      return out;
    }

    BigInt _packRef15(List<List<int>> patch) {
      var v = BigInt.zero;
      for (var r = 0; r < 15; r++) {
        for (var c = 0; c < 15; c++) {
          v |= BigInt.from(patch[r][c] & 0xFF) << ((r * 15 + c) * 8);
        }
      }
      return v;
    }

    final patch = [
      for (var r = 0; r < 15; r++)
        [for (var c = 0; c < 15; c++) (r * 11 + c * 19 + 30) & 0xFF],
    ];
    final res = [for (var i = 0; i < 64; i++) (i * 3 - 48)];

    final filtNames = {0: 'regular', 1: 'smooth', 2: 'sharp'};
    for (final filt in [0, 1, 2]) {
      for (final n in [4, 8]) {
        for (final mv in [(0, 0), (8, 8), (5, 11)]) {
          test('${n}x$n ${filtNames[filt]} frac (${mv.$1},${mv.$2}) '
              'matches reference', () async {
            await setUpDut();
            fracX.inject(mv.$1);
            fracY.inject(mv.$2);
            filterType.inject(filt);
            refIn.inject(_packRef15(patch));
            residual.inject(_packRes(res));
            await clk.nextPosedge;

            final got = readRecon();
            final expected = _predict8(patch, mv.$1, mv.$2, filt, n, res);
            for (var r = 0; r < n; r++) {
              for (var c = 0; c < n; c++) {
                expect(
                  got[r * 8 + c],
                  equals(expected[r * 8 + c]),
                  reason: 'pixel ($r,$c)',
                );
              }
            }
            await Simulator.endSimulation();
          });
        }
      }
    }
  });
}
