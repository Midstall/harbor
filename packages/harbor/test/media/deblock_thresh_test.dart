import 'dart:async';

import 'package:harbor/src/media/deblock_thresh.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden mirroring the SW reference deblock `_buildThresholds`, evaluated for a
// single (lvl, sharpness) pair. Returns [mblim, lim, hevThr].
List<int> golden(int lvl, int sharpness) {
  int blockInsideLimit =
      lvl >> ((sharpness > 0 ? 1 : 0) + (sharpness > 4 ? 1 : 0));
  if (sharpness > 0) {
    if (blockInsideLimit > (9 - sharpness)) blockInsideLimit = 9 - sharpness;
  }
  if (blockInsideLimit < 1) blockInsideLimit = 1;
  final lim = blockInsideLimit;
  final mblim = 2 * (lvl + 2) + blockInsideLimit;
  final hevThr = lvl >> 4;
  return [mblim, lim, hevThr];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborDeblockThresh matches _buildThresholds over all 64x8', () async {
    final t = HarborDeblockThresh();
    final clk = SimpleClockGenerator(10).clk;
    final level = Logic(name: 'level', width: 6);
    final sharpness = Logic(name: 'sharpness', width: 3);
    t.input('level').srcConnection! <= level;
    t.input('sharpness').srcConnection! <= sharpness;

    await t.build();
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    for (var lvl = 0; lvl <= 63; lvl++) {
      for (var sh = 0; sh <= 7; sh++) {
        level.put(lvl);
        sharpness.put(sh);
        await clk.nextPosedge;
        final want = golden(lvl, sh);
        final got = [
          t.output('mblim').value.toInt(),
          t.output('lim').value.toInt(),
          t.output('hev').value.toInt(),
        ];
        expect(got, equals(want), reason: 'lvl=$lvl sharpness=$sh');
      }
    }
    await Simulator.endSimulation();
  });
}
