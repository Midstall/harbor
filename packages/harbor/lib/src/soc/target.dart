import '../pdk/io_ring.dart';
import '../pdk/klayout.dart';
import '../pdk/pdk_provider.dart';

/// Build target describing whether the SoC targets an FPGA or ASIC,
/// and which vendor/PDK to use.
///
/// The target controls what synthesis and place-and-route scripts
/// are generated when calling [HarborSoC.generateAll].
sealed class HarborDeviceTarget {
  /// Human-readable name for this target.
  String get name;

  const HarborDeviceTarget();
}

/// FPGA target with vendor-specific toolchain configuration.
///
/// ```dart
/// final target = HarborFpgaTarget.ice40(
///   device: 'up5k',
///   package: 'sg48',
///   frequency: 48000000,
///   pinMap: {'uart_tx': 'P1', 'uart_rx': 'P2'},
/// );
/// ```
class HarborFpgaTarget extends HarborDeviceTarget {
  @override
  final String name;

  /// FPGA vendor.
  final HarborFpgaVendor vendor;

  /// Device part number (e.g., `'up5k'`, `'lfe5u-45f'`, `'xc7s50'`).
  final String device;

  /// Package (e.g., `'sg48'`, `'CABGA381'`, `'ftgb196'`).
  final String package;

  /// Target clock frequency in Hz.
  final int frequency;

  /// Pin constraints: signal name → pin identifier.
  final Map<String, String> pinMap;

  /// Additional constraints passed to the toolchain.
  final Map<String, String> extraConstraints;

  /// Whether this FPGA supports eFuse OTP storage.
  ///
  /// ECP5 and Spartan 7 have eFuse support for user data and
  /// security keys. iCE40 does not.
  bool get hasEfuse => switch (vendor) {
    HarborFpgaVendor.ice40 => false,
    HarborFpgaVendor.ecp5 => true,
    HarborFpgaVendor.vivado => true,
    HarborFpgaVendor.openXc7 => true,
  };

  /// Whether this FPGA has a built-in temperature sensor primitive.
  ///
  /// ECP5 has DTR, Xilinx 7-series has XADC. iCE40 does not.
  bool get hasTemperatureSensor => switch (vendor) {
    HarborFpgaVendor.ice40 => false,
    HarborFpgaVendor.ecp5 => true,
    HarborFpgaVendor.vivado => true,
    HarborFpgaVendor.openXc7 => true,
  };

  /// File extension for the constraint file (e.g., `'pcf'`, `'lpf'`, `'xdc'`).
  String get constraintExtension => switch (vendor) {
    HarborFpgaVendor.ice40 => 'pcf',
    HarborFpgaVendor.ecp5 => 'lpf',
    HarborFpgaVendor.vivado => 'xdc',
    HarborFpgaVendor.openXc7 => 'xdc',
  };

  const HarborFpgaTarget({
    required this.name,
    required this.vendor,
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
  });

  /// iCE40 UP5K target using Yosys + nextpnr-ice40.
  const HarborFpgaTarget.ice40({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
  }) : name = 'ice40-$device',
       vendor = HarborFpgaVendor.ice40;

  /// Lattice ECP5 target using Yosys + nextpnr-ecp5.
  const HarborFpgaTarget.ecp5({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
  }) : name = 'ecp5-$device',
       vendor = HarborFpgaVendor.ecp5;

  /// Xilinx Spartan 7 target using Vivado or openXC7.
  const HarborFpgaTarget.spartan7({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    bool useOpenXc7 = false,
  }) : name = 'spartan7-$device',
       vendor = useOpenXc7 ? HarborFpgaVendor.openXc7 : HarborFpgaVendor.vivado;

  /// Yosys synthesis target string for this FPGA family.
  String get _yosysSynthTarget => switch (vendor) {
    HarborFpgaVendor.ice40 => 'ice40',
    HarborFpgaVendor.ecp5 => 'ecp5',
    HarborFpgaVendor.vivado => 'xilinx',
    HarborFpgaVendor.openXc7 => 'xilinx',
  };

  /// Bitstream output extension.
  String get bitstreamExtension => switch (vendor) {
    HarborFpgaVendor.ice40 => 'bin',
    HarborFpgaVendor.ecp5 => 'bit',
    HarborFpgaVendor.vivado => 'bit',
    HarborFpgaVendor.openXc7 => 'bit',
  };

  /// Generates a Yosys synthesis TCL script for this FPGA target.
  ///
  /// Produces a JSON netlist for nextpnr (iCE40/ECP5) or a
  /// Verilog netlist for Vivado/openXC7.
  String generateYosysTcl(String topCell, {List<String> svFiles = const []}) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Yosys synthesis for $name');
    buf.writeln('# Target: ${_yosysSynthTarget} ($device)');
    buf.writeln();
    if (svFiles.isNotEmpty) {
      for (final sv in svFiles) {
        buf.writeln('read_verilog -sv $sv');
      }
    } else {
      buf.writeln('read_verilog -sv rtl/*.sv');
    }
    buf.writeln('hierarchy -top $topCell');

    switch (vendor) {
      case HarborFpgaVendor.ice40:
        buf.writeln('synth_ice40 -top $topCell -json $topCell.json');
      case HarborFpgaVendor.ecp5:
        buf.writeln('synth_ecp5 -top $topCell -json $topCell.json');
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        buf.writeln('synth_xilinx -top $topCell -flatten');
        buf.writeln('write_json $topCell.json');
    }

    buf.writeln('stat');
    return buf.toString();
  }

  /// Maps an ECP5 device part to its nextpnr size suffix (e.g. `45k`).
  static String _ecp5DeviceSize(String device) {
    final lower = device.toLowerCase();
    if (lower.contains('12')) return '12k';
    if (lower.contains('25')) return '25k';
    if (lower.contains('45')) return '45k';
    if (lower.contains('85')) return '85k';
    return device;
  }

  /// Generates a nextpnr command for place-and-route (iCE40/ECP5).
  ///
  /// Returns null for Vivado targets (which use their own flow).
  String? generateNextpnrCommand(String topCell) {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return 'nextpnr-ice40 --$device --package $package '
            '--json $topCell.json '
            '--pcf $topCell.pcf '
            '--asc $topCell.asc'
            '${frequency > 0 ? " --freq ${(frequency / 1e6).toStringAsFixed(0)}" : ""}';
      case HarborFpgaVendor.ecp5:
        final ecp5Size = _ecp5DeviceSize(device);
        return 'nextpnr-ecp5 --$ecp5Size --package $package '
            '--json $topCell.json '
            '--lpf $topCell.lpf '
            '--textcfg $topCell.config'
            '${frequency > 0 ? " --freq ${(frequency / 1e6).toStringAsFixed(0)}" : ""}';
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return null; // Vivado/openXC7 use their own PnR
    }
  }

  /// Generates a bitstream packing command (iCE40/ECP5).
  ///
  /// Returns null for Vivado targets.
  String? generatePackCommand(String topCell) {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return 'icepack $topCell.asc $topCell.bin';
      case HarborFpgaVendor.ecp5:
        return 'ecppack --input $topCell.config --bit $topCell.bit';
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return null;
    }
  }

  /// Generates a complete Makefile for the FPGA build flow.
  String generateMakefile(String topCell) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Makefile for $name');
    buf.writeln('TOP = $topCell');
    buf.writeln('DEVICE = $device');
    buf.writeln('PACKAGE = $package');
    buf.writeln();
    buf.writeln('SV_FILES = \$(wildcard rtl/*.sv)');
    buf.writeln();

    // Synthesis
    buf.writeln('.PHONY: all synth pnr pack clean');
    buf.writeln();
    buf.writeln('all: \$(TOP).$bitstreamExtension');
    buf.writeln();
    buf.writeln('synth: \$(TOP).json');
    buf.writeln('\$(TOP).json: \$(SV_FILES)');
    buf.writeln('\tyosys -s synth.tcl');
    buf.writeln();

    // PnR + pack
    final pnrCmd = generateNextpnrCommand(topCell);
    final packCmd = generatePackCommand(topCell);
    if (pnrCmd != null && packCmd != null) {
      final intermediate = vendor == HarborFpgaVendor.ice40
          ? '\$(TOP).asc'
          : '\$(TOP).config';
      buf.writeln('pnr: $intermediate');
      buf.writeln('$intermediate: \$(TOP).json \$(TOP).$constraintExtension');
      buf.writeln('\t$pnrCmd');
      buf.writeln();
      buf.writeln('pack: \$(TOP).$bitstreamExtension');
      buf.writeln('\$(TOP).$bitstreamExtension: $intermediate');
      buf.writeln('\t$packCmd');
    }

    buf.writeln();
    buf.writeln('clean:');
    buf.writeln(
      '\trm -f \$(TOP).json \$(TOP).asc \$(TOP).config '
      '\$(TOP).bin \$(TOP).bit',
    );
    return buf.toString();
  }

  /// Generates a pin constraint file in the vendor's format.
  ///
  /// - iCE40: `.pcf` (Physical Constraints File)
  /// - ECP5: `.lpf` (Lattice Preference File)
  /// - Xilinx: `.xdc` (Xilinx Design Constraints)
  String generateConstraints() {
    switch (vendor) {
      case HarborFpgaVendor.ice40:
        return _generatePcf();
      case HarborFpgaVendor.ecp5:
        return _generateLpf();
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return _generateXdc();
    }
  }

  String _generatePcf() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated PCF for $name');
    for (final entry in pinMap.entries) {
      buf.writeln('set_io ${entry.key} ${entry.value}');
    }
    if (frequency > 0) {
      final clkPin = pinMap['clk'];
      if (clkPin != null) {
        buf.writeln('set_frequency clk ${frequency / 1e6}');
      }
    }
    return buf.toString();
  }

  String _generateLpf() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated LPF for $name');
    for (final entry in pinMap.entries) {
      buf.writeln('LOCATE COMP "${entry.key}" SITE "${entry.value}";');
      buf.writeln('IOBUF PORT "${entry.key}" IO_TYPE=LVCMOS33;');
    }
    if (frequency > 0) {
      buf.writeln(
        'FREQUENCY PORT "clk" ${(frequency / 1e6).toStringAsFixed(1)} MHz;',
      );
    }
    return buf.toString();
  }

  String _generateXdc() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated XDC for $name');
    for (final entry in pinMap.entries) {
      buf.writeln(
        'set_property -dict {PACKAGE_PIN ${entry.value} IOSTANDARD LVCMOS33} '
        '[get_ports {${entry.key}}]',
      );
    }
    if (frequency > 0) {
      final periodNs = 1e9 / frequency;
      buf.writeln(
        'create_clock -period ${periodNs.toStringAsFixed(3)} '
        '[get_ports {clk}]',
      );
    }
    return buf.toString();
  }
}

/// Describes a macro/tile module for hierarchical hardening.
///
/// Each macro is synthesized and placed-and-routed independently,
/// then placed as a hard macro in the top-level chip assembly.
class HarborAsicMacro {
  /// Module name in the RTL hierarchy.
  final String moduleName;

  /// Utilization target for this macro's internal placement.
  final double utilization;

  /// Halo spacing around this macro in the top-level layout (um).
  final double haloUm;

  /// Pin placement on all 4 edges for grid connectivity.
  final bool pinOnAllEdges;

  const HarborAsicMacro({
    required this.moduleName,
    this.utilization = 0.6,
    this.haloUm = 10.0,
    this.pinOnAllEdges = true,
  });
}

/// ASIC tapeout target with PDK configuration.
///
/// Supports two flows:
/// - **Flat**: entire design synthesized and placed at once
/// - **Hierarchical**: specified modules are hardened as macros first,
///   then assembled into the top-level chip (like Aegis tile flow)
///
/// The emitted synth/PnR TCL is driven by `asix.mkTapeout`: PDK paths and
/// floorplan knobs are read from environment variables (LIB_FILE, TECH_LEF,
/// CELL_LEF_DIR, SYNTH_V, SDC_FILE, SITE_NAME, UTILIZATION, etc.) rather than
/// baked into the script, and RTL is read relative to the script via
/// `[info script]`. Cell *names* (tie/fill/clock-buffer) stay baked from the
/// [PdkProvider]. Knobs that asix also owns ([utilization], [frequency]) act as
/// defaults only: asix's matching args take precedence at build time.
///
/// ```dart
/// final target = HarborAsicTarget(
///   provider: Sky130Provider(pdkRoot: '/path/to/sky130A'),
///   topCell: 'MySoC',
///   frequency: 50000000,
///   macros: [
///     HarborAsicMacro(moduleName: 'RiverCore'),
///     HarborAsicMacro(moduleName: 'L2Cache'),
///   ],
/// );
/// ```
class HarborAsicTarget extends HarborDeviceTarget {
  @override
  String get name => '${provider.name}-${provider.node}';

  /// The PDK provider supplying cell libraries, analog blocks, etc.
  final PdkProvider provider;

  /// Top-level cell name for synthesis.
  final String topCell;

  /// Target clock frequency in Hz.
  ///
  /// Drives [generateSdc] for standalone/FPGA use. Under `asix.mkTapeout` the
  /// constraints come from asix's own `clockPeriodNs` (it generates its own
  /// `constraints.sdc` and points `SDC_FILE` at it), so keep the two in sync.
  final int frequency;

  /// Utilization target for placement (0.0 to 1.0).
  ///
  /// Advisory under `asix.mkTapeout`: the PnR script reads `UTILIZATION` from
  /// the env (asix's `coreUtilization`), so this value is the default rather
  /// than the build-time effective one.
  final double utilization;

  /// Modules to harden as macros before top-level assembly.
  ///
  /// Empty list = flat flow (no hierarchical hardening).
  final List<HarborAsicMacro> macros;

  /// Margin around the die edge in um.
  final double dieMarginUm;

  /// Minimum metal layer for top-level routing (skip lower layers
  /// used internally by macros to avoid DRC violations).
  final int topRoutingMinLayer;

  /// IO ring configuration (null = no IO ring generation).
  final HarborIoRing? ioRing;

  /// KLayout scripts configuration (null = no KLayout scripts).
  final HarborKlayoutDrcConfig? klayoutDrc;

  /// Analog GDS files to merge into the final layout.
  final List<String> analogGdsPaths;

  const HarborAsicTarget({
    required this.provider,
    required this.topCell,
    this.frequency = 0,
    this.utilization = 0.5,
    this.macros = const [],
    this.dieMarginUm = 200.0,
    this.topRoutingMinLayer = 2,
    this.ioRing,
    this.klayoutDrc,
    this.analogGdsPaths = const [],
  });

  /// Whether this uses hierarchical macro hardening.
  bool get isHierarchical => macros.isNotEmpty;

  /// Generates an SDC timing constraints file.
  ///
  /// Used by the FPGA/standalone flows. `asix.mkTapeout` ignores this and
  /// generates its own `constraints.sdc` from `clockPeriodNs`, pointing the
  /// PnR script's `SDC_FILE` env var at it.
  String generateSdc() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated SDC for $name');
    if (frequency > 0) {
      final periodNs = 1e9 / frequency;
      buf.writeln(
        'create_clock -name clk -period ${periodNs.toStringAsFixed(3)} '
        '[get_ports {clk}]',
      );
    }
    buf.writeln('set_input_delay 0 -clock clk [all_inputs]');
    buf.writeln('set_output_delay 0 -clock clk [all_outputs]');
    return buf.toString();
  }

  /// Generates a Yosys synthesis TCL script for the top-level design.
  ///
  /// In hierarchical mode, macro modules are replaced with blackbox
  /// stubs so only the glue logic is synthesized at the top level.
  String generateYosysTcl() {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated Yosys synthesis for $topCell');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (yosys -c). The standard-cell liberty',
    );
    buf.writeln(
      '# comes from \$::env(LIB_FILE); RTL/stubs are read relative to',
    );
    buf.writeln(
      '# this script via [info script] so the flow is location-agnostic.',
    );
    if (isHierarchical) {
      buf.writeln('# Mode: hierarchical (${macros.length} macros)');
    }
    buf.writeln();
    buf.writeln('set ipdir [file dirname [info script]]');
    buf.writeln('read_verilog -sv \$ipdir/rtl/*.sv');

    // Read blackbox stubs for hard macros (SRAM, etc.)
    buf.writeln('read_verilog -lib \$ipdir/blackboxes.v');

    // In hierarchical mode, replace macros with blackbox stubs
    if (isHierarchical) {
      buf.writeln();
      buf.writeln('# Replace hardened macros with blackbox stubs');
      buf.writeln('read_verilog \$::env(STUBS_V)');
      for (final macro in macros) {
        buf.writeln('blackbox ${macro.moduleName}');
      }
      buf.writeln();
    }

    buf.writeln('hierarchy -top $topCell -keep_portwidths');
    buf.writeln('synth -top $topCell');
    buf.writeln('dfflibmap -liberty \$::env(LIB_FILE)');
    buf.writeln('abc -liberty \$::env(LIB_FILE)');
    buf.writeln(
      'hilomap -hicell ${lib.tieHighCell} Z '
      '-locell ${lib.tieLowCell} ZN',
    );
    buf.writeln('opt_clean -purge');
    buf.writeln('write_verilog -noattr ${topCell}_synth.v');
    buf.writeln('stat -liberty \$::env(LIB_FILE)');
    return buf.toString();
  }

  /// Generates a Yosys synthesis TCL script for a single macro module.
  ///
  /// Used in hierarchical flow to harden each macro independently.
  String generateMacroYosysTcl(HarborAsicMacro macro) {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln(
      '# Auto-generated Yosys synthesis for macro: ${macro.moduleName}',
    );
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (yosys -c); liberty from \$::env(LIB_FILE),',
    );
    buf.writeln(
      '# RTL read relative to this script. Macro scripts live in the',
    );
    buf.writeln('# ip macros/ subdir, so rtl/ is one level up from here.');
    buf.writeln();
    buf.writeln('set iproot [file dirname [file dirname [info script]]]');
    buf.writeln('read_verilog -sv \$iproot/rtl/*.sv');
    buf.writeln('hierarchy -top ${macro.moduleName}');
    buf.writeln('synth -top ${macro.moduleName} -flatten');
    buf.writeln('dfflibmap -liberty \$::env(LIB_FILE)');
    buf.writeln('abc -liberty \$::env(LIB_FILE)');
    buf.writeln(
      'hilomap -hicell ${lib.tieHighCell} Z '
      '-locell ${lib.tieLowCell} ZN',
    );
    buf.writeln('opt_clean -purge');
    buf.writeln('write_verilog -noattr ${macro.moduleName}_synth.v');
    buf.writeln('stat -liberty \$::env(LIB_FILE)');
    return buf.toString();
  }

  /// Generates an OpenROAD PnR script for a single macro (tile hardening).
  ///
  /// Produces three outputs per macro:
  /// - `<macro>_final.def` - routed layout
  /// - `<macro>.lef` - LEF abstract for top-level placement
  /// - `<macro>.lib` - Liberty timing model for top-level STA
  String generateMacroOpenroadTcl(HarborAsicMacro macro) {
    final lib = provider.standardCellLibrary;
    final m = macro.moduleName;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated OpenROAD macro hardening for $m');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln(
      '# Run by asix.mkTapeout (openroad -exit). Liberty/LEF come from',
    );
    buf.writeln(
      '# the env (LIB_FILE/TECH_LEF/CELL_LEF_DIR); utilization is the',
    );
    buf.writeln(
      '# per-tile TILE_UTIL. asix provides no macro SDC, so timing is',
    );
    buf.writeln('# left unconstrained at the tile level.');
    buf.writeln();

    // Read inputs (paths supplied by asix via env vars)
    buf.writeln('read_liberty \$::env(LIB_FILE)');
    buf.writeln(
      'if {[info exists ::env(TECH_LEF)] && \$::env(TECH_LEF) ne ""} {',
    );
    buf.writeln('    read_lef \$::env(TECH_LEF)');
    buf.writeln('}');
    buf.writeln(
      'foreach _lef [lsort [glob -nocomplain \$::env(CELL_LEF_DIR)/*.lef]] {',
    );
    buf.writeln(
      '    if {[string match *tech* [file tail \$_lef]]} { continue }',
    );
    buf.writeln('    read_lef \$_lef');
    buf.writeln('}');
    buf.writeln('read_verilog ${m}_synth.v');
    buf.writeln('link_design $m');
    buf.writeln();

    // Floorplan
    buf.writeln('initialize_floorplan \\');
    buf.writeln('    -utilization \$::env(TILE_UTIL) \\');
    buf.writeln('    -core_space 2 \\');
    buf.writeln('    -site \$::env(SITE_NAME)');
    buf.writeln();

    // Pin placement on all edges for grid connectivity
    if (macro.pinOnAllEdges) {
      buf.writeln('# Place pins on all edges for macro connectivity');
      buf.writeln('place_pins -hor_layers Metal3 -ver_layers Metal2');
      buf.writeln();
    }

    // Power
    buf.writeln('add_global_connection -net VDD -pin_pattern VDD -power');
    buf.writeln('add_global_connection -net VSS -pin_pattern VSS -ground');
    buf.writeln('global_connect');
    buf.writeln();

    // Placement
    buf.writeln('global_placement -density \$::env(TILE_UTIL)');
    buf.writeln('detailed_placement');
    buf.writeln();

    // CTS
    if (lib.clockBufferCells.isNotEmpty) {
      buf.writeln('estimate_parasitics -placement');
      buf.writeln(
        'clock_tree_synthesis -buf_list '
        '{${lib.clockBufferCells.join(" ")}}',
      );
      buf.writeln('detailed_placement');
      buf.writeln();
    }

    // Routing
    buf.writeln('global_route -allow_congestion');
    buf.writeln('detailed_route');
    buf.writeln();

    // Fill
    if (lib.fillCells.isNotEmpty) {
      buf.writeln('filler_placement ${lib.fillCells.join(" ")}');
      buf.writeln();
    }

    // Output macro artifacts
    buf.writeln('# Macro outputs');
    buf.writeln('write_def ${m}_final.def');
    buf.writeln('write_abstract_lef ${m}.lef');
    buf.writeln('write_timing_model ${m}.lib');
    buf.writeln();
    buf.writeln('report_checks -path_delay min_max > ${m}_timing.rpt');
    buf.writeln('report_design_area > ${m}_area.rpt');

    return buf.toString();
  }

  /// Generates an OpenROAD place-and-route TCL script for the top level.
  ///
  /// In hierarchical mode, reads pre-hardened macro LEF/LIB files
  /// and places them with halos. Routes only on upper metal layers
  /// to avoid DRC violations with macro-internal routing.
  String generateOpenroadTcl() {
    final lib = provider.standardCellLibrary;
    final buf = StringBuffer();
    buf.writeln('# Auto-generated OpenROAD P&R for $topCell');
    buf.writeln('# PDK: ${provider.name}');
    buf.writeln('# Run by asix.mkTapeout (openroad -exit). All PDK paths and');
    buf.writeln('# floorplan knobs come from the env: LIB_FILE/TECH_LEF/');
    buf.writeln('# CELL_LEF_DIR/SYNTH_V/SDC_FILE/SITE_NAME/UTILIZATION/');
    buf.writeln(
      '# MACRO_HALO/PLACEMENT_DENSITY/DROUTE_END_ITER (+optional DIE_AREA).',
    );
    if (isHierarchical) {
      buf.writeln(
        '# Mode: hierarchical assembly '
        '(${macros.length} pre-hardened macros)',
      );
    }
    buf.writeln();

    // Read inputs (paths supplied by asix via env vars). The tech LEF is read
    // explicitly, then every other cell LEF is globbed from CELL_LEF_DIR while
    // skipping anything that looks like the tech LEF (avoids a double read).
    buf.writeln('read_liberty \$::env(LIB_FILE)');
    buf.writeln(
      'if {[info exists ::env(TECH_LEF)] && \$::env(TECH_LEF) ne ""} {',
    );
    buf.writeln('    read_lef \$::env(TECH_LEF)');
    buf.writeln('}');
    buf.writeln(
      'foreach _lef [lsort [glob -nocomplain \$::env(CELL_LEF_DIR)/*.lef]] {',
    );
    buf.writeln(
      '    if {[string match *tech* [file tail \$_lef]]} { continue }',
    );
    buf.writeln('    read_lef \$_lef');
    buf.writeln('}');

    // Read macro LEF/LIB in hierarchical mode (asix copies these into the CWD)
    if (isHierarchical) {
      buf.writeln();
      buf.writeln('# Read hardened macro abstracts');
      for (final macro in macros) {
        buf.writeln('read_lef ${macro.moduleName}.lef');
        buf.writeln('read_liberty ${macro.moduleName}.lib');
      }
    }

    buf.writeln();
    buf.writeln('read_verilog \$::env(SYNTH_V)');
    buf.writeln('link_design $topCell');
    buf.writeln('read_sdc \$::env(SDC_FILE)');
    buf.writeln();

    // Floorplan: a fixed DIE_AREA (fab-slot tapeouts) takes precedence over a
    // utilization-driven auto floorplan. The core is inset from the die by the
    // die margin on every side.
    buf.writeln('if {[info exists ::env(DIE_AREA)]} {');
    buf.writeln('    lassign \$::env(DIE_AREA) _dx0 _dy0 _dx1 _dy1');
    buf.writeln('    set _m ${dieMarginUm.toStringAsFixed(0)}');
    buf.writeln('    initialize_floorplan \\');
    buf.writeln('        -die_area "\$_dx0 \$_dy0 \$_dx1 \$_dy1" \\');
    buf.writeln(
      '        -core_area "[expr {\$_dx0 + \$_m}] [expr {\$_dy0 + \$_m}] [expr {\$_dx1 - \$_m}] [expr {\$_dy1 - \$_m}]" \\',
    );
    buf.writeln('        -site \$::env(SITE_NAME)');
    buf.writeln('} else {');
    buf.writeln('    initialize_floorplan \\');
    buf.writeln('        -utilization \$::env(UTILIZATION) \\');
    buf.writeln('        -core_space ${dieMarginUm.toStringAsFixed(0)} \\');
    buf.writeln('        -site \$::env(SITE_NAME)');
    buf.writeln('}');
    buf.writeln();

    // Macro placement with halos (halo width supplied by asix as MACRO_HALO)
    if (isHierarchical) {
      buf.writeln('# Macro placement with halos');
      for (final macro in macros) {
        buf.writeln(
          'set_macro_halo -halo_x \$::env(MACRO_HALO) '
          '-halo_y \$::env(MACRO_HALO) '
          '[get_cells -hierarchical -filter "ref_name == ${macro.moduleName}"]',
        );
      }
      buf.writeln('macro_placement');
      buf.writeln();
    }

    // Power
    buf.writeln('add_global_connection -net VDD -pin_pattern VDD -power');
    buf.writeln('add_global_connection -net VSS -pin_pattern VSS -ground');
    buf.writeln('global_connect');
    buf.writeln();

    // Placement (density supplied by asix as PLACEMENT_DENSITY)
    buf.writeln('global_placement -density \$::env(PLACEMENT_DENSITY)');
    buf.writeln('detailed_placement');
    buf.writeln();

    // CTS
    if (lib.clockBufferCells.isNotEmpty) {
      buf.writeln('estimate_parasitics -placement');
      buf.writeln(
        'clock_tree_synthesis -buf_list '
        '{${lib.clockBufferCells.join(" ")}}',
      );
      buf.writeln('detailed_placement');
      buf.writeln();
    }

    // Routing - skip lower metal layers in hierarchical mode
    if (isHierarchical && topRoutingMinLayer > 1) {
      buf.writeln(
        '# Skip Metal1-${topRoutingMinLayer - 1} '
        '(used internally by macros)',
      );
      buf.writeln(
        'set_global_routing_layer_adjustment '
        'Metal1-Metal${topRoutingMinLayer - 1} 1.0',
      );
    }
    buf.writeln('global_route -allow_congestion');
    buf.writeln('if {[info exists ::env(DROUTE_END_ITER)]} {');
    buf.writeln('    detailed_route -droute_end_iter \$::env(DROUTE_END_ITER)');
    buf.writeln('} else {');
    buf.writeln('    detailed_route');
    buf.writeln('}');
    buf.writeln();

    // Fill
    if (lib.fillCells.isNotEmpty) {
      buf.writeln('filler_placement ${lib.fillCells.join(" ")}');
      buf.writeln();
    }

    // Reports & outputs
    buf.writeln('report_checks -path_delay min_max > timing.rpt');
    buf.writeln('report_design_area > area.rpt');
    buf.writeln('report_power > power.rpt');
    buf.writeln('write_def ${topCell}_final.def');
    buf.writeln('write_verilog ${topCell}_final.v');

    return buf.toString();
  }
}

/// Supported FPGA vendors / toolchains.
enum HarborFpgaVendor {
  /// Lattice iCE40 - Yosys + nextpnr-ice40
  ice40,

  /// Lattice ECP5 - Yosys + nextpnr-ecp5
  ecp5,

  /// Xilinx Vivado (proprietary)
  vivado,

  /// Xilinx openXC7 (open-source)
  openXc7,
}
