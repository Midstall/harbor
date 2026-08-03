import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/wishbone/wishbone_arbiter.dart';
import '../bus/wishbone/wishbone_decoder.dart';
import '../bus/wishbone/wishbone_interface.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../clock/clock_domain.dart';
import '../pdk/klayout.dart';
import '../peripherals/harbor_ddr3.dart';
import 'acpi.dart';
import 'cpu.dart';
import 'device_tree.dart';
import 'graph.dart';
import 'svd.dart';
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
  final List<HarborCpu> cpus;

  /// Build target (FPGA or ASIC). Controls what scripts are generated.
  final HarborDeviceTarget? target;

  final List<_PeripheralEntry> _peripherals = [];
  final List<_SecondarySlave> _secondarySlaves = [];
  final List<_MasterEntry> _masters = [];

  /// The fabric arbiter, exposed after [buildFabric] when there is more than one
  /// master (null with a single master, which connects to the decoder directly).
  /// Its `grant` output identifies the master currently owning the bus, which a
  /// security peripheral can use as the unforgeable source identity.
  WishboneArbiter? fabricArbiter;

  /// Modules already added as submodules + clock-wired. A module may be BOTH a
  /// master and a peripheral (a dual-role device like a DMA or an accelerator
  /// with CSR slave + bus master). This set keeps the second [addMaster] /
  /// [addPeripheral] from double-adding or double-driving its clk/reset.
  final Set<BridgeModule> _wired = {};

  /// Adds [module] as a submodule and wires its clk/reset exactly once, even if
  /// it is registered as both a master and a peripheral.
  void _wireOnce(BridgeModule module, String? clockDomainName) {
    if (!_wired.add(module)) return;
    addSubModule(module);
    final (
      clk,
      reset,
    ) = clockDomainName != null && _clockDomains.containsKey(clockDomainName)
        ? (
            _clockDomains[clockDomainName]!.clk,
            _clockDomains[clockDomainName]!.reset,
          )
        : defaultClock;
    module.input('clk').srcConnection! <= clk;
    module.input('reset').srcConnection! <= reset;
  }

  late final HarborClockGenerator _clockGen;
  final Map<String, HarborClockDomain> _clockDomains = {};

  /// The Xilinx DDR3-fast clock tree, built in this SoC's clock generation when
  /// [xilinxDdr3Tree] is provided. Null otherwise. Exposes the DDR CK / CLKDIV /
  /// IDELAYCTRL-ref / CK90 / DQS clocks for the DDR controller peripheral, and
  /// its spare `coreClk` drives any [HarborClockConfig.providedByDdr3Tree] domain
  /// (so the core runs off the SAME MMCM as the DDR clocks: one MMCM on the pin).
  late final XilinxDdr3Clocks? xilinxDdr3Clocks;

  final String acpiOemId;
  final String acpiOemTableId;

  /// Vendor name for the generated CMSIS-SVD file.
  final String svdVendor;

  /// Version string for the generated CMSIS-SVD file.
  final String svdVersion;

  /// First interrupt source number handed out by the interrupt allocator.
  ///
  /// Source 0 is reserved (the "no interrupt" sentinel in PLIC/APLIC), so the
  /// default first real source is 1.
  final int interruptBase;

  /// Creates a new SoC.
  ///
  /// Accepts an optional list of [clocks] to generate PLL-derived
  /// clock domains. If empty, the external `clk` input is used directly.
  HarborSoC({
    required String name,
    required this.compatible,
    required this.busConfig,
    this.acpiOemId = 'MIDSTL',
    this.acpiOemTableId = 'HARBOR',
    this.svdVendor = 'Midstall',
    this.svdVersion = '1.0',
    this.interruptBase = 1,
    this.cpus = const [],
    this.target,
    List<HarborClockConfig> clocks = const [],
    XilinxDdr3TreeSpec? xilinxDdr3Tree,
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

    // Xilinx DDR3-fast (single-oscillator, e.g. Arty S7): build the shared DDR3
    // clock tree HERE (from the `clk` pin). The core/sys clock is generated by a
    // SEPARATE PLL (not a spare CLKOUT of the DDR MMCM): two outputs of one MMCM
    // are phase-locked at a fixed sub-cycle relationship, which parks the async
    // sys<->ctrl CDC synchronizer at a pathological metastable phase and corrupts
    // crossed reads (the creek boot coin-flip). Two independent PLLs drift, so
    // the crossing is genuinely async. Both PLLs source one shared input BUFG so
    // openXC7 accepts two PLLs on the pin's single clock-capable route.
    final ddrSpec = xilinxDdr3Tree;
    ({Logic coreClk, Logic locked, double coreMhz})? corePll;
    if (ddrSpec != null) {
      final sharedIn = addSubModule(XilinxBufg(name: 'sysosc_bufg'));
      sharedIn.input('I').srcConnection! <= input('clk');
      final shared = sharedIn.output('O');
      // Decoupled core PLL off the shared input. The DDR tree no longer emits
      // its CLKOUT5 core clock.
      corePll = buildXilinxCorePll(
        this,
        source: shared,
        sourceHz: ddrSpec.sourceHz,
        coreClkHz: ddrSpec.coreClkHz,
      );
      xilinxDdr3Clocks = buildXilinxDdr3ClockTree(
        this,
        source: shared,
        sourceHz: ddrSpec.sourceHz,
        ddrCkHz: ddrSpec.ddrCkHz,
        idelayRefHz: ddrSpec.idelayRefHz,
        dqsPhaseDeg: ddrSpec.dqsPhaseDeg,
        // Core clock now comes from the dedicated corePll, not CLKOUT5.
        coreClkHz: null,
      );
    } else {
      xilinxDdr3Clocks = null;
    }

    for (final clkConfig in clocks) {
      if (clkConfig.providedByDdr3Tree) {
        if (corePll == null) {
          throw StateError(
            'clock "${clkConfig.name}" is providedByDdr3Tree but no '
            'xilinxDdr3Tree/coreClkHz was supplied to build its core clock.',
          );
        }
        _clockDomains[clkConfig.name] = _clockGen.createDomainFromClock(
          clkConfig,
          corePll.coreClk,
          locked: corePll.locked,
        );
        continue;
      }
      final sec = clkConfig.coClkosSecondary;
      if (sec != null) {
        // One EHXPLLL drives both: CLKOP = this domain, CLKOS = the secondary.
        // Avoids a 2nd PLL block that may not lock on silicon.
        final shared = _clockGen.createDomainWithSecondary(
          clkConfig,
          secondaryFrequency: sec.frequency,
          secondaryName: sec.name,
        );
        // Register the secondary FIRST so a 'sys'-named secondary stays the
        // default clock (values.first), then the CLKOP primary.
        _clockDomains[sec.name] = shared.secondary;
        _clockDomains[clkConfig.name] = shared.primary;
      } else {
        _clockDomains[clkConfig.name] = _clockGen.createDomain(clkConfig);
      }
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
      // Prefer the conventional 'sys' bus domain: it may not be the first
      // registered entry when it is a CLKOS secondary of another PLL, and fall
      // back to the first domain otherwise.
      final d = _clockDomains['sys'] ?? _clockDomains.values.first;
      return (d.clk, d.reset);
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

    final dt = (peripheral as HarborDeviceTreeNodeProvider).dtNode;
    _peripherals.add(
      _PeripheralEntry(module: peripheral, addressRange: dt.reg),
    );
    _wireOnce(peripheral, clockDomainName);
    return peripheral;
  }

  /// Maps a SECOND wishbone slave interface of an already-added peripheral into
  /// the fabric at [range]. Unlike [addPeripheral] it does NOT register the
  /// module again (its dtNode / clock / interrupts are already wired) - it only
  /// adds a decoder slot bound to [busInterfaceName]. For peripherals that
  /// expose more than one bus face, e.g. the ddr3 controller's runtime-training
  /// register window carved from the top of its own region.
  void addPeripheralSlave(
    BridgeModule module,
    String busInterfaceName,
    BusAddressRange range,
  ) {
    _secondarySlaves.add(
      _SecondarySlave(
        module: module,
        busInterfaceName: busInterfaceName,
        addressRange: range,
      ),
    );
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
    _masters.add(
      _MasterEntry(module: master, busInterfaceName: busInterfaceName),
    );
    _wireOnce(master, clockDomainName);
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

  /// Checks the SoC for build-time integrity problems and returns every
  /// problem found as a human-readable string. An empty list means the SoC is
  /// consistent.
  ///
  /// [buildFabric] calls this and refuses to build when it returns anything,
  /// so these checks turn silent surprises into loud failures. The checks are:
  ///
  /// - peripheral address windows must not overlap,
  /// - a peripheral's register map must have no overlapping fields,
  /// - every register must fit within the peripheral's address block,
  /// - no interrupt number may be assigned to two peripherals.
  List<String> validate() {
    final errors = <String>[];

    // Peripheral address windows must not overlap.
    final mappings = _peripherals.indexed
        .map(
          (e) =>
              HarborAddressMapping(range: e.$2.addressRange, slaveIndex: e.$1),
        )
        .toList();
    errors.addAll(validateAddressMappings(mappings));

    // Register maps: internal overlaps and out-of-block registers. The register
    // map and its block size both come from the SVD view, so they are checked
    // against a single source.
    for (final entry in _peripherals) {
      final m = entry.module;
      if (m is! HarborSvdPeripheralProvider) continue;
      final sp = (m as HarborSvdPeripheralProvider).svdPeripheral;
      final regs = sp.registers;
      if (regs == null) continue;

      for (final overlap in regs.validate()) {
        errors.add('${sp.name}: $overlap');
      }
      for (final f in regs.fields) {
        if (f.end > sp.size) {
          errors.add(
            "${sp.name}: register '${f.name}' @ 0x${f.offset.toRadixString(16)} "
            '(${f.width}B) exceeds address block size '
            '0x${sp.size.toRadixString(16)}',
          );
        }
      }
    }

    // No interrupt number may be assigned twice.
    final seen = <int, String>{};
    interruptAssignments().forEach((module, irq) {
      final existing = seen[irq];
      if (existing != null) {
        errors.add(
          'interrupt $irq assigned to both $existing and ${module.name}',
        );
      } else {
        seen[irq] = module.name;
      }
    });

    return errors;
  }

  /// Builds the bus fabric connecting masters to peripherals.
  ///
  /// For each master, creates address-decode logic that routes
  /// transactions to the correct peripheral based on
  /// [HarborDeviceTreeNode.reg] address ranges.
  ///
  /// Validates the SoC via [validate] first and throws a [StateError] if any
  /// problem is found.
  ///
  /// Must be called after all [addPeripheral] and [addMaster]
  /// calls, before [build].
  void buildFabric() {
    final errors = validate();
    if (errors.isNotEmpty) {
      throw StateError('Validation errors in $name:\n${errors.join("\n")}');
    }

    if (_peripherals.isEmpty || _masters.isEmpty) return;

    switch (busConfig) {
      case WishboneConfig wbConfig:
        _buildWishboneFabric(wbConfig);
      default:
        throw UnsupportedError(
          'Bus protocol ${busConfig.runtimeType} not yet supported in buildFabric',
        );
    }
  }

  void _buildWishboneFabric(WishboneConfig wbConfig) {
    // Primary peripheral buses first, then any secondary slaves (each a distinct
    // decoder slot). Both feed the same address-decode + connect loop below.
    final slaves =
        <({BridgeModule module, String iface, BusAddressRange range})>[
          for (final e in _peripherals)
            (module: e.module, iface: 'bus', range: e.addressRange),
          for (final s in _secondarySlaves)
            (
              module: s.module,
              iface: s.busInterfaceName,
              range: s.addressRange,
            ),
        ];
    final mappings = slaves.indexed
        .map((e) => HarborAddressMapping(range: e.$2.range, slaveIndex: e.$1))
        .toList();

    final decoder = WishboneDecoder(wbConfig, mappings);
    addSubModule(decoder);

    // One master -> straight to the decoder. Multiple masters -> merge them
    // through a WishboneArbiter first (round-robin, grant-locked) so they share
    // the single decoder/peripheral fabric without multi-driving it.
    if (_masters.length == 1) {
      connectInterfaces(
        _masters[0].module.interface(_masters[0].busInterfaceName),
        decoder.interface('master'),
      );
    } else {
      final arbiter = WishboneArbiter(
        numMasters: _masters.length,
        config: wbConfig,
      );
      fabricArbiter = arbiter;
      addSubModule(arbiter);
      final (clk, reset) = defaultClock;
      arbiter.input('clk').srcConnection! <= clk;
      arbiter.input('reset').srcConnection! <= reset;
      for (var i = 0; i < _masters.length; i++) {
        connectInterfaces(
          _masters[i].module.interface(_masters[i].busInterfaceName),
          arbiter.interface('master_$i'),
        );
      }
      connectInterfaces(
        arbiter.interface('slave'),
        decoder.interface('master'),
      );
    }

    // Connect decoder's slave interfaces to the primary + secondary slaves.
    for (var i = 0; i < slaves.length; i++) {
      connectInterfaces(
        decoder.interface('slave_$i'),
        slaves[i].module.interface(slaves[i].iface),
      );
    }
  }

  /// Assigns an interrupt source number to every peripheral that sources an
  /// interrupt, in the order peripherals were added.
  ///
  /// This is the single interrupt-number allocator for the SoC: the device
  /// tree, ACPI, SVD, and graph generators all read this assignment rather
  /// than each peripheral hardcoding its own number. A peripheral is treated
  /// as an interrupt source when it has an `interrupt` output port and is not
  /// itself an interrupt controller.
  ///
  /// The returned map is keyed by the peripheral module.
  Map<BridgeModule, int> interruptAssignments() {
    final result = <BridgeModule, int>{};
    var next = interruptBase;
    for (final entry in _peripherals) {
      final m = entry.module;
      if (m is HarborDeviceTreeNodeProvider &&
          (m as HarborDeviceTreeNodeProvider).dtNode.interruptController) {
        continue;
      }
      if (!_hasInterruptOutput(m)) continue;
      result[m] = next++;
    }
    return result;
  }

  bool _hasInterruptOutput(BridgeModule m) {
    try {
      m.output('interrupt');
      return true;
    } on Exception {
      return false;
    }
  }

  /// Generates a ACPICA compatible `.asl` file.
  String generateAcpi() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborAcpiDeviceProvider>()
        .toList();
    return HarborAcpiGenerator(
      oemId: acpiOemId,
      oemTableId: acpiOemTableId,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
    ).generate();
  }

  /// Generates a Linux/U-Boot compatible `.dts` file.
  String generateDts() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborDeviceTreeNodeProvider>()
        .toList();
    // Devices that back usable RAM contribute root `memory@` nodes, not just
    // their controller node under `/soc`, so an OS/SBI payload finds RAM.
    final memories = _peripherals
        .map((e) => e.module)
        .whereType<HarborSystemMemoryProvider>()
        .expand((p) => p.systemMemory)
        .toList();
    return HarborDeviceTreeGenerator(
      model: name,
      compatible: compatible,
      cpus: cpus,
      peripherals: providers,
      memories: memories,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
    ).generate();
  }

  /// Generates a CMSIS-SVD (System View Description) file.
  String generateSvd() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborSvdPeripheralProvider>()
        .toList();
    return HarborSvdGenerator(
      vendor: svdVendor,
      name: name,
      version: svdVersion,
      description: compatible,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
    ).generate();
  }

  /// Generates a Mermaid flowchart of this SoC's topology.
  String generateMermaid() => _graphGenerator().mermaid();

  /// Generates a Graphviz DOT graph of this SoC's topology.
  String generateDot() => _graphGenerator().dot();

  HarborSoCGraphGenerator _graphGenerator() {
    final assign = interruptAssignments();
    final providers = _peripherals
        .map((e) => e.module)
        .whereType<HarborDeviceTreeNodeProvider>()
        .toList();
    return HarborSoCGraphGenerator(
      name: name,
      cpus: cpus,
      peripherals: providers,
      interrupts: {
        for (final p in providers)
          if (assign[p] != null) p: [assign[p]!],
      },
      hasJtagDebug: masters.whereType<HarborJtagDebug>().isNotEmpty,
    );
  }

  /// Builds RTL and writes all generated outputs to [outputPath].
  ///
  /// Generates:
  /// - `rtl/`: SystemVerilog files + filelist.f (via rohd_bridge)
  /// - `<name>.dts`: device tree source
  /// - `<name>.dot`: Graphviz topology graph
  /// - `<name>.mermaid.md`: Mermaid topology graph
  /// - Target-specific files:
  ///   - FPGA: constraint file (`.pcf`/`.lpf`/`.xdc`)
  ///   - ASIC: SDC timing constraints
  Future<void> generateAll(Directory directory) async {
    directory.createSync(recursive: true);
    final path = directory.path;

    // RTL generation: emit one SystemVerilog file per UNIQUIFIED module name.
    //
    // We deliberately do NOT use rohd_bridge's `buildAndGenerateRTL`, which
    // names each output file by `module.definitionName`. When ROHD's
    // synthesizer uniquifies two *distinct* modules that requested the same
    // `definitionName` (e.g. `ParallelPrefixAdder_W64` and the second,
    // structurally-different instance emitted as `ParallelPrefixAdder_W64_0`),
    // both modules still report the same `definitionName`, so they collide onto
    // a single file: one body clobbers the other (corrupting its `endmodule`)
    // and the filelist lists it twice -> Verilator MODDUP/ENDLABEL errors.
    //
    // ROHD already prevents this: `SynthFileContents.name` carries the correct
    // uniquified module name. Keying filenames on that yields one file per
    // emitted module with no collision.
    await build();
    final synthBuilder = SynthBuilder(this, SystemVerilogSynthesizer());
    final rtlPath = '$path/rtl';
    Directory(rtlPath).createSync(recursive: true);
    final filelist = StringBuffer();
    for (final fileContents in synthBuilder.getSynthFileContents()) {
      final fileName = '${fileContents.name}.sv';
      var contents = fileContents.contents;
      // ROHD emits the bidirectional `net_connect` helper with TWO ports that
      // share the name `w` (`module net_connect #(...) (w, w)`), which yosys
      // rejects as a duplicate port. Rewrite it to two distinct cross-assigned
      // inout ports. Instantiations are positional, so this is transparent.
      if (fileContents.name == 'net_connect' &&
          RegExp(r'\(\s*w\s*,\s*w\s*\)').hasMatch(contents)) {
        contents =
            '// A special module for connecting two nets '
            'bidirectionally\n'
            'module net_connect #(parameter int WIDTH=1) (w0, w1);\n'
            'inout wire [WIDTH-1:0] w0;\n'
            'inout wire [WIDTH-1:0] w1;\n'
            'assign w0 = w1;\n'
            'assign w1 = w0;\n'
            'endmodule\n';
      }
      File('$rtlPath/$fileName').writeAsStringSync(contents);
      filelist.writeln('./rtl/$fileName');
    }
    File('$path/filelist.f').writeAsStringSync(filelist.toString());

    // Generate blackbox stubs for leaf modules (SRAM macros, etc.)
    final blackboxStubs = _generateBlackboxStubs();
    if (blackboxStubs.isNotEmpty) {
      File('$path/blackboxes.v').writeAsStringSync(blackboxStubs);
    }

    // ACPI
    File('$path/$name.asl').writeAsStringSync(generateAcpi());

    // Device tree
    File('$path/$name.dts').writeAsStringSync(generateDts());

    // CMSIS-SVD
    File('$path/$name.svd').writeAsStringSync(generateSvd());

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

          // OpenOCD config, auto-emitted when the SoC has a JTAG debug master.
          final jtag = masters.whereType<HarborJtagDebug>();
          if (jtag.isNotEmpty) {
            final dm = jtag.first;
            File('$path/openocd.cfg').writeAsStringSync(
              t.generateOpenocdConfig(
                innerIrWidth: dm.jtagInnerIrWidth,
                dmIdcode: dm.jtagDmIdcode,
              ),
            );
          }

          // openXC7 DDR3 nextpnr helper scripts. The DDR PHY's bitslip-
          // reference train SERDES must be pinned off the dead _SING tile;
          // these ride nextpnr-xilinx --pre-place (constraints.py) and
          // --pre-route (show_bels.py). Emitted only for the open-source
          // Xilinx flow when a HarborDdr3 controller is present.
          if (t.vendor == HarborFpgaVendor.openXc7) {
            final ddr = peripherals.whereType<HarborDdr3>().firstOrNull;
            if (ddr != null) {
              Directory('$path/support/nextpnr').createSync(recursive: true);
              File(
                '$path/support/nextpnr/constraints.py',
              ).writeAsStringSync(t.generateDdrPreplacePy(lanes: ddr.lanes));
              File(
                '$path/support/nextpnr/show_bels.py',
              ).writeAsStringSync(t.generateDdrShowBelsPy());
            }
          }
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

/// A secondary bus slave of an already-registered peripheral (see
/// [HarborSoC.addPeripheralSlave]): another decoder slot only, no dtNode/clock.
class _SecondarySlave {
  final BridgeModule module;
  final String busInterfaceName;
  final BusAddressRange addressRange;

  const _SecondarySlave({
    required this.module,
    required this.busInterfaceName,
    required this.addressRange,
  });
}

class _MasterEntry {
  final BridgeModule module;
  final String busInterfaceName;

  const _MasterEntry({required this.module, required this.busInterfaceName});
}
