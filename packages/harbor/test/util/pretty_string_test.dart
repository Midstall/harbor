import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborPrettyString', () {
    test('HarborDeviceTreeNode toPrettyString', () {
      final node = HarborDeviceTreeNode(
        compatible: ['ns16550a'],
        reg: BusAddressRange(0x10000000, 0x1000),
        interrupts: [1],
        properties: {'clock-frequency': 48000000},
      );

      final pretty = node.toPrettyString();
      expect(pretty, contains('HarborDeviceTreeNode('));
      expect(pretty, contains('  compatible: ns16550a,'));
      expect(pretty, contains('  reg: 0x10000000'));
      expect(pretty, contains('  interrupts: [1],'));
      expect(pretty, contains('  clock-frequency: 48000000,'));
      expect(pretty, contains(')'));
    });

    test('HarborDeviceTreeNode toPrettyString with custom indent', () {
      final node = HarborDeviceTreeNode(
        compatible: ['riscv,clint0'],
        reg: BusAddressRange(0x02000000, 0x10000),
      );

      final pretty = node.toPrettyString(
        const HarborPrettyStringOptions(indent: '    '),
      );
      expect(pretty, contains('    compatible: riscv,clint0,'));
    });

    test('HarborDeviceTreeNode toPrettyString nested', () {
      final node = HarborDeviceTreeNode(
        compatible: ['sifive,plic-1.0.0'],
        reg: BusAddressRange(0x0C000000, 0x4000000),
        interruptController: true,
        interruptCells: 1,
      );

      final pretty = node.toPrettyString(
        const HarborPrettyStringOptions(depth: 1),
      );
      // Should be indented one level
      expect(pretty, startsWith('  HarborDeviceTreeNode('));
      expect(pretty, contains('    compatible:'));
    });

    test('HarborCpu toPrettyString', () {
      const cpu = HarborCpu(
        hartId: 0,
        isa: 'rv64imac',
        mmu: 'riscv,sv39',
        clockFrequency: 100000000,
      );

      final pretty = cpu.toPrettyString();
      expect(pretty, contains('hartId: 0'));
      expect(pretty, contains('isa: rv64imac'));
      expect(pretty, contains('mmu: riscv,sv39'));
      expect(pretty, contains('clockFrequency: 100000000'));
    });

    test('WishboneConfig toPrettyString', () {
      const config = WishboneConfig(
        addressWidth: 32,
        dataWidth: 32,
        useErr: true,
        useCti: true,
      );

      final pretty = config.toPrettyString();
      expect(pretty, contains('addressWidth: 32'));
      expect(pretty, contains('dataWidth: 32'));
      expect(pretty, contains('useErr: true'));
      expect(pretty, contains('useCti: true'));
      expect(pretty, isNot(contains('useRty'))); // not set
    });

    test('TileLinkConfig toPrettyString', () {
      const config = TileLinkConfig(
        addressWidth: 32,
        dataWidth: 64,
        withBCE: true,
      );

      final pretty = config.toPrettyString();
      expect(pretty, contains('addressWidth: 32'));
      expect(pretty, contains('dataWidth: 64'));
      expect(pretty, contains('withBCE: true'));
    });

    test('StandardCellLibrary toPrettyString', () {
      final pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
      final lib = pdk.standardCellLibrary;

      final pretty = lib.toPrettyString();
      expect(pretty, contains('sky130_fd_sc_hd'));
      expect(pretty, contains('liberty:'));
      expect(pretty, contains('lef:'));
      expect(pretty, contains('clkBufs:'));
    });

    test('AnalogBlock toPrettyString', () {
      final pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
      final io = pdk.ioCell(index: 0);

      final pretty = io.toPrettyString();
      expect(pretty, contains('AnalogBlock('));
      expect(pretty, contains('symbol:'));
      expect(pretty, contains('padIn -> PAD'));
    });
  });
}
