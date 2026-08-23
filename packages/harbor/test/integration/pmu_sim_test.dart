import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('PMU sim', () {
    test('write wakeup enable and read back', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // WAKEUP_EN byte offset 0x10
      await tb.write(0x10, 0x0F);
      final val = await tb.read(0x10);
      expect(val, equals(0x0F));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // CTRL byte offset 0x00: bit 0 = global enable, bits [5:4] = sleep mode
      // After reset global_enable is 1, write 0 to disable
      await tb.write(0x00, 0x00);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x00));

      // Re-enable with sleep mode = 1
      await tb.write(0x00, 0x11);
      final val2 = await tb.read(0x00);
      expect(val2 & 0x01, equals(0x01));
      expect((val2 >> 4) & 0x03, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write domain CTRL register (power off domain)', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // Domain 0 CTRL at byte 0x40 + 0*0x20 + 0x00.
      // Target state: 0 = off
      await tb.write(0x40, 0x00);
      final val = await tb.read(0x40);
      expect(val & 0x03, equals(0x00));

      await Simulator.endSimulation();
    });

    test('read domain STATUS register', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // Domain 0 STATUS at byte 0x40 + 0*0x20 + 0x08.
      // After reset domain state = on (2), target = on (2)
      final val = await tb.read(0x48);
      // State bits [1:0] should be 2 (on), busy bit 8 should be 0
      expect(val & 0x03, equals(HarborPowerDomainState.on.index));

      await Simulator.endSimulation();
    });

    test('read wakeup STATUS register', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // WAKEUP_STATUS byte offset 0x18
      final val = await tb.read(0x18);
      // After reset, no wakeup events
      expect(val, equals(0));

      await Simulator.endSimulation();
    });

    test('domainPower outputs change with register writes', () async {
      final pmu = HarborPowerManagementUnit(
        config: const HarborPmuConfig(
          domains: [
            HarborPowerDomain(name: 'core', index: 0),
            HarborPowerDomain(name: 'io', index: 1),
          ],
        ),
        baseAddress: 0x12000,
      );

      final tb = PeripheralTestBench(pmu);
      await tb.init();

      // After reset, domains are ON
      await tb.waitCycles(2);
      expect(pmu.domainPower[0].value.toInt(), equals(1));
      expect(pmu.domainPower[1].value.toInt(), equals(1));

      // Power off domain 1: DOM1 CTRL at byte 0x40 + 1*0x20 + 0x00 = 0x60.
      // Target state: 0 = off
      await tb.write(0x60, 0x00);
      // Wait for transition
      await tb.waitCycles(3);
      expect(pmu.domainPower[1].value.toInt(), equals(0));

      await Simulator.endSimulation();
    });
  });
}
