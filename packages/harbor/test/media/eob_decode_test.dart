import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Goldens captured from the bit-exact software range coder + adaptive CDFs
// (read_coeffs_txb eob path) for the 200 seeded iterations below.
const _golden = <({int allZero, int eob})>[
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 7),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 8),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 15),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 7),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 8),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 15),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 7),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 13),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 7),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 6),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 15),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 5),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 6),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 5),
  (allZero: 1, eob: 0),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 1),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 9),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 11),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 8),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 13),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 3),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 14),
  (allZero: 0, eob: 12),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 10),
  (allZero: 0, eob: 15),
  (allZero: 0, eob: 16),
  (allZero: 0, eob: 14),
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 32;

  group('HarborEobDecode', () {
    late HarborEobDecode t;
    late Logic clk, reset, start, bytes;

    Future<void> setUpDut() async {
      t = HarborEobDecode(maxBytes: maxBytes);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      start = Logic(name: 'start');
      bytes = Logic(name: 'bytes', width: maxBytes * 8);
      t.input('clk').srcConnection! <= clk;
      t.input('reset').srcConnection! <= reset;
      t.input('start').srcConnection! <= start;
      t.input('bytes').srcConnection! <= bytes;
      await t.build();
      reset.inject(1);
      start.inject(0);
      bytes.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    BigInt packBytes(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xff) << (i * 8);
      }
      return v;
    }

    test('matches libaom eob decode over random coded bytes', () async {
      await setUpDut();
      final rng = Random(0xE0B);
      for (var iter = 0; iter < 200; iter++) {
        final b = [for (var i = 0; i < maxBytes; i++) rng.nextInt(256)];
        final want = _golden[iter];

        bytes.inject(packBytes(b));
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (t.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 200) fail('timeout iter=$iter');
        }
        final gotAllZero = t.output('all_zero').value.toInt();
        final gotEob = t.output('eob').value.toInt();
        expect(gotAllZero, want.allZero, reason: 'all_zero iter=$iter');
        expect(gotEob, want.eob, reason: 'eob iter=$iter (bytes=$b)');
        await clk.nextPosedge; // back to idle
      }
      await Simulator.endSimulation();
    });
  });
}
