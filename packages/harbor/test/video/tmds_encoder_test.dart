import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the DVI 1.0 TMDS encoder against spec-derived vectors.
///
/// Control codes (DE low) are the four fixed 10-bit symbols. Data vectors and
/// the running-disparity behavior are derived by hand from the DVI 1.0
/// encoding algorithm (Figure 3-5):
///   - D=0x00 with disparity 0 encodes to 0x100, leaving disparity -8.
///   - feeding D=0x00 again (disparity -8) balances to 0x3FF.
void main() {
  late Logic clk, reset, de, data, ctrl;
  late TmdsEncoder enc;

  Future<void> setup() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    de = Logic(name: 'de');
    data = Logic(name: 'data', width: 8);
    ctrl = Logic(name: 'ctrl', width: 2);
    enc = TmdsEncoder(clk: clk, reset: reset, de: de, data: data, ctrl: ctrl);
    await enc.build();

    reset.inject(1);
    de.inject(0);
    data.inject(0);
    ctrl.inject(0);
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
  }

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  group('control period (DE low)', () {
    test('emits the four fixed control symbols', () async {
      await setup();
      const expected = {0: 0x354, 1: 0x0AB, 2: 0x154, 3: 0x2AB};
      for (final entry in expected.entries) {
        de.inject(0);
        ctrl.inject(entry.key);
        await clk.nextNegedge;
        expect(
          enc.q.value.toInt(),
          equals(entry.value),
          reason: 'ctrl=${entry.key}',
        );
      }
    });
  });

  group('data period (DE high)', () {
    test('D=0 then D=0 balances disparity (0x100 then 0x3FF)', () async {
      await setup();
      de.inject(1);
      data.inject(0);
      ctrl.inject(0);

      // First pixel: disparity starts at 0.
      await clk.nextNegedge;
      expect(enc.q.value.toInt(), equals(0x100));

      // Second pixel: disparity is now -8, so the symbol is inverted.
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(enc.q.value.toInt(), equals(0x3FF));
    });

    test('D=0xFF at disparity 0 encodes to 0x200 (XNOR path)', () async {
      await setup();
      de.inject(1);
      data.inject(0xFF);
      ctrl.inject(0);
      await clk.nextNegedge;
      expect(enc.q.value.toInt(), equals(0x200));
    });
  });
}
