import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _table = [
  0,
  5,
  6,
  1,
  7,
  8,
  2,
  9,
  10,
  3,
  11,
  12,
  4,
  4,
  4,
  4,
  13,
  14,
  15,
  16,
  17,
  18,
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborMaxTxSize', () {
    late HarborMaxTxSize p;
    late Logic clk, bsize;

    Future<void> setUpDut() async {
      p = HarborMaxTxSize();
      clk = SimpleClockGenerator(10).clk;
      bsize = Logic(name: 'bsize', width: 5);
      p.input('bsize').srcConnection! <= bsize;
      await p.build();
      bsize.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('maps every block size to its max tx size', () async {
      await setUpDut();
      for (var b = 0; b < _table.length; b++) {
        bsize.inject(b);
        await clk.nextPosedge;
        expect(
          p.output('tx_size').value.toInt(),
          equals(_table[b]),
          reason: 'bsize $b',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
