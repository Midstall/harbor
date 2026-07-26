import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

(int, int) _findDir(List<List<int>> img) {
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
      cost[d] = acc + sq(par[7]) * divTable[8];
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
  return (bestDir, (bestCost - cost[(bestDir + 4) & 7]) >> 10);
}

// adjust_strength(strength, var) (luma only).
int _adjustStrength(int strength, int variance) {
  final m = _msb(variance >> 6);
  final i = (variance >> 6) != 0 ? (m < 12 ? m : 12) : 0;
  return variance != 0 ? (strength * (4 + i) + 8) >> 4 : 0;
}

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

// nb is a 5x5 with the current pixel at [2][2].
int _cdefPixel(List<List<int>> nb, int dir, int pri, int sec, int pd, int sd) {
  final cur = nb[2][2];
  final clip = pri != 0 && sec != 0;
  var sum = 0;
  var minV = cur, maxV = cur;
  for (var k = 0; k < 2; k++) {
    final tap = _priTaps[pri & 1][k];
    final dy = _dirs[dir][k][0], dx = _dirs[dir][k][1];
    final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
    sum += tap * (_constrain(p - cur, pri, pd) + _constrain(q - cur, pri, pd));
    minV = min(minV, min(p, q));
    maxV = max(maxV, max(p, q));
  }
  for (var k = 0; k < 2; k++) {
    final tap = _secTaps[k];
    for (final s in [(dir + 2) & 7, (dir + 6) & 7]) {
      final dy = _dirs[s][k][0], dx = _dirs[s][k][1];
      final p = nb[2 + dy][2 + dx], q = nb[2 - dy][2 - dx];
      sum +=
          tap * (_constrain(p - cur, sec, sd) + _constrain(q - cur, sec, sd));
      minV = min(minV, min(p, q));
      maxV = max(maxV, max(p, q));
    }
  }
  final out = cur + ((8 + sum - (sum < 0 ? 1 : 0)) >> 4);
  if (clip) return out < minV ? minV : (out > maxV ? maxV : out);
  return out & 0xff;
}

// 12x12 padded -> filtered 8x8 (block occupies padded rows/cols 2..9). luma
// applies adjust_strength, dir is gated on the original strength.
List<int> _cdefBlock(
  List<List<int>> padded,
  int pri,
  int sec,
  int pd,
  int sd, {
  bool luma = true,
}) {
  final central = [
    for (var r = 0; r < 8; r++)
      [for (var c = 0; c < 8; c++) padded[r + 2][c + 2]],
  ];
  final (rawDir, variance) = _findDir(central);
  final t = luma ? _adjustStrength(pri, variance) : pri;
  final dir = pri != 0 ? rawDir : 0;
  final out = <int>[];
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      final nb = [
        for (var dr = 0; dr < 5; dr++)
          [for (var dc = 0; dc < 5; dc++) padded[r + dr][c + dc]],
      ];
      out.add(_cdefPixel(nb, dir, t, sec, pd, sd));
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdefBlock', () {
    test('filters an 8x8 block (direction search + per-pixel)', () async {
      final cb = HarborCdefBlock();
      final clk = SimpleClockGenerator(10).clk;
      final padded = Logic(name: 'padded', width: 12 * 12 * 8);
      final pri = Logic(name: 'pri', width: 8);
      final sec = Logic(name: 'sec', width: 8);
      final priDamp = Logic(name: 'pri_damp', width: 8);
      final secDamp = Logic(name: 'sec_damp', width: 8);

      cb.input('padded').srcConnection! <= padded;
      cb.input('pri').srcConnection! <= pri;
      cb.input('sec').srcConnection! <= sec;
      cb.input('pri_damp').srcConnection! <= priDamp;
      cb.input('sec_damp').srcConnection! <= secDamp;

      await cb.build();

      // A 12x12 region with a diagonal edge through the central 8x8.
      final pad = [
        for (var r = 0; r < 12; r++)
          [
            for (var c = 0; c < 12; c++)
              (((r + c) < 11 ? 100 : 150) + (r * 3 + c * 5) % 11 - 5) & 0xFF,
          ],
      ];
      var pv = BigInt.zero;
      for (var r = 0; r < 12; r++) {
        for (var c = 0; c < 12; c++) {
          pv |= BigInt.from(pad[r][c] & 0xFF) << ((r * 12 + c) * 8);
        }
      }

      padded.inject(pv);
      pri.inject(8);
      sec.inject(4);
      priDamp.inject(4);
      secDamp.inject(3);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;

      final v = cb.output('out').value.toBigInt();
      final got = [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
      final expected = _cdefBlock(pad, 8, 4, 4, 3);
      expect(got, equals(expected));
      await Simulator.endSimulation();
    });

    test(
      'matches full luma path (adjust_strength + clip) on random blocks',
      () async {
        final cb = HarborCdefBlock();
        final clk = SimpleClockGenerator(10).clk;
        final padded = Logic(name: 'padded', width: 12 * 12 * 8);
        final pri = Logic(name: 'pri', width: 8);
        final sec = Logic(name: 'sec', width: 8);
        final priDamp = Logic(name: 'pri_damp', width: 8);
        final secDamp = Logic(name: 'sec_damp', width: 8);
        cb.input('padded').srcConnection! <= padded;
        cb.input('pri').srcConnection! <= pri;
        cb.input('sec').srcConnection! <= sec;
        cb.input('pri_damp').srcConnection! <= priDamp;
        cb.input('sec_damp').srcConnection! <= secDamp;
        await cb.build();
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;

        final rng = Random(0xB10C);
        for (var iter = 0; iter < 60; iter++) {
          // Bias toward an edge so direction/variance vary, some flat blocks too.
          final flat = iter % 3 == 0;
          final base = 60 + rng.nextInt(120);
          final pad = [
            for (var r = 0; r < 12; r++)
              [
                for (var c = 0; c < 12; c++)
                  flat
                      ? (base + rng.nextInt(7) - 3).clamp(0, 255)
                      : (((r + c) < 11 ? base : base + 50) +
                                rng.nextInt(13) -
                                6) &
                            0xFF,
              ],
          ];
          var pv = BigInt.zero;
          for (var r = 0; r < 12; r++) {
            for (var c = 0; c < 12; c++) {
              pv |= BigInt.from(pad[r][c] & 0xFF) << ((r * 12 + c) * 8);
            }
          }
          final prV = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
          final seV = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
          final pdV = 3 + rng.nextInt(4);
          final sdV = 3 + rng.nextInt(4);
          padded.inject(pv);
          pri.inject(prV);
          sec.inject(seV);
          priDamp.inject(pdV);
          secDamp.inject(sdV);
          await clk.nextPosedge;

          final v = cb.output('out').value.toBigInt();
          final got = [
            for (var i = 0; i < 64; i++)
              ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
          ];
          expect(
            got,
            equals(_cdefBlock(pad, prV, seV, pdV, sdV)),
            reason: 'iter=$iter pri=$prV sec=$seV pd=$pdV sd=$sdV',
          );
        }
        await Simulator.endSimulation();
      },
    );
  });
}
