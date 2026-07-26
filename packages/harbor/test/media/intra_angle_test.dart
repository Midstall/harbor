import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _base = [0, 90, 180, 45, 135, 113, 157, 203, 67, 0, 0, 0, 0];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraAngle', () {
    late HarborIntraAngle p;
    late Logic clk, mode, delta;

    Future<void> setUpDut() async {
      p = HarborIntraAngle();
      clk = SimpleClockGenerator(10).clk;
      mode = Logic(name: 'mode', width: 4);
      delta = Logic(name: 'angle_delta', width: 3);
      p.input('mode').srcConnection! <= mode;
      p.input('angle_delta').srcConnection! <= delta;
      await p.build();
      mode.inject(0);
      delta.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('computes directional angle = base + delta*3', () async {
      await setUpDut();
      for (var m = 0; m < 13; m++) {
        for (var d = -3; d <= 3; d++) {
          mode.inject(m);
          delta.inject(d & 0x7);
          await clk.nextPosedge;
          final isDir = m >= 1 && m <= 8;
          final expAngle = isDir ? _base[m] + d * 3 : 0;
          expect(
            p.output('angle').value.toInt(),
            equals(expAngle),
            reason: 'mode $m delta $d',
          );
          expect(
            p.output('is_directional').value.toInt(),
            equals(isDir ? 1 : 0),
            reason: 'mode $m dir',
          );
        }
      }
      await Simulator.endSimulation();
    });
  });
}
