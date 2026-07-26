import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborTileDecodeDriver', () {
    test('walks two superblocks across a 32x16 tile', () async {
      final d = HarborTileDecodeDriver();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final sbSize = Logic(name: 'sb_size', width: 5);
      final sbStep = Logic(name: 'sb_step', width: 16);
      final miRows = Logic(name: 'mi_rows', width: 16);
      final miCols = Logic(name: 'mi_cols', width: 16);
      final partIn = Logic(name: 'partition_in', width: 4);
      final partValid = Logic(name: 'partition_valid');
      final emitAck = Logic(name: 'emit_ack');
      d.input('clk').srcConnection! <= clk;
      d.input('reset').srcConnection! <= reset;
      d.input('start').srcConnection! <= start;
      d.input('sb_size').srcConnection! <= sbSize;
      d.input('sb_step').srcConnection! <= sbStep;
      d.input('mi_rows').srcConnection! <= miRows;
      d.input('mi_cols').srcConnection! <= miCols;
      d.input('partition_in').srcConnection! <= partIn;
      d.input('partition_valid').srcConnection! <= partValid;
      d.input('emit_ack').srcConnection! <= emitAck;
      await d.build();

      const none = 0, split = 3;
      // SB0 at (0,0): NONE. SB1 at (0,4): SPLIT into 4 NONE 8x8.
      final decisions = <(int, int, int), int>{
        (0, 0, 6): none,
        (0, 4, 6): split,
        (0, 4, 3): none,
        (0, 6, 3): none,
        (2, 4, 3): none,
        (2, 6, 3): none,
      };

      reset.inject(1);
      start.inject(0);
      sbSize.inject(6); // 16x16
      sbStep.inject(4); // 16x16 = 4 mi units
      miRows.inject(4);
      miCols.inject(8);
      partIn.inject(0);
      partValid.inject(1);
      emitAck.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      final emits = <(int, int, int)>[];
      var lastPart = 0;
      for (var cyc = 0; cyc < 300; cyc++) {
        if (d.output('query_valid').value.toInt() == 1) {
          final key = (
            d.output('query_r').value.toInt(),
            d.output('query_c').value.toInt(),
            d.output('query_bsize').value.toInt(),
          );
          lastPart = decisions[key] ?? 0;
        }
        partIn.inject(lastPart);
        if (d.output('emit_valid').value.toInt() == 1) {
          emits.add((
            d.output('emit_r').value.toInt(),
            d.output('emit_c').value.toInt(),
            d.output('emit_bsize').value.toInt(),
          ));
        }
        if (d.output('done').value.toInt() == 1) break;
        await clk.nextPosedge;
      }

      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 6), // SB0: one 16x16
          (0, 4, 3), // SB1: four 8x8 (raster)
          (0, 6, 3),
          (2, 4, 3),
          (2, 6, 3),
        ]),
      );
      await Simulator.endSimulation();
    });
  });
}
