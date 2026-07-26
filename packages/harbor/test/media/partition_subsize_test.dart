import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _table = {
  3: [3, 2, 1, 0, 31, 31, 31, 31, 31, 31],
  6: [6, 5, 4, 3, 5, 5, 4, 4, 17, 16],
  9: [9, 8, 7, 6, 8, 8, 7, 7, 19, 18],
  12: [12, 11, 10, 9, 11, 11, 10, 10, 21, 20],
  15: [15, 14, 13, 12, 14, 14, 13, 13, 31, 31],
};

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPartitionSubsize', () {
    late HarborPartitionSubsize p;
    late Logic clk, partition, bsize;

    Future<void> setUpDut() async {
      p = HarborPartitionSubsize();
      clk = SimpleClockGenerator(10).clk;
      partition = Logic(name: 'partition', width: 4);
      bsize = Logic(name: 'bsize', width: 5);
      p.input('partition').srcConnection! <= partition;
      p.input('bsize').srcConnection! <= bsize;
      await p.build();
      partition.inject(0);
      bsize.inject(3);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('matches Partition_Subsize for all square sizes', () async {
      await setUpDut();
      for (final bs in [3, 6, 9, 12, 15]) {
        for (var part = 0; part < 10; part++) {
          bsize.inject(bs);
          partition.inject(part);
          await clk.nextPosedge;
          expect(
            p.output('subsize').value.toInt(),
            equals(_table[bs]![part]),
            reason: 'bsize $bs partition $part',
          );
        }
      }
      // A non-square / unsupported size returns BLOCK_INVALID.
      bsize.inject(4); // 8x16
      partition.inject(0);
      await clk.nextPosedge;
      expect(p.output('subsize').value.toInt(), equals(31));
      await Simulator.endSimulation();
    });
  });
}
