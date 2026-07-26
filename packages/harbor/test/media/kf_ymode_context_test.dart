import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ctx = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborKfYModeContext', () {
    late HarborKfYModeContext p;
    late Logic clk, above, left;

    Future<void> setUpDut() async {
      p = HarborKfYModeContext();
      clk = SimpleClockGenerator(10).clk;
      above = Logic(name: 'above_mode', width: 4);
      left = Logic(name: 'left_mode', width: 4);
      p.input('above_mode').srcConnection! <= above;
      p.input('left_mode').srcConnection! <= left;
      await p.build();
      above.inject(0);
      left.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('maps all neighbour mode pairs through Intra_Mode_Context', () async {
      await setUpDut();
      for (var a = 0; a < 13; a++) {
        for (var l = 0; l < 13; l++) {
          above.inject(a);
          left.inject(l);
          await clk.nextPosedge;
          expect(
            p.output('above_ctx').value.toInt(),
            equals(_ctx[a]),
            reason: 'above $a',
          );
          expect(
            p.output('left_ctx').value.toInt(),
            equals(_ctx[l]),
            reason: 'left $l',
          );
        }
      }
      await Simulator.endSimulation();
    });
  });
}
