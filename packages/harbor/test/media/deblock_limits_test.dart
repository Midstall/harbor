import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

(int, int, int) _limits(int lvl, int sharpness) {
  var bil = sharpness != 0 ? lvl >> (1 + (sharpness > 4 ? 1 : 0)) : lvl;
  final cap = 9 - sharpness;
  if (bil > cap) bil = cap;
  if (bil < 1) bil = 1;
  final limit = bil;
  final blimit = 2 * (lvl + 2) + bil;
  final thresh = lvl >> 4;
  return (blimit, limit, thresh);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDeblockLimits', () {
    late HarborDeblockLimits dl;
    late Logic clk, lvl, sharp;

    Future<void> setUpDut() async {
      dl = HarborDeblockLimits();
      clk = SimpleClockGenerator(10).clk;
      lvl = Logic(name: 'filter_level', width: 6);
      sharp = Logic(name: 'sharpness', width: 3);
      dl.input('filter_level').srcConnection! <= lvl;
      dl.input('sharpness').srcConnection! <= sharp;
      await dl.build();
      lvl.inject(0);
      sharp.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    // Sweep representative filter levels against every sharpness.
    final levels = [0, 1, 4, 8, 16, 31, 47, 63];
    for (final L in levels) {
      for (var S = 0; S < 8; S++) {
        test('level $L sharpness $S', () async {
          await setUpDut();
          lvl.inject(L);
          sharp.inject(S);
          await clk.nextPosedge;
          final got = (
            dl.output('blimit').value.toInt(),
            dl.output('limit').value.toInt(),
            dl.output('thresh').value.toInt(),
          );
          expect(got, equals(_limits(L, S)), reason: 'level $L sharpness $S');
          await Simulator.endSimulation();
        });
      }
    }
  });
}
