import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden y_mode values for the 300 seeded iterations below, captured from the
// reference libaom read_kf_y_mode decode.
const _wants = [
  2,
  8,
  11,
  7,
  1,
  9,
  1,
  9,
  4,
  11,
  7,
  4,
  4,
  1,
  2,
  6,
  2,
  2,
  1,
  1,
  6,
  4,
  2,
  7,
  7,
  5,
  1,
  2,
  0,
  2,
  12,
  7,
  9,
  7,
  7,
  2,
  0,
  8,
  5,
  2,
  6,
  0,
  7,
  9,
  0,
  9,
  5,
  3,
  2,
  2,
  2,
  0,
  0,
  7,
  1,
  0,
  1,
  7,
  2,
  7,
  9,
  7,
  9,
  8,
  9,
  7,
  2,
  9,
  5,
  6,
  7,
  2,
  1,
  2,
  9,
  0,
  2,
  0,
  2,
  7,
  4,
  7,
  0,
  3,
  1,
  9,
  0,
  7,
  0,
  9,
  2,
  1,
  9,
  0,
  12,
  2,
  9,
  2,
  1,
  12,
  0,
  8,
  0,
  1,
  0,
  0,
  9,
  9,
  1,
  5,
  0,
  9,
  2,
  6,
  2,
  0,
  7,
  9,
  0,
  6,
  0,
  0,
  12,
  11,
  0,
  10,
  9,
  0,
  2,
  0,
  0,
  9,
  2,
  0,
  0,
  9,
  2,
  7,
  0,
  8,
  9,
  0,
  11,
  8,
  9,
  6,
  11,
  1,
  2,
  0,
  3,
  4,
  11,
  11,
  12,
  9,
  3,
  11,
  2,
  7,
  9,
  6,
  10,
  0,
  9,
  5,
  2,
  0,
  0,
  2,
  2,
  1,
  4,
  5,
  2,
  11,
  8,
  0,
  2,
  9,
  0,
  0,
  2,
  0,
  0,
  0,
  1,
  3,
  2,
  9,
  7,
  0,
  2,
  0,
  9,
  1,
  0,
  0,
  10,
  0,
  0,
  4,
  12,
  0,
  0,
  0,
  2,
  5,
  3,
  2,
  8,
  7,
  2,
  7,
  4,
  1,
  0,
  7,
  6,
  8,
  0,
  0,
  10,
  3,
  0,
  0,
  2,
  0,
  9,
  3,
  1,
  6,
  7,
  9,
  6,
  0,
  6,
  9,
  0,
  6,
  7,
  8,
  3,
  0,
  1,
  2,
  0,
  5,
  0,
  1,
  7,
  10,
  1,
  1,
  4,
  2,
  4,
  12,
  9,
  7,
  5,
  9,
  0,
  4,
  0,
  6,
  1,
  0,
  9,
  0,
  8,
  1,
  7,
  3,
  0,
  6,
  2,
  0,
  7,
  8,
  0,
  12,
  3,
  0,
  0,
  0,
  0,
  6,
  10,
  5,
  8,
  7,
  7,
  0,
  9,
  0,
  0,
  0,
  1,
  7,
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 16;

  test('HarborKfYModeDecode matches libaom read_kf_y_mode', () async {
    final t = HarborKfYModeDecode(maxBytes: maxBytes);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final bytes = Logic(name: 'bytes', width: maxBytes * 8);
    final aboveMode = Logic(name: 'above_mode', width: 4);
    final leftMode = Logic(name: 'left_mode', width: 4);
    t.input('clk').srcConnection! <= clk;
    t.input('reset').srcConnection! <= reset;
    t.input('start').srcConnection! <= start;
    t.input('bytes').srcConnection! <= bytes;
    t.input('above_mode').srcConnection! <= aboveMode;
    t.input('left_mode').srcConnection! <= leftMode;
    await t.build();
    reset.inject(1);
    start.inject(0);
    bytes.inject(0);
    aboveMode.inject(0);
    leftMode.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    BigInt packBytes(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xff) << (i * 8);
      }
      return v;
    }

    final rng = Random(0x4F1);
    for (var iter = 0; iter < 300; iter++) {
      final b = [for (var i = 0; i < maxBytes; i++) rng.nextInt(256)];
      final am = rng.nextInt(13);
      final lm = rng.nextInt(13);
      final want = _wants[iter];

      bytes.inject(packBytes(b));
      aboveMode.inject(am);
      leftMode.inject(lm);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (t.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 100) fail('timeout iter=$iter');
      }
      expect(
        t.output('y_mode').value.toInt(),
        want,
        reason: 'iter=$iter am=$am lm=$lm',
      );
      await clk.nextPosedge;
    }
    await Simulator.endSimulation();
  });
}
