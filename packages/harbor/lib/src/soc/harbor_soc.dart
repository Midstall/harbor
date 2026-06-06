import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/wishbone/wishbone_decoder.dart';
import '../bus/wishbone/wishbone_interface.dart';
import '../clock/clock_domain.dart';
import '../pdk/klayout.dart';
import 'device_tree.dart';
import 'graph.dart';
import 'target.dart';

/// A composable SoC built on rohd_bridge.
///
/// Provides a declarative API for assembling a RISC-V SoC: add
/// peripherals and bus masters, and [HarborSoC] auto-wires them
/// through a bus decoder. For custom topology, drop down to
/// rohd_bridge's [addSubModule], [connectInterfaces], and
/// [connectPorts] directly.
///
/// ```dart
/// final soc = HarborSoC(
///   name: 'MySoC',
///   compatible: 'midstall,creek-v1',
///   busConfig: WishboneConfig(addressWidth: 32, dataWidth: 32),
/// );
///
/// // Declarative - auto-wired by address
/// soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
/// soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));
/// soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
///
/// // Expose UART pins at SoC level
/// soc.exposePin(uart, 'tx');
/// soc.exposePin(uart, 'rx');
///
/// // Add a bus master (CPU)
/// soc.addMaster(myRiverCore);
///
/// // Build the bus fabric (decoder + wiring)
/// soc.buildFabric();
///
/// // Generate outputs
/// await soc.buildAndGenerateRTL();
/// File('soc.dts').writeAsStringSync(soc.generateDts());
/// File('soc.dot').writeAsStringSync(soc.generateDot());
/// ```
class HarborSoC extends BridgeModule {
  /// Root `compatible` string for the device tree.
  final String compatible;

  /// Bus configuration for the fabric.
  final Object busConfig;

  /// CPU information for the device tree.
  final List<HarborDeviceTreeCpu> cpus;

  /// Build target (FPGA or ASIC). Controls what scripts are generated.
  final HarborDeviceTarget? target;

  final List<_PeripheralEntry> _peripherals = [];
  final List<_MasterEntry> _masters = [];

  late final HarborClockGenerator _clockGen;
  final Map<String, HarborClockDomain> _clockDomains = {};

  /// Creates a new SoC.
  ///
  /// Accepts an optional list of [clocks] to generate PLL-derived
  /// clock domains. If empty, the external `clk` input is used directly.
  HarborSoC({
    required String name,
    required this.compatible,
    required this.busConfig,
    this.cpus = const [],
    this.target,
    List<HarborClockConfig> clocks = const [],
  }) : super(name, name: name) {
    createPort('clk', PortDirection.input);

    final hasClockDomains = clocks.isNotEmpty;

    // Reset source is target-aware. FPGA targets with clock domains generate
    // an internal power-on reset: FPGA registers have a defined power-up
    // state of zero after configuration, so a counter self-starts at 0 and
    // holds reset asserted for its first 128 cycles, then releases forever
    // (it deliberately has no reset of its own: the power-up value is its
    // initializer). Everything else (FPGA SoCs without clock domains, ASIC
    // tapeouts whose flops have NO defined power-up state, and targetless/
    // simulation SoCs) gets a real external reset pin instead: the board,
    // PMIC, or testbench owns reset.
    // Without one of these, nonzero-reset state (such as a core's
    // reset-vector PC) never loads and the SoC wedges fetching from 0.
    final usePowerOnReset = hasClockDomains && target is HarborFpgaTarget;
    if (!usePowerOnReset) {
      createPort('reset', PortDirection.input);
    }

    final Logic resetSignal;
    if (usePowerOnReset) {
      final porCount = Logic(name: 'porCount', width: 8);
      Sequential(input('clk'), [
        If(~porCount[7], then: [porCount < porCount + 1]),
      ]);
      resetSignal = (~porCount[7]).named('porReset');
    } else {
      resetSignal = input('reset');
    }

    _clockGen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: resetSignal,
      target: target,
    );

    for (final clkConfig in clocks) {
      _clockDomains[clkConfig.name] = _clockGen.createDomain(clkConfig);
    }
  }

  /// Gets a clock domain by name.
  ///
  /// Returns null if no domain with that name exists. Falls back to
  /// the raw `clk`/`reset` inputs if no domains were configured.
  HarborClockDomain? clockDomain(String name) => _clockDomains[name];

  /// The default clock and reset signals.
  ///
  /// If clock domains are configured, returns the first domain.
  /// Otherwise returns the raw input clock and reset.
  (Logic clk, Logic reset) get defaultClock {
    if (_clockDomains.isNotEmpty) {
      final first = _clockDomains.values.first;
      return (first.clk, first.reset);
    }
    return (input('clk'), input('reset'));
  }

  /// All registered peripherals.
  List<BridgeModule> get peripherals =>
      _peripherals.map((e) => e.module).toList();

  /// All registered bus masters.
  List<BridgeModule> get masters => _masters.map((e) => e.module).toList();

  /// Adds a peripheral to the SoC.
  ///
  /// The peripheral must implement [HarborDeviceTreeNodeProvider] so
  /// the address mapping can be derived from its [HarborDeviceTreeNode.reg].
  ///
  /// Clock and reset are auto-wired. The bus interface is connected
  /// when [buildFabric] is called.
  T addPeripheral<T extends BridgeModule>(
    T peripheral, {
    String? clockDomainName,
  }) {
    if (peripheral is! HarborDeviceTreeNodeProvider) {
      throw ArgumentError(
        'Peripheral ${peripheral.name} must implement '
        'HarborDeviceTreeNodeProvider.',
      );
    }

    addSubModule(peripheral);

    final dt = (peripheral as HarborDeviceTreeNodeProvider).dtNode;
    _peripherals.add(
      _PeripheralEntry(module: peripheral, addressRange: dt.reg),
    );

    // Wire clock and reset from the specified domain or default
    final (
      clk,
      reset,
    ) = clockDomainName != null && _clockDomains.containsKey(clockDomainName)
        ? (
            _clockDomains[clockDomainName]!.clk,
            _clockDomains[clockDomainName]!.reset,
          )
        : defaultClock;

    peripheral.input('clk').srcConnection! <= clk;
    peripheral.input('reset').srcConnection! <= reset;

    return peripheral;
  }

  /// Adds a bus master (e.g., CPU core) to the SoC.
  ///
  /// [busInterfaceName] is the name of the master's Wishbone provider
  /// interface (default `'dataBus'`).
  ///
  /// Clock and reset are auto-wired.
  T addMaster<T extends BridgeModule>(
    T master, {
    String busInterfaceName = 'dataBus',
    String? clockDomainName,
  }) {
    addSubModule(master);
    _masters.add(
      _MasterEntry(module: master, busInterfaceName: busInterfaceName),
    );

    final (
      clk,
      reset,
    ) = clockDomainName != null && _clockDomains.containsKey(clockDomainName)
        ? (
            _clockDomains[clockDomainName]!.clk,
            _clockDomains[clockDomainName]!.reset,
          )
        : defaultClock;

    master.input('clk').srcConnection! <= clk;
    master.input('reset').srcConnection! <= reset;

    return master;
  }

  /// Pulls a peripheral's port up to the SoC level as an external pin.
  ///
  /// Useful for UART TX/RX, GPIO, SPI, etc.
  PortReference exposePin(
    BridgeModule peripheral,
    String portName, {
    String? externalName,
  }) {
    return pullUpPort(
      peripheral.port(portName),
      newPortName: externalName ?? '${peripheral.name}_$portName',
    );
  }

  /// Builds the bus fabric connecting masters to peripherals.
  ///
  /// For each master, creates address-decode logic that routes
  /// transactions to the correct peripheral based on
  /// [HarborDeviceTreeNode.reg] address ranges.
  ///
  /// Must be called after all [addPeripheral] and [addMaster]
  /// calls, before [build].
  void buildFabric() {
    if (_peripherals.isEmpty || _masters.isEmpty) return;

    // Validate no address overlaps
    final mappings = _peripherals.indexed
        .map(
          (e) =>
              HarborAddressMapping(range: e.$2.addressRange, slaveIndex: e.$1),
        )
        .toList();

    final errors = validateAddressMappings(mappings);
    if (errors.isNotEmpty) {
      throw StateError(
        'Address mapping errors in $name:\n${errors.join("\n")}',
      );
    }

    for (final masterEntry in _masters) {
      switch (busConfig) {
        case WishboneConfig wbConfig:
          _buildWishboneFabric(masterEntry, wbConfig);
        default:
          throw UnsupportedError(
            'Bus protocol ${busConfig.runtimeType} not yet supported in buildFabric',
          );
      }
    }
  }

  void _buildWishboneFabric(_MasterEntry masterEntry, WishboneConfig wbConfig) {
    final mappings = _peripherals.indexed
        .map(
          (e) =>
              HarborAddressMapping(range: e.$2.addressRange, slaveIndex: e.$1),
        )
        .toList();

    final decoder = WishboneDecoder(wbConfig, mappings);
    addSubModule(decoder);

    // Connect master's bus to decoder's master interface
    connectInterfaces(
      masterEntry.module.interface(masterEntry.busInterfaceName),
      decoder.interface('master'),
    );

    // Connect decoder's slave interfaces to peripherals
    for (var i = 0; i < _peripherals.length; i++) {
      connectInterfaces(
        decoder.interface('slave_$i'),
        _peripherals[i].module.interface('bus'),
      );
    }
  }

  /// Generates a Linux/U-Boot compatible `.dts` file.
  String generateDts() {
    return HarborDeviceTreeGenerator(
      model: name,
      compatible: compatible,
      cpus: cpus,
      peripherals: _peripherals
          .map((e) => e.module)
          .whereType<HarborDeviceTreeNodeProvider>()
          .toList(),
    ).generate();
  }

  /// Generates a Mermaid flowchart of this SoC's topology.
  String generateMermaid() {
    return HarborSoCGraphGenerator(
      name: name,
      cpus: cpus,
      peripherals: _peripherals
          .map((e) => e.module)
          .whereType<HarborDeviceTreeNodeProvider>()
          .toList(),
    ).mermaid();
  }

  /// Generates a Graphviz DOT graph of this SoC's topology.
  String generateDot() {
    return HarborSoCGraphGenerator(
      name: name,
      cpus: cpus,
      peripherals: _peripherals
          .map((e) => e.module)
          .whereType<HarborDeviceTreeNodeProvider>()
          .toList(),
    ).dot();
  }

  /// Builds RTL and writes all generated outputs to [outputPath].
  ///
  /// Generates:
  /// - `rtl/` - SystemVerilog files + filelist.f (via rohd_bridge)
  /// - `<name>.dts` - device tree source
  /// - `<name>.dot` - Graphviz topology graph
  /// - `<name>.mermaid.md` - Mermaid topology graph
  /// - Target-specific files:
  ///   - FPGA: constraint file (`.pcf`/`.lpf`/`.xdc`)
  ///   - ASIC: SDC timing constraints
  Future<void> generateAll(Directory directory) async {
    directory.createSync(recursive: true);
    final path = directory.path;

    // RTL generation via rohd_bridge
    await buildAndGenerateRTL(outputPath: path);

    // Generate blackbox stubs for leaf modules (SRAM macros, etc.)
    final blackboxStubs = _generateBlackboxStubs();
    if (blackboxStubs.isNotEmpty) {
      File('$path/blackboxes.v').writeAsStringSync(blackboxStubs);
    }

    // Device tree
    File('$path/$name.dts').writeAsStringSync(generateDts());

    // Graphs
    File('$path/$name.dot').writeAsStringSync(generateDot());
    File(
      '$path/$name.mermaid.md',
    ).writeAsStringSync('```mermaid\n${generateMermaid()}\n```\n');

    // Target-specific outputs
    final t = target;
    if (t != null) {
      switch (t) {
        case HarborFpgaTarget():
          File(
            '$path/$name.${t.constraintExtension}',
          ).writeAsStringSync(t.generateConstraints());
          final rtlDir = Directory('$path/rtl');
          final svFiles = rtlDir.existsSync()
              ? rtlDir
                    .listSync()
                    .where((f) => f.path.endsWith('.sv'))
                    .map((f) => 'rtl/${f.uri.pathSegments.last}')
                    .toList()
              : <String>[];
          File(
            '$path/synth.tcl',
          ).writeAsStringSync(t.generateYosysTcl(name, svFiles: svFiles));
          File('$path/Makefile').writeAsStringSync(t.generateMakefile(name));
        case HarborAsicTarget():
          File('$path/$name.sdc').writeAsStringSync(t.generateSdc());
          File('$path/synth.tcl').writeAsStringSync(t.generateYosysTcl());
          File('$path/pnr.tcl').writeAsStringSync(t.generateOpenroadTcl());

          // Hierarchical macro scripts
          if (t.isHierarchical) {
            final macroDir = Directory('$path/macros');
            macroDir.createSync(recursive: true);
            for (final macro in t.macros) {
              File(
                '$path/macros/${macro.moduleName}_synth.tcl',
              ).writeAsStringSync(t.generateMacroYosysTcl(macro));
              File(
                '$path/macros/${macro.moduleName}_pnr.tcl',
              ).writeAsStringSync(t.generateMacroOpenroadTcl(macro));
            }
          }

          // KLayout scripts
          final klayout = HarborKlayoutScripts(
            pdkName: t.provider.name,
            topCell: t.topCell,
            drc: t.klayoutDrc,
            lvsNetlistPath: '${t.topCell}_final.v',
          );

          final klayoutDir = Directory('$path/klayout');
          klayoutDir.createSync(recursive: true);

          // DEF to GDS conversion
          final lib = t.provider.standardCellLibrary;
          File('$path/klayout/def2gds.py').writeAsStringSync(
            klayout.generateDefToGds(
              defPath: '${t.topCell}_final.def',
              techLefPath: lib.techLefPath ?? lib.lefPath,
              outputGdsPath: '${t.topCell}.gds',
            ),
          );

          // GDS merge (if analog blocks present)
          if (t.analogGdsPaths.isNotEmpty) {
            File('$path/klayout/gds_merge.py').writeAsStringSync(
              klayout.generateGdsMerge(
                digitalGdsPath: '${t.topCell}.gds',
                analogGdsPaths: t.analogGdsPaths,
                outputGdsPath: '${t.topCell}_merged.gds',
              ),
            );
          }

          // DRC
          File(
            '$path/klayout/drc.py',
          ).writeAsStringSync(klayout.generateDrc(gdsPath: '${t.topCell}.gds'));

          // LVS
          File(
            '$path/klayout/lvs.py',
          ).writeAsStringSync(klayout.generateLvs(gdsPath: '${t.topCell}.gds'));
      }
    }
  }

  /// Generates Verilog blackbox stubs for all SystemVerilog leaf modules.
  ///
  /// These are hard IP blocks (SRAM macros, PLLs, etc.) that have no
  /// ROHD-generated definition. The stubs let Yosys recognize the
  /// module interfaces during synthesis.
  String _generateBlackboxStubs() {
    final leafModules = <BridgeModule>[];
    _collectLeafModules(this, leafModules);
    if (leafModules.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('// Auto-generated blackbox stubs for synthesis');
    final seen = <String>{};
    for (final mod in leafModules) {
      if (!seen.add(mod.definitionName)) continue;

      buf.writeln('(* blackbox *)');
      buf.write('module ${mod.definitionName}(');

      final ports = <String>[];
      for (final entry in mod.inputs.entries) {
        final w = entry.value.width;
        ports.add(
          w > 1 ? 'input [${w - 1}:0] ${entry.key}' : 'input ${entry.key}',
        );
      }
      for (final entry in mod.outputs.entries) {
        final w = entry.value.width;
        ports.add(
          w > 1 ? 'output [${w - 1}:0] ${entry.key}' : 'output ${entry.key}',
        );
      }
      buf.writeln(ports.join(', '));
      buf.writeln(');');
      buf.writeln('endmodule');
      buf.writeln();
    }
    return buf.toString();
  }

  static void _collectLeafModules(Module mod, List<BridgeModule> result) {
    if (mod is BridgeModule && mod.isSystemVerilogLeaf) {
      result.add(mod);
    }
    for (final sub in mod.subModules) {
      _collectLeafModules(sub, result);
    }
  }
}

class _PeripheralEntry {
  final BridgeModule module;
  final BusAddressRange addressRange;

  const _PeripheralEntry({required this.module, required this.addressRange});
}

class _MasterEntry {
  final BridgeModule module;
  final String busInterfaceName;

  const _MasterEntry({required this.module, required this.busInterfaceName});
}
