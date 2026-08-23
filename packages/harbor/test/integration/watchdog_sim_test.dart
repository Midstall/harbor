import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Watchdog sim', () {
    test('write and read timeout register', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      // TIMEOUT is byte offset 0x10
      await tb.write(0x10, 5000);
      final val = await tb.read(0x10);
      expect(val, equals(5000));

      await Simulator.endSimulation();
    });

    test('enable via CTRL and read back', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      // CTRL byte offset 0x00: bit 0=enable, bit 1=reset_en
      await tb.write(0x00, 0x03);
      final val = await tb.read(0x00);
      expect(val & 0x03, equals(0x03));

      await Simulator.endSimulation();
    });

    test('counter increments when enabled', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      // Set a large timeout so it doesn't expire
      await tb.write(0x10, 99999);
      // Enable
      await tb.write(0x00, 0x01);

      await tb.waitCycles(5);
      final count1 = await tb.read(0x28); // COUNT byte offset 0x28

      await tb.waitCycles(10);
      final count2 = await tb.read(0x28);

      expect(count2, greaterThan(count1));

      await Simulator.endSimulation();
    });

    test('kick resets counter', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      await tb.write(0x10, 99999);
      await tb.write(0x00, 0x01); // enable

      await tb.waitCycles(20);
      final countBefore = await tb.read(0x28);
      expect(countBefore, greaterThan(0));

      // KICK byte offset 0x20, magic value
      await tb.write(0x20, 0x4B494B);
      await tb.waitCycles(2);

      final countAfter = await tb.read(0x28);
      expect(countAfter, lessThan(countBefore));

      await Simulator.endSimulation();
    });

    test('disabling stops counter', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      await tb.write(0x10, 99999);
      await tb.write(0x00, 0x01); // enable
      await tb.waitCycles(10);

      // Disable
      await tb.write(0x00, 0x00);
      await tb.waitCycles(2);

      final count1 = await tb.read(0x28);
      await tb.waitCycles(5);
      final count2 = await tb.read(0x28);

      expect(count2, equals(count1));

      await Simulator.endSimulation();
    });

    test('read timeout after write large value', () async {
      final wdt = HarborWatchdog(baseAddress: 0x2000);
      final tb = PeripheralTestBench(wdt);
      await tb.init();

      await tb.write(0x10, 99999);
      final val = await tb.read(0x10);
      expect(val, equals(99999));

      await Simulator.endSimulation();
    });
  });
}
