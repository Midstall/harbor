import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('PCIe sim', () {
    test('write CTRL enable and read back', () async {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      pcie.port('wake_n').getsLogic(Const(1));
      for (var i = 0; i < 4; i++) {
        pcie.port('rxp_$i').getsLogic(Const(0));
        pcie.port('rxn_$i').getsLogic(Const(1));
      }
      // Tie off the unused ECAM port so its inputs are defined.
      pcie.port('ecam_CYC').getsLogic(Const(0));
      pcie.port('ecam_STB').getsLogic(Const(0));
      pcie.port('ecam_WE').getsLogic(Const(0));
      pcie.port('ecam_ADR').getsLogic(Const(0, width: 26));
      pcie.port('ecam_DAT_MOSI').getsLogic(Const(0, width: 32));
      pcie.port('ecam_SEL').getsLogic(Const(0, width: 4));
      // Tie off the downstream master port response.
      pcie.port('pcie_m_rdata').getsLogic(Const(0, width: 32));
      pcie.port('pcie_m_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(pcie);
      await tb.init();

      // CTRL word addr 0, bit 0 = enable
      await tb.write(0, 0x01);
      final val = await tb.read(0);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS', () async {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      pcie.port('wake_n').getsLogic(Const(1));
      for (var i = 0; i < 4; i++) {
        pcie.port('rxp_$i').getsLogic(Const(0));
        pcie.port('rxn_$i').getsLogic(Const(1));
      }
      // Tie off the unused ECAM port so its inputs are defined.
      pcie.port('ecam_CYC').getsLogic(Const(0));
      pcie.port('ecam_STB').getsLogic(Const(0));
      pcie.port('ecam_WE').getsLogic(Const(0));
      pcie.port('ecam_ADR').getsLogic(Const(0, width: 26));
      pcie.port('ecam_DAT_MOSI').getsLogic(Const(0, width: 32));
      pcie.port('ecam_SEL').getsLogic(Const(0, width: 4));
      // Tie off the downstream master port response.
      pcie.port('pcie_m_rdata').getsLogic(Const(0, width: 32));
      pcie.port('pcie_m_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(pcie);
      await tb.init();

      // STATUS word addr 1
      final val = await tb.read(1);
      // link_up bit 0 should be 0 after reset
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      pcie.port('wake_n').getsLogic(Const(1));
      for (var i = 0; i < 4; i++) {
        pcie.port('rxp_$i').getsLogic(Const(0));
        pcie.port('rxn_$i').getsLogic(Const(1));
      }
      // Tie off the unused ECAM port so its inputs are defined.
      pcie.port('ecam_CYC').getsLogic(Const(0));
      pcie.port('ecam_STB').getsLogic(Const(0));
      pcie.port('ecam_WE').getsLogic(Const(0));
      pcie.port('ecam_ADR').getsLogic(Const(0, width: 26));
      pcie.port('ecam_DAT_MOSI').getsLogic(Const(0, width: 32));
      pcie.port('ecam_SEL').getsLogic(Const(0, width: 4));
      // Tie off the downstream master port response.
      pcie.port('pcie_m_rdata').getsLogic(Const(0, width: 32));
      pcie.port('pcie_m_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(pcie);
      await tb.init();

      // INT_ENABLE word addr 4 (0x010 >> 2)
      await tb.write(4, 0xAB);
      final val = await tb.read(4);
      expect(val, equals(0xAB));

      await Simulator.endSimulation();
    });

    test('write LINK_CTRL and read back', () async {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      pcie.port('wake_n').getsLogic(Const(1));
      for (var i = 0; i < 4; i++) {
        pcie.port('rxp_$i').getsLogic(Const(0));
        pcie.port('rxn_$i').getsLogic(Const(1));
      }
      // Tie off the unused ECAM port so its inputs are defined.
      pcie.port('ecam_CYC').getsLogic(Const(0));
      pcie.port('ecam_STB').getsLogic(Const(0));
      pcie.port('ecam_WE').getsLogic(Const(0));
      pcie.port('ecam_ADR').getsLogic(Const(0, width: 26));
      pcie.port('ecam_DAT_MOSI').getsLogic(Const(0, width: 32));
      pcie.port('ecam_SEL').getsLogic(Const(0, width: 4));
      // Tie off the downstream master port response.
      pcie.port('pcie_m_rdata').getsLogic(Const(0, width: 32));
      pcie.port('pcie_m_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(pcie);
      await tb.init();

      // LINK_CTRL word addr 2 (0x008 >> 2) - currently read-only, returns 0
      final val = await tb.read(2);
      expect(val, equals(0));

      await Simulator.endSimulation();
    });

    test('write BAR0_BASE and read back', () async {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      pcie.port('wake_n').getsLogic(Const(1));
      for (var i = 0; i < 4; i++) {
        pcie.port('rxp_$i').getsLogic(Const(0));
        pcie.port('rxn_$i').getsLogic(Const(1));
      }
      // Tie off the unused ECAM port so its inputs are defined.
      pcie.port('ecam_CYC').getsLogic(Const(0));
      pcie.port('ecam_STB').getsLogic(Const(0));
      pcie.port('ecam_WE').getsLogic(Const(0));
      pcie.port('ecam_ADR').getsLogic(Const(0, width: 26));
      pcie.port('ecam_DAT_MOSI').getsLogic(Const(0, width: 32));
      pcie.port('ecam_SEL').getsLogic(Const(0, width: 4));
      // Tie off the downstream master port response.
      pcie.port('pcie_m_rdata').getsLogic(Const(0, width: 32));
      pcie.port('pcie_m_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(pcie);
      await tb.init();

      // BAR0_BASE word addr 8 (0x020 >> 2)
      await tb.write(8, 0xC0000000);
      final val = await tb.read(8);
      expect(val, equals(0xC0000000));

      await Simulator.endSimulation();
    });
  });
}
