import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/filter_intra.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// av1_filter_intra_taps[FILTER_INTRA_MODES=5][8][7], copied verbatim from
// the SW reference intra prediction model.
const List<List<List<int>>> _filterIntraTaps = [
  [
    [-6, 10, 0, 0, 0, 12, 0],
    [-5, 2, 10, 0, 0, 9, 0],
    [-3, 1, 1, 10, 0, 7, 0],
    [-3, 1, 1, 2, 10, 5, 0],
    [-4, 6, 0, 0, 0, 2, 12],
    [-3, 2, 6, 0, 0, 2, 9],
    [-3, 2, 2, 6, 0, 2, 7],
    [-3, 1, 2, 2, 6, 3, 5],
  ],
  [
    [-10, 16, 0, 0, 0, 10, 0],
    [-6, 0, 16, 0, 0, 6, 0],
    [-4, 0, 0, 16, 0, 4, 0],
    [-2, 0, 0, 0, 16, 2, 0],
    [-10, 16, 0, 0, 0, 0, 10],
    [-6, 0, 16, 0, 0, 0, 6],
    [-4, 0, 0, 16, 0, 0, 4],
    [-2, 0, 0, 0, 16, 0, 2],
  ],
  [
    [-8, 8, 0, 0, 0, 16, 0],
    [-8, 0, 8, 0, 0, 16, 0],
    [-8, 0, 0, 8, 0, 16, 0],
    [-8, 0, 0, 0, 8, 16, 0],
    [-4, 4, 0, 0, 0, 0, 16],
    [-4, 0, 4, 0, 0, 0, 16],
    [-4, 0, 0, 4, 0, 0, 16],
    [-4, 0, 0, 0, 4, 0, 16],
  ],
  [
    [-2, 8, 0, 0, 0, 10, 0],
    [-1, 3, 8, 0, 0, 6, 0],
    [-1, 2, 3, 8, 0, 4, 0],
    [0, 1, 2, 3, 8, 2, 0],
    [-1, 4, 0, 0, 0, 3, 10],
    [-1, 3, 4, 0, 0, 4, 6],
    [-1, 2, 3, 4, 0, 4, 4],
    [-1, 2, 2, 3, 4, 3, 3],
  ],
  [
    [-12, 14, 0, 0, 0, 14, 0],
    [-10, 0, 14, 0, 0, 12, 0],
    [-9, 0, 0, 14, 0, 11, 0],
    [-8, 0, 0, 0, 14, 10, 0],
    [-10, 12, 0, 0, 0, 0, 14],
    [-9, 1, 12, 0, 0, 0, 12],
    [-8, 0, 0, 12, 0, 1, 11],
    [-7, 0, 0, 1, 12, 1, 9],
  ],
];

const int _filterIntraScaleBits = 4;
const int _bdMax = 255;

int _clipPixel(int v) => v < 0 ? 0 : (v > _bdMax ? _bdMax : v);
int _roundPow2(int value, int n) => (value + (1 << (n - 1))) >> n;

// Golden: Dart copy of _filterIntraPredictor (intra_pred.dart line 221), with
// aboveOff=1, leftOff=0 so above[0] is the above-left corner.
List<int> _goldenFilterIntra(
  int bw,
  int bh,
  List<int> above,
  List<int> left,
  int mode,
) {
  final dst = List<int>.filled(bw * bh, 0);
  const aboveOff = 1;
  const leftOff = 0;
  final buf = [for (var i = 0; i < bh + 1; i++) List<int>.filled(bw + 1, 0)];
  for (var r = 0; r < bh; r++) {
    buf[r + 1][0] = left[leftOff + r];
  }
  for (var c = 0; c < bw + 1; c++) {
    buf[0][c] = above[aboveOff - 1 + c];
  }
  for (var r = 1; r < bh + 1; r += 2) {
    for (var c = 1; c < bw + 1; c += 4) {
      final p0 = buf[r - 1][c - 1];
      final p1 = buf[r - 1][c];
      final p2 = buf[r - 1][c + 1];
      final p3 = buf[r - 1][c + 2];
      final p4 = buf[r - 1][c + 3];
      final p5 = buf[r][c - 1];
      final p6 = buf[r + 1][c - 1];
      for (var k = 0; k < 8; k++) {
        final rOff = k >> 2;
        final cOff = k & 3;
        final t = _filterIntraTaps[mode][k];
        final pr =
            t[0] * p0 +
            t[1] * p1 +
            t[2] * p2 +
            t[3] * p3 +
            t[4] * p4 +
            t[5] * p5 +
            t[6] * p6;
        buf[r + rOff][c + cOff] = _clipPixel(
          _roundPow2(pr, _filterIntraScaleBits),
        );
      }
    }
  }
  for (var r = 0; r < bh; r++) {
    for (var c = 0; c < bw; c++) {
      dst[r * bw + c] = buf[r + 1][c + 1];
    }
  }
  return dst;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Validation: bw must be a multiple of 4, bh a multiple of 2.
  test('HarborFilterIntra rejects bad block sizes', () {
    expect(() => HarborFilterIntra(bw: 6, bh: 8), throwsArgumentError);
    expect(() => HarborFilterIntra(bw: 8, bh: 3), throwsArgumentError);
    expect(() => HarborFilterIntra(bw: 0, bh: 8), throwsArgumentError);
  });

  // Block sizes cover both patch dimensions: bw=4/8/16 (1/2/4 patch cols) and
  // bh=2/4/8 (1/2/4 patch rows) so the scan-order recursion is fully exercised.
  // Larger blocks reuse the identical datapath, so they run fewer iterations to
  // stay inside the per-test ROHD sim-time budget.
  for (final size in [
    (4, 2, 60),
    (8, 8, 60),
    (8, 4, 60),
    (4, 8, 60),
    (16, 8, 8),
  ]) {
    final bw = size.$1;
    final bh = size.$2;
    final iters = size.$3;
    test(
      'HarborFilterIntra matches SW _filterIntraPredictor (${bw}x$bh)',
      () async {
        final dut = HarborFilterIntra(bw: bw, bh: bh);
        final above = Logic(name: 'above', width: (bw + 1) * 8);
        final left = Logic(name: 'left', width: bh * 8);
        final mode = Logic(name: 'mode', width: 3);
        dut.input('above').srcConnection! <= above;
        dut.input('left').srcConnection! <= left;
        dut.input('mode').srcConnection! <= mode;
        await dut.build();
        Simulator.setMaxSimTime(6000000000);
        unawaited(Simulator.run());

        final rng = Random(0xF1A + bw * 31 + bh);
        for (var iter = 0; iter < iters; iter++) {
          for (var m = 0; m < 5; m++) {
            // above has corner + bw samples = bw+1 entries.
            final aboveSamples = [
              for (var i = 0; i < bw + 1; i++) rng.nextInt(256),
            ];
            final leftSamples = [for (var i = 0; i < bh; i++) rng.nextInt(256)];

            var abPacked = BigInt.zero;
            for (var i = 0; i < aboveSamples.length; i++) {
              abPacked |= BigInt.from(aboveSamples[i]) << (i * 8);
            }
            var lfPacked = BigInt.zero;
            for (var i = 0; i < leftSamples.length; i++) {
              lfPacked |= BigInt.from(leftSamples[i]) << (i * 8);
            }
            above.put(abPacked);
            left.put(lfPacked);
            mode.put(m);
            await Simulator.tick();

            final gold = _goldenFilterIntra(
              bw,
              bh,
              aboveSamples,
              leftSamples,
              m,
            );
            final predVal = dut.output('pred').value;
            for (var idx = 0; idx < bw * bh; idx++) {
              expect(
                predVal.getRange(idx * 8, idx * 8 + 8).toInt(),
                equals(gold[idx]),
                reason: 'pred ${bw}x$bh mode=$m iter=$iter idx=$idx',
              );
            }
          }
        }
        await Simulator.endSimulation();
      },
    );
  }
}
