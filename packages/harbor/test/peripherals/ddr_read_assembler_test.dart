import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Future<int> runSelect(int beatSel) async {
    await Simulator.reset();
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final beatWord = Logic(width: 32)..inject(0);
    final rdStart = Logic()..inject(0);
    final bsel = Logic(width: 2)..inject(beatSel);
    final windowOpen = Logic()..inject(0);
    final dut = DdrReadWordAssembler(
      clk,
      reset,
      beatWord: beatWord,
      rdStart: rdStart,
      beatSel: bsel,
      windowOpen: windowOpen,
    );
    await dut.build();
    Simulator.setMaxSimTime(3000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    // Read command: latch beatSel.
    rdStart.inject(1);
    await clk.nextPosedge;
    rdStart.inject(0);
    // Open the window, feed 4 distinctive words on the 4 capture cycles.
    const words = [0x11110000, 0x22221111, 0x33332222, 0x44443333];
    windowOpen.inject(1);
    for (var i = 0; i < 4; i++) {
      beatWord.inject(words[i]);
      await clk.nextPosedge;
      if (i == 0) windowOpen.inject(0);
    }
    await clk.nextNegedge;
    final data = dut.rdData.value.toInt();
    final valid = dut.rdValid.value.toInt();
    await Simulator.endSimulation();
    expect(valid, 1);
    return data;
  }

  test('assembler selects each of the 4 BL8 words by beatSel', () async {
    expect(await runSelect(0), 0x11110000);
  });

  test(
    'streaming repro: each beatSel picks its own word, no collapse',
    () async {
      final results = [for (var b = 0; b < 4; b++) await runSelect(b)];
      expect(results, [0x11110000, 0x22221111, 0x33332222, 0x44443333]);
      // Regression guard for #142: the 4 selected words are DISTINCT (a
      // static-DQ collapse would replicate one value / make hi16==lo16).
      expect(results.toSet().length, 4);
      for (final w in results) {
        expect(w >> 16, isNot(equals(w & 0xFFFF)));
      }
    },
  );
}
