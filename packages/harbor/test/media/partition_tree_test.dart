import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPartitionTree', () {
    // Run the tree for a set of (r,c,bsize)->partition decisions and return the
    // emitted leaves in order.
    Future<List<(int, int, int)>> run(
      int sbSize,
      int miR,
      int miC,
      Map<(int, int, int), int> decisions,
    ) async {
      final t = HarborPartitionTree();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final sbR = Logic(name: 'sb_r', width: 16);
      final sbC = Logic(name: 'sb_c', width: 16);
      final sbSz = Logic(name: 'sb_size', width: 5);
      final miRows = Logic(name: 'mi_rows', width: 16);
      final miCols = Logic(name: 'mi_cols', width: 16);
      final partIn = Logic(name: 'partition_in', width: 4);
      final partValid = Logic(name: 'partition_valid');
      final emitAck = Logic(name: 'emit_ack');
      t.input('clk').srcConnection! <= clk;
      t.input('reset').srcConnection! <= reset;
      t.input('start').srcConnection! <= start;
      t.input('sb_r').srcConnection! <= sbR;
      t.input('sb_c').srcConnection! <= sbC;
      t.input('sb_size').srcConnection! <= sbSz;
      t.input('mi_rows').srcConnection! <= miRows;
      t.input('mi_cols').srcConnection! <= miCols;
      t.input('partition_in').srcConnection! <= partIn;
      t.input('partition_valid').srcConnection! <= partValid;
      t.input('emit_ack').srcConnection! <= emitAck;
      await t.build();

      reset.inject(1);
      start.inject(0);
      sbR.inject(0);
      sbC.inject(0);
      sbSz.inject(sbSize);
      miRows.inject(miR);
      miCols.inject(miC);
      partIn.inject(0);
      partValid.inject(1); // env is always ready
      emitAck.inject(1); // leaves consumed immediately
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
      for (var cyc = 0; cyc < 200; cyc++) {
        if (t.output('query_valid').value.toInt() == 1) {
          final key = (
            t.output('query_r').value.toInt(),
            t.output('query_c').value.toInt(),
            t.output('query_bsize').value.toInt(),
          );
          lastPart = decisions[key] ?? 0;
        }
        partIn.inject(lastPart);
        if (t.output('emit_valid').value.toInt() == 1) {
          emits.add((
            t.output('emit_r').value.toInt(),
            t.output('emit_c').value.toInt(),
            t.output('emit_bsize').value.toInt(),
          ));
        }
        if (t.output('done').value.toInt() == 1) break;
        await clk.nextPosedge;
      }
      await Simulator.endSimulation();
      return emits;
    }

    const none = 0, horz = 1, vert = 2, split = 3;
    const horzA = 4, vertB = 7, horz4 = 8, vert4 = 9;

    test('SPLIT into 4 with none/horz/vert/none', () async {
      final emits = await run(6, 4, 4, {
        (0, 0, 6): split,
        (0, 0, 3): none,
        (0, 2, 3): horz,
        (2, 0, 3): vert,
        (2, 2, 3): none,
      });
      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 3),
          (0, 2, 2),
          (1, 2, 2),
          (2, 0, 1),
          (2, 1, 1),
          (2, 2, 3),
        ]),
      );
    });

    test('HORZ_A: two 8x8 top, one 16x8 bottom', () async {
      final emits = await run(6, 4, 4, {(0, 0, 6): horzA});
      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 3), // 8x8 top-left
          (0, 2, 3), // 8x8 top-right
          (2, 0, 5), // 16x8 bottom
        ]),
      );
    });

    test('VERT_B: one 8x16 left, two 8x8 right', () async {
      final emits = await run(6, 4, 4, {(0, 0, 6): vertB});
      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 4), // 8x16 left (subsize VERT of 16x16)
          (0, 2, 3), // 8x8 top-right
          (2, 2, 3), // 8x8 bottom-right
        ]),
      );
    });

    test('HORZ_4: four 16x4 strips', () async {
      final emits = await run(6, 4, 4, {(0, 0, 6): horz4});
      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 17),
          (1, 0, 17),
          (2, 0, 17),
          (3, 0, 17),
        ]),
      );
    });

    test('VERT_4: four 4x16 strips', () async {
      final emits = await run(6, 4, 4, {(0, 0, 6): vert4});
      expect(
        emits,
        equals(<(int, int, int)>[
          (0, 0, 16),
          (0, 1, 16),
          (0, 2, 16),
          (0, 3, 16),
        ]),
      );
    });
  });
}
