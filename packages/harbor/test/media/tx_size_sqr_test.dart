import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _sqr = [0, 1, 2, 3, 4, 0, 0, 1, 1, 2, 2, 3, 3, 0, 0, 1, 1, 2, 2];
const _sqrUp = [0, 1, 2, 3, 4, 1, 1, 2, 2, 3, 3, 4, 4, 2, 2, 3, 3, 4, 4];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborTxSizeSqr', () {
    late HarborTxSizeSqr p;
    late Logic clk, tx;

    Future<void> setUpDut() async {
      p = HarborTxSizeSqr();
      clk = SimpleClockGenerator(10).clk;
      tx = Logic(name: 'tx_size', width: 5);
      p.input('tx_size').srcConnection! <= tx;
      await p.build();
      tx.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('maps every tx size to its square / square-up', () async {
      await setUpDut();
      for (var i = 0; i < _sqr.length; i++) {
        tx.inject(i);
        await clk.nextPosedge;
        expect(
          p.output('tx_size_sqr').value.toInt(),
          equals(_sqr[i]),
          reason: 'sqr $i',
        );
        expect(
          p.output('tx_size_sqr_up').value.toInt(),
          equals(_sqrUp[i]),
          reason: 'sqr_up $i',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
