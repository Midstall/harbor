import 'dart:async';
import 'dart:math';

// Direct import of the module under test (parent wires the export).
import 'package:harbor/src/media/cdef_frame_pass.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden model: a faithful slice of the reference cdefFrame for a
// single region with a REAL 2-pixel border ring (interior superblock case).
//
// The per-8x8 core (direction search + adjust_strength + per-pixel filter) is
// the already-verified _cdefBlock golden, copied verbatim from the
// HarborCdefBlock test so we exercise the same reference the block was proven
// against. The frame-pass logic we add here is exactly:
//   - per-8x8 skip => pass the block through unchanged,
//   - non-skip => build the block's 12x12 window from the padded region and
//     filter it.

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

// 12x12 padded -> filtered 8x8 (block occupies padded rows/cols 2..9).
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

// Golden frame pass: `pad` is the (region+4) x (region+4) padded grid (real
// border ring). `skip` is [nb][nb] bools. Returns the filtered region x region.
List<List<int>> _cdefFramePass(
  List<List<int>> pad,
  int region,
  List<List<bool>> skip,
  int pri,
  int sec,
  int pd,
  int sd, {
  bool luma = true,
}) {
  final nb = region ~/ 8;
  // Filtered region initialised from the input region (skip => pass through).
  final out = [
    for (var r = 0; r < region; r++)
      [for (var c = 0; c < region; c++) pad[r + 2][c + 2]],
  ];
  for (var by = 0; by < nb; by++) {
    for (var bx = 0; bx < nb; bx++) {
      if (skip[by][bx]) continue;
      // 12x12 window: padded rows/cols by*8 .. by*8+11 (block top-left of the
      // central 8x8 sits at padded (by*8+2, bx*8+2)).
      final win = [
        for (var r = 0; r < 12; r++)
          [for (var c = 0; c < 12; c++) pad[by * 8 + r][bx * 8 + c]],
      ];
      final blk = _cdefBlock(win, pri, sec, pd, sd, luma: luma);
      for (var r = 0; r < 8; r++) {
        for (var c = 0; c < 8; c++) {
          out[by * 8 + r][bx * 8 + c] = blk[r * 8 + c];
        }
      }
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdefFramePass', () {
    // Region under test: 16x16 = 2x2 8x8 blocks. The 8-bit CDEF block has no
    // CDEF_VERY_LARGE sentinel support, so the border ring is REAL pixels (an
    // interior region of a larger frame). See the module doc.
    const region = 16;
    const padded = region + 4; // 20x20: region + 2px border ring each side.
    const nb = region ~/ 8; // 2

    Future<List<List<int>>> runHw(
      HarborCdefFramePass mod,
      Logic clk,
      Logic padIn,
      Logic skipIn,
      Logic pri,
      Logic sec,
      Logic pd,
      Logic sd,
      List<List<int>> pad,
      List<List<bool>> skip,
      int prV,
      int seV,
      int pdV,
      int sdV,
    ) async {
      var pv = BigInt.zero;
      for (var r = 0; r < padded; r++) {
        for (var c = 0; c < padded; c++) {
          pv |= BigInt.from(pad[r][c] & 0xFF) << ((r * padded + c) * 8);
        }
      }
      var sv = BigInt.zero;
      for (var by = 0; by < nb; by++) {
        for (var bx = 0; bx < nb; bx++) {
          if (skip[by][bx]) sv |= BigInt.one << (by * nb + bx);
        }
      }
      padIn.inject(pv);
      skipIn.inject(sv);
      pri.inject(prV);
      sec.inject(seV);
      pd.inject(pdV);
      sd.inject(sdV);
      await clk.nextPosedge;
      final v = mod.output('out').value.toBigInt();
      return [
        for (var r = 0; r < region; r++)
          [
            for (var c = 0; c < region; c++)
              ((v >> ((r * region + c) * 8)) & BigInt.from(0xFF)).toInt(),
          ],
      ];
    }

    test(
      'matches the golden frame pass over random regions/skips/strengths',
      () async {
        final mod = HarborCdefFramePass(region: region);
        final clk = SimpleClockGenerator(10).clk;
        final padIn = Logic(name: 'padded', width: padded * padded * 8);
        final skipIn = Logic(name: 'skip', width: nb * nb);
        final pri = Logic(name: 'pri', width: 8);
        final sec = Logic(name: 'sec', width: 8);
        final pd = Logic(name: 'pri_damp', width: 8);
        final sd = Logic(name: 'sec_damp', width: 8);

        mod.input('padded').srcConnection! <= padIn;
        mod.input('skip').srcConnection! <= skipIn;
        mod.input('pri').srcConnection! <= pri;
        mod.input('sec').srcConnection! <= sec;
        mod.input('pri_damp').srcConnection! <= pd;
        mod.input('sec_damp').srcConnection! <= sd;

        await mod.build();
        Simulator.setMaxSimTime(60000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;

        final rng = Random(0xCDEF);
        for (var iter = 0; iter < 16; iter++) {
          // Build a 20x20 padded region with directional edges so direction and
          // variance actually vary across blocks.
          final base = 60 + rng.nextInt(120);
          final flat = iter % 4 == 0;
          final pad = [
            for (var r = 0; r < padded; r++)
              [
                for (var c = 0; c < padded; c++)
                  flat
                      ? (base + rng.nextInt(7) - 3).clamp(0, 255)
                      : (((r + c) < padded ? base : base + 50) +
                                rng.nextInt(13) -
                                6) &
                            0xFF,
              ],
          ];
          // Random skip pattern. Force at least one of each across iterations.
          final skip = [
            for (var by = 0; by < nb; by++)
              [for (var bx = 0; bx < nb; bx++) rng.nextBool()],
          ];
          // First iter: nothing skipped. Second: everything skipped.
          if (iter == 0) {
            for (final row in skip) {
              for (var i = 0; i < row.length; i++) {
                row[i] = false;
              }
            }
          } else if (iter == 1) {
            for (final row in skip) {
              for (var i = 0; i < row.length; i++) {
                row[i] = true;
              }
            }
          }
          final prV = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
          final seV = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
          final pdV = 3 + rng.nextInt(4);
          final sdV = 3 + rng.nextInt(4);

          final got = await runHw(
            mod,
            clk,
            padIn,
            skipIn,
            pri,
            sec,
            pd,
            sd,
            pad,
            skip,
            prV,
            seV,
            pdV,
            sdV,
          );
          final exp = _cdefFramePass(pad, region, skip, prV, seV, pdV, sdV);
          expect(
            got,
            equals(exp),
            reason:
                'iter=$iter pri=$prV sec=$seV pd=$pdV sd=$sdV '
                'skip=$skip',
          );
        }
        await Simulator.endSimulation();
      },
    );

    test('chroma path (luma=false, no adjust_strength)', () async {
      final mod = HarborCdefFramePass(region: region, luma: false);
      final clk = SimpleClockGenerator(10).clk;
      final padIn = Logic(name: 'padded', width: padded * padded * 8);
      final skipIn = Logic(name: 'skip', width: nb * nb);
      final pri = Logic(name: 'pri', width: 8);
      final sec = Logic(name: 'sec', width: 8);
      final pd = Logic(name: 'pri_damp', width: 8);
      final sd = Logic(name: 'sec_damp', width: 8);
      mod.input('padded').srcConnection! <= padIn;
      mod.input('skip').srcConnection! <= skipIn;
      mod.input('pri').srcConnection! <= pri;
      mod.input('sec').srcConnection! <= sec;
      mod.input('pri_damp').srcConnection! <= pd;
      mod.input('sec_damp').srcConnection! <= sd;
      await mod.build();
      Simulator.setMaxSimTime(60000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;

      final rng = Random(0x5A5A);
      for (var iter = 0; iter < 8; iter++) {
        final base = 60 + rng.nextInt(120);
        final pad = [
          for (var r = 0; r < padded; r++)
            [
              for (var c = 0; c < padded; c++)
                (((r + c) < padded ? base : base + 50) + rng.nextInt(13) - 6) &
                    0xFF,
            ],
        ];
        final skip = [
          for (var by = 0; by < nb; by++)
            [for (var bx = 0; bx < nb; bx++) rng.nextBool()],
        ];
        final prV = rng.nextInt(12);
        final seV = rng.nextInt(6);
        final pdV = 3 + rng.nextInt(4);
        final sdV = 3 + rng.nextInt(4);
        final got = await runHw(
          mod,
          clk,
          padIn,
          skipIn,
          pri,
          sec,
          pd,
          sd,
          pad,
          skip,
          prV,
          seV,
          pdV,
          sdV,
        );
        final exp = _cdefFramePass(
          pad,
          region,
          skip,
          prV,
          seV,
          pdV,
          sdV,
          luma: false,
        );
        expect(got, equals(exp), reason: 'iter=$iter');
      }
      await Simulator.endSimulation();
    });
  });
}
