import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference libaom CDEF per-pixel filter (constrain + primary/secondary taps).
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

  group('HarborCdefFilter', () {
    late HarborCdefFilter cd;
    late Logic clk, nb, dir, pri, sec, priDamp, secDamp;

    Future<void> setUpDut() async {
      cd = HarborCdefFilter();
      clk = SimpleClockGenerator(10).clk;
      nb = Logic(name: 'nb', width: 200);
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
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packNb(List<List<int>> g) {
      var v = BigInt.zero;
      for (var r = 0; r < 5; r++) {
        for (var c = 0; c < 5; c++) {
          v |= BigInt.from(g[r][c] & 0xFF) << ((r * 5 + c) * 8);
        }
      }
      return v;
    }

    // A 5x5 neighbourhood with a ringing pattern around the centre.
    List<List<int>> grid(int seed) => [
      for (var r = 0; r < 5; r++)
        [
          for (var c = 0; c < 5; c++)
            (128 + ((r - 2) * 9 + (c - 2) * 7 + seed * (r + c)) % 24 - 12) &
                0xFF,
        ],
    ];

    for (final dirV in [0, 2, 4, 5, 7]) {
      for (final params in [(8, 4, 3, 3), (15, 0, 5, 3), (4, 8, 3, 4)]) {
        test(
          'pixel matches reference dir=$dirV pri=${params.$1} sec=${params.$2}',
          () async {
            await setUpDut();
            final g = grid(dirV + params.$1);
            nb.inject(packNb(g));
            dir.inject(dirV);
            pri.inject(params.$1);
            sec.inject(params.$2);
            priDamp.inject(params.$3);
            secDamp.inject(params.$4);
            await clk.nextPosedge;

            final got = cd.output('out').value.toInt();
            final expected = _cdefPixel(
              g,
              dirV,
              params.$1,
              params.$2,
              params.$3,
              params.$4,
            );
            expect(got, equals(expected));
            await Simulator.endSimulation();
          },
        );
      }
    }

    test('matches reference on random pixels/params', () async {
      await setUpDut();
      final rng = Random(0xCDEFF11);
      for (var iter = 0; iter < 600; iter++) {
        final g = <List<int>>[
          for (var r = 0; r < 5; r++)
            [for (var c = 0; c < 5; c++) rng.nextInt(256)],
        ];
        final dv = rng.nextInt(8);
        // Mix: sometimes one strength is zero (no clip / wrap path), sometimes
        // both nonzero (clip path), strengths and dampings across their range.
        final pv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(16);
        final sv = rng.nextInt(4) == 0 ? 0 : rng.nextInt(8);
        final pdv = 3 + rng.nextInt(4);
        final sdv = 3 + rng.nextInt(4);
        nb.inject(packNb(g));
        dir.inject(dv);
        pri.inject(pv);
        sec.inject(sv);
        priDamp.inject(pdv);
        secDamp.inject(sdv);
        await clk.nextPosedge;
        expect(
          cd.output('out').value.toInt(),
          equals(_cdefPixel(g, dv, pv, sv, pdv, sdv)),
          reason: 'iter=$iter dir=$dv pri=$pv sec=$sv pd=$pdv sd=$sdv g=$g',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
