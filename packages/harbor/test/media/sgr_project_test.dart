import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 SGR projection (libaom _sgrProcUnit final combine), bd8.
int _clampPx(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

int _project(int pre, int flt0, int flt1, int xq0, int xq1) {
  final u = pre << 4; // SGRPROJ_RST_BITS
  var v = u << 7; // SGRPROJ_PRJ_BITS
  v += xq0 * (flt0 - u);
  v += xq1 * (flt1 - u);
  return _clampPx((v + (1 << 10)) >> 11);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSgrProject', () {
    late HarborSgrProject pj;
    late Logic clk, pre, flt0, flt1, xq0, xq1;

    Future<void> setUpDut() async {
      pj = HarborSgrProject();
      clk = SimpleClockGenerator(10).clk;
      pre = Logic(name: 'pre', width: 8);
      flt0 = Logic(name: 'flt0', width: 18);
      flt1 = Logic(name: 'flt1', width: 18);
      xq0 = Logic(name: 'xq0', width: 8);
      xq1 = Logic(name: 'xq1', width: 8);
      pj.input('pre').srcConnection! <= pre;
      pj.input('flt0').srcConnection! <= flt0;
      pj.input('flt1').srcConnection! <= flt1;
      pj.input('xq0').srcConnection! <= xq0;
      pj.input('xq1').srcConnection! <= xq1;
      await pj.build();
      for (final p in [pre, flt0, flt1, xq0, xq1]) {
        p.inject(0);
      }
      Simulator.setMaxSimTime(40000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('matches the reference on random units', () async {
      await setUpDut();
      final rng = Random(0x5697);
      for (var iter = 0; iter < 2000; iter++) {
        final pv = rng.nextInt(256);
        // flt are in the RST domain (~ pre<<4), so cluster near pv<<4 with
        // spread, plus some wide draws.
        int flt() => iter % 3 == 0
            ? rng.nextInt(1 << 18)
            : ((pv << 4) + rng.nextInt(2048) - 1024).clamp(0, (1 << 18) - 1);
        final f0 = flt(), f1 = flt();
        // xq weights in their AV1 signed ranges.
        final q0 = rng.nextInt(128) - 96;
        final q1 = rng.nextInt(128) - 32;
        pre.inject(pv);
        flt0.inject(f0);
        flt1.inject(f1);
        xq0.inject(q0 & 0xFF);
        xq1.inject(q1 & 0xFF);
        await clk.nextPosedge;
        expect(
          pj.output('out').value.toInt(),
          equals(_project(pv, f0, f1, q0, q1)),
          reason: 'iter=$iter pre=$pv f0=$f0 f1=$f1 q0=$q0 q1=$q1',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
