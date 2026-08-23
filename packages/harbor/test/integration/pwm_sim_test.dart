import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('PWM sim', () {
    test('write global enable and read back', () async {
      final pwm = HarborPwmTimer(baseAddress: 0x7000);
      final tb = PeripheralTestBench(pwm);
      await tb.init();

      // GLOBAL_CTRL byte offset 0x00, bit 0 = global enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read INT_STATUS register', () async {
      final pwm = HarborPwmTimer(baseAddress: 0x7000);
      final tb = PeripheralTestBench(pwm);
      await tb.init();

      // INT_STATUS byte offset 0x08
      final val = await tb.read(0x08);
      // After reset, no interrupts pending
      expect(val, equals(0));

      await Simulator.endSimulation();
    });
  });
}
