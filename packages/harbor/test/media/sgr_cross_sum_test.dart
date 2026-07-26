import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 SGR cross-sum (libaom _sgrFast/_sgrFull inner loop), bd8.
int _round2(int x, int n) => (x + (1 << (n - 1))) >> n;

int _weighted(List<int> g, int mode) {
  switch (mode) {
    case 0:
      return (g[4] + g[3] + g[5] + g[1] + g[7]) * 4 +
          (g[0] + g[2] + g[6] + g[8]) * 3;
    case 1:
      return (g[1] + g[7]) * 6 + (g[0] + g[2] + g[6] + g[8]) * 5;
    default:
      return g[4] * 6 + (g[3] + g[5]) * 5;
  }
}

int _flt(List<int> aw, List<int> bw, int center, int mode) {
  final av = _weighted(aw, mode);
  final bv = _weighted(bw, mode);
  final v = av * center + bv;
  final nb = mode == 2 ? 4 : 5;
  return _round2(v, nb + 4);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborSgrCrossSum matches sgr_fast/sgr_full cross-sum', () async {
    final cs = HarborSgrCrossSum();
    final clk = SimpleClockGenerator(10).clk;
    final aw = Logic(name: 'aw', width: 9 * 9);
    final bw = Logic(name: 'bw', width: 9 * 20);
    final center = Logic(name: 'center', width: 8);
    final mode = Logic(name: 'mode', width: 2);
    cs.input('aw').srcConnection! <= aw;
    cs.input('bw').srcConnection! <= bw;
    cs.input('center').srcConnection! <= center;
    cs.input('mode').srcConnection! <= mode;
    await cs.build();
    Simulator.setMaxSimTime(60000000);
    unawaited(Simulator.run());

    final rng = Random(0xC305);
    for (var iter = 0; iter < 2000; iter++) {
      // A values are 0..256 (the x/(x+1) LUT range), B up to ~181000.
      final a = [for (var i = 0; i < 9; i++) rng.nextInt(257)];
      final b = [for (var i = 0; i < 9; i++) rng.nextInt(181000)];
      final cen = rng.nextInt(256);
      final md = rng.nextInt(3);
      var ap = BigInt.zero, bp = BigInt.zero;
      for (var i = 0; i < 9; i++) {
        ap |= BigInt.from(a[i]) << (i * 9);
        bp |= BigInt.from(b[i]) << (i * 20);
      }
      aw.put(ap);
      bw.put(bp);
      center.put(cen);
      mode.put(md);
      await clk.nextPosedge;
      expect(
        cs.output('flt').value.toInt(),
        equals(_flt(a, b, cen, md)),
        reason: 'iter=$iter mode=$md cen=$cen a=$a b=$b',
      );
    }
    await Simulator.endSimulation();
  });
}
