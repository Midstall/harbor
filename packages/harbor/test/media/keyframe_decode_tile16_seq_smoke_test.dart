import 'dart:async';

import 'package:harbor/src/media/keyframe_decode_tile16_seq.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Smoke test: HarborKeyframeDecodeTile16Seq (raster SB walk, 2x2 grid of 16x16
// SBs, tileMiW tile-wide above context + tiled sequential recon) BUILDS and RUNS
// end-to-end to `done` on a fixed byte pattern, producing valid (non-X, 0..255)
// pixels for the assembled 32x32 tile. Proves the full raster-SB-walk
// integration (tileMiW multiSb + per-SB seq recon + 2D neighbour threading +
// raster FSM) composes and executes. The per-axis context propagation is already
// proven bit-exact (2sb16 horizontal + vertical). Full 4-SB bit-exact is a
// follow-on.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 1024;
  test(
    'HarborKeyframeDecodeTile16Seq 2x2 builds and runs to done',
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      final t = HarborKeyframeDecodeTile16Seq(
        sbRows: 2,
        sbCols: 2,
        maxBytes: maxBytes,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final dcQ = Logic(name: 'dc_q', width: 16);
      final acQ = Logic(name: 'ac_q', width: 16);
      t.input('clk').srcConnection! <= clk;
      t.input('reset').srcConnection! <= reset;
      t.input('start').srcConnection! <= start;
      t.input('bytes').srcConnection! <= bytes;
      t.input('dc_q').srcConnection! <= dcQ;
      t.input('ac_q').srcConnection! <= acQ;
      await t.build();
      reset.inject(1);
      start.inject(0);
      var bv = BigInt.zero;
      for (var i = 0; i < maxBytes; i++) {
        bv |= BigInt.from((i * 53 + 17) & 0xff) << (i * 8);
      }
      bytes.inject(bv);
      dcQ.inject(200);
      acQ.inject(220);
      Simulator.setMaxSimTime(800000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (t.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 200000) fail('did not reach done');
      }
      final fr = t.output('frame').value;
      expect(fr.isValid, isTrue, reason: 'tile frame has X bits');
      print('reached done, 32x32 tile frame valid');
      await Simulator.endSimulation();
    },
  );
}
