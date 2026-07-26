import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference libaom cdef_find_dir: returns [bestDir, variance].
List<int> _findDirVar(List<List<int>> img) {
  const divTable = [0, 840, 420, 280, 210, 168, 140, 120, 105];
  const sizes = [15, 11, 8, 11, 15, 11, 8, 11];
  int idxFor(int d, int i, int j) {
    switch (d) {
      case 0:
        return i + j;
      case 1:
        return i + (j >> 1);
      case 2:
        return i;
      case 3:
        return 3 + i - (j >> 1);
      case 4:
        return 7 + i - j;
      case 5:
        return 3 - (i >> 1) + j;
      case 6:
        return j;
      default:
        return (i >> 1) + j;
    }
  }

  final partial = [for (var d = 0; d < 8; d++) List.filled(sizes[d], 0)];
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 8; j++) {
      final x = img[i][j] - 128;
      for (var d = 0; d < 8; d++) {
        partial[d][idxFor(d, i, j)] += x;
      }
    }
  }
  int sq(int p) => p * p;
  final cost = List.filled(8, 0);
  for (var d = 0; d < 8; d++) {
    final par = partial[d];
    if (d == 2 || d == 6) {
      var s = 0;
      for (var i = 0; i < 8; i++) {
        s += sq(par[i]);
      }
      cost[d] = s * 105;
    } else if (d == 0 || d == 4) {
      var acc = 0;
      for (var i = 0; i < 7; i++) {
        acc += (sq(par[i]) + sq(par[14 - i])) * divTable[i + 1];
      }
      acc += sq(par[7]) * divTable[8];
      cost[d] = acc;
    } else {
      var s = 0;
      for (var j = 0; j < 5; j++) {
        s += sq(par[3 + j]);
      }
      var acc = s * 105;
      for (var j = 0; j < 3; j++) {
        acc += (sq(par[j]) + sq(par[10 - j])) * divTable[2 * j + 2];
      }
      cost[d] = acc;
    }
  }
  var bestCost = 0, bestDir = 0;
  for (var i = 0; i < 8; i++) {
    if (cost[i] > bestCost) {
      bestCost = cost[i];
      bestDir = i;
    }
  }
  final variance = (bestCost - cost[(bestDir + 4) & 7]) >> 10;
  return [bestDir, variance];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdefDirection', () {
    late HarborCdefDirection cd;
    late Logic clk, block;

    Future<void> setUpDut() async {
      cd = HarborCdefDirection();
      clk = SimpleClockGenerator(10).clk;
      block = Logic(name: 'block', width: 512);
      cd.input('block').srcConnection! <= block;
      await cd.build();
      block.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packBlk(List<List<int>> g) {
      var v = BigInt.zero;
      for (var r = 0; r < 8; r++) {
        for (var c = 0; c < 8; c++) {
          v |= BigInt.from(g[r][c] & 0xFF) << ((r * 8 + c) * 8);
        }
      }
      return v;
    }

    // Generators that favour particular edge directions.
    final blocks = <(String, List<List<int>>)>[
      (
        'horizontal edge',
        [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) r < 4 ? 90 : 160],
        ],
      ),
      (
        'vertical edge',
        [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) c < 4 ? 90 : 160],
        ],
      ),
      (
        'diagonal edge',
        [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) (r + c) < 7 ? 100 : 150],
        ],
      ),
      (
        'anti-diagonal',
        [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) (r - c) < 0 ? 110 : 150],
        ],
      ),
      (
        'mixed texture',
        [
          for (var r = 0; r < 8; r++)
            [
              for (var c = 0; c < 8; c++)
                (128 + (r * 13 + c * 29) % 60 - 30) & 0xFF,
            ],
        ],
      ),
      (
        'shallow gradient',
        [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) (100 + r * 6 + c * 2) & 0xFF],
        ],
      ),
    ];

    for (final b in blocks) {
      test('finds the AV1 direction: ${b.$1}', () async {
        await setUpDut();
        block.inject(packBlk(b.$2));
        await clk.nextPosedge;
        final want = _findDirVar(b.$2);
        expect(cd.output('dir').value.toInt(), equals(want[0]), reason: b.$1);
        expect(
          cd.output('variance').value.toInt(),
          equals(want[1]),
          reason: '${b.$1} variance',
        );
        await Simulator.endSimulation();
      });
    }

    test('matches dir+variance on random blocks', () async {
      await setUpDut();
      final rng = Random(0xCDEF);
      for (var iter = 0; iter < 400; iter++) {
        final g = [
          for (var r = 0; r < 8; r++)
            [for (var c = 0; c < 8; c++) rng.nextInt(256)],
        ];
        block.inject(packBlk(g));
        await clk.nextPosedge;
        final want = _findDirVar(g);
        expect(
          cd.output('dir').value.toInt(),
          equals(want[0]),
          reason: 'iter=$iter dir',
        );
        expect(
          cd.output('variance').value.toInt(),
          equals(want[1]),
          reason: 'iter=$iter variance g=$g',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
