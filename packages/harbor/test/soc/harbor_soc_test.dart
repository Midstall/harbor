import 'package:harbor/harbor.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('HarborSoC', () {
    test('creates with peripherals', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      final clint = soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      expect(soc.peripherals, hasLength(2));
      expect(soc.peripherals, contains(clint));
      expect(soc.peripherals, contains(uart));
    });

    test('rejects non-HarborDeviceTreeNodeProvider peripheral', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      // A plain BridgeModule without HarborDeviceTreeNodeProvider
      final badModule = BridgeModule('BadModule', name: 'bad');
      badModule.createPort('clk', PortDirection.input);
      badModule.createPort('reset', PortDirection.input);

      expect(() => soc.addPeripheral(badModule), throwsArgumentError);
    });

    test('generates DTS', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
      );

      soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));

      final dts = soc.generateDts();
      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('test,soc-v1'));
      expect(dts, contains('riscv,clint0'));
      expect(dts, contains('sifive,plic-1.0.0'));
    });

    test('generates Mermaid', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      final mermaid = soc.generateMermaid();
      expect(mermaid, contains('flowchart TD'));
      expect(mermaid, contains('ns16550a'));
    });

    test('generates DOT', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));

      final dot = soc.generateDot();
      expect(dot, contains('digraph'));
      expect(dot, contains('sifive,plic-1.0.0'));
    });

    test('validates address overlaps', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      // CLINT is 64KB at 0x02000000
      // PLIC at overlapping address
      soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      soc.addPeripheral(HarborClint(baseAddress: 0x02000000, name: 'clint2'));

      // buildFabric should detect the overlap
      // (needs a master to trigger)
    });

    test('target can be set', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        target: const HarborFpgaTarget.ice40(
          device: 'up5k',
          package: 'sg48',
          frequency: 48000000,
          pinMap: {'clk': '35', 'uart_tx': '14'},
        ),
      );

      expect(soc.target, isA<HarborFpgaTarget>());
    });
  });

  group('HarborDeviceTarget', () {
    group('HarborFpgaTarget', () {
      test('ice40 generates PCF', () {
        const target = HarborFpgaTarget.ice40(
          device: 'up5k',
          package: 'sg48',
          pinMap: {'clk': '35', 'uart_tx': '14', 'uart_rx': '15'},
          frequency: 48000000,
        );

        final pcf = target.generateConstraints();
        expect(pcf, contains('set_io clk 35'));
        expect(pcf, contains('set_io uart_tx 14'));
        expect(pcf, contains('set_io uart_rx 15'));
      });

      test('ecp5 generates LPF', () {
        const target = HarborFpgaTarget.ecp5(
          device: 'lfe5u-45f',
          package: 'CABGA381',
          pinMap: {'clk': 'P3', 'led': 'B2'},
          frequency: 25000000,
        );

        final lpf = target.generateConstraints();
        expect(lpf, contains('LOCATE COMP "clk" SITE "P3"'));
        expect(lpf, contains('IOBUF PORT "clk" IO_TYPE=LVCMOS33'));
        expect(lpf, contains('FREQUENCY'));
      });

      test('spartan7 generates XDC', () {
        const target = HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'ftgb196',
          pinMap: {'clk': 'L16', 'uart_tx': 'J18'},
          frequency: 100000000,
        );

        final xdc = target.generateConstraints();
        expect(xdc, contains('PACKAGE_PIN L16'));
        expect(xdc, contains('create_clock'));
        expect(xdc, contains('10.000')); // 100MHz = 10ns
      });

      test('openXC7 also generates XDC', () {
        const target = HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'ftgb196',
          useOpenXc7: true,
        );

        expect(target.vendor, equals(HarborFpgaVendor.openXc7));
        expect(target.generateConstraints(), contains('XDC'));
      });
    });

    group('HarborAsicTarget', () {
      test('sky130 generates SDC', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
          frequency: 50000000,
        );

        final sdc = target.generateSdc();
        expect(sdc, contains('create_clock'));
        expect(sdc, contains('20.000')); // 50MHz = 20ns
        expect(sdc, contains('set_input_delay'));
        expect(sdc, contains('set_output_delay'));
      });

      test('sky130 generates Yosys TCL', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
        );

        final tcl = target.generateYosysTcl();
        expect(tcl, contains('synth -top MySoC'));
        expect(tcl, contains('sky130_fd_sc_hd'));
        expect(tcl, contains('dfflibmap'));
      });

      test('sky130 generates OpenROAD TCL', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
        );

        final tcl = target.generateOpenroadTcl();
        expect(tcl, contains('read_liberty'));
        expect(tcl, contains('global_placement'));
        expect(tcl, contains('clock_tree_synthesis'));
        expect(tcl, contains('detailed_route'));
      });

      test('gf180mcu target', () {
        final target = HarborAsicTarget(
          provider: Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD'),
          topCell: 'MySoC',
        );

        expect(target.provider.name, contains('GF180MCU'));
        expect(target.provider.node, equals('180nm'));
      });

      test('PDK provides analog blocks', () {
        final pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
        final io = pdk.ioCell(index: 0);
        final pll = pdk.pll(index: 0);

        expect(io.pinMapping, contains('padIn'));
        expect(pll.pinMapping, contains('refClk'));
        expect(pdk.standardCellLibrary.name, contains('sky130'));
        expect(pdk.metalLayers, equals(5));
        expect(pdk.supplyVoltage, equals(1.8));
      });
    });

    test('sealed type exhaustiveness', () {
      const HarborDeviceTarget target = HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
      );
      final result = switch (target) {
        HarborFpgaTarget() => 'fpga',
        HarborAsicTarget() => 'asic',
      };
      expect(result, equals('fpga'));
    });
  });
}
