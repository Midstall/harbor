import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _txType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraModeTxType', () {
    late HarborIntraModeTxType p;
    late Logic clk, mode;

    Future<void> setUpDut() async {
      p = HarborIntraModeTxType();
      clk = SimpleClockGenerator(10).clk;
      mode = Logic(name: 'intra_mode', width: 4);
      p.input('intra_mode').srcConnection! <= mode;
      await p.build();
      mode.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('maps each intra mode to its tx type and direction selects', () async {
      await setUpDut();
      for (var m = 0; m < 13; m++) {
        mode.inject(m);
        await clk.nextPosedge;
        final tt = _txType[m];
        expect(
          p.output('tx_type').value.toInt(),
          equals(tt),
          reason: 'mode $m',
        );
        expect(
          p.output('v_type').value.toInt(),
          equals(tt & 1),
          reason: 'v $m',
        );
        expect(
          p.output('h_type').value.toInt(),
          equals((tt >> 1) & 1),
          reason: 'h $m',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
