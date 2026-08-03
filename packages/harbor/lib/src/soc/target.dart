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

/// Implemented by a bus master that exposes a debug module over the FPGA
/// config-JTAG BSCAN tunnel (e.g. a RISC-V DM). When a SoC has such a master
/// and an FPGA target, [HarborSoC.generateAll] auto-emits an `openocd.cfg` via
/// [HarborFpgaTarget.generateOpenocdConfig].
abstract interface class HarborJtagDebug {
  /// Inner debug-module IR width in bits for the nested BSCAN tunnel.
  int get jtagInnerIrWidth;

  /// The debug module's JTAG IDCODE, or null if unknown.
  int? get jtagDmIdcode;
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

  /// Name of the top-level clock input port, used for the timing constraint in
  /// the generated constraint file. Defaults to `'clk'`.
  final String clockPortName;

  /// Optional bitstream programming command for a `prog` Makefile target
  /// (e.g. `'openFPGALoader -b ulx3s \$(TOP).bit'`). When null, no `prog`
  /// target is emitted.
  final String? progCommand;

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
    this.clockPortName = 'clk',
    this.progCommand,
  });

  /// iCE40 UP5K target using Yosys + nextpnr-ice40.
  const HarborFpgaTarget.ice40({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
  }) : name = 'ice40-$device',
       vendor = HarborFpgaVendor.ice40;

  /// Lattice ECP5 target using Yosys + nextpnr-ecp5.
  const HarborFpgaTarget.ecp5({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
  }) : name = 'ecp5-$device',
       vendor = HarborFpgaVendor.ecp5;

  /// Xilinx Spartan 7 target using Vivado or openXC7.
  const HarborFpgaTarget.spartan7({
    required this.device,
    required this.package,
    this.frequency = 0,
    this.pinMap = const {},
    this.extraConstraints = const {},
    this.clockPortName = 'clk',
    this.progCommand,
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

  /// prjxray architecture family string for the openXC7 flow.
  ///
  /// Used as the `fasm2frames --db-root $(XRAY_DB)/<family>` segment and the
  /// `xc7frames2bit --part_file $(XRAY_DB)/<family>/<part>/part.yaml` path. Only
  /// meaningful for the Xilinx vendors (empty otherwise).
  String get _prjxrayFamily => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 'spartan7',
    HarborFpgaVendor.ice40 || HarborFpgaVendor.ecp5 => '',
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
        // -abc2 -relut: extra ABC pass plus LUT re-mapping. Measured on the
        // stream_v1/up5k bring-up: 4160 -> 3822 LUT4s (~8%) for synth time.
        buf.writeln(
          'synth_ice40 -abc2 -relut -top $topCell -json $topCell.json',
        );
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

  /// Boundary-scan TAP IR length for this FPGA family.
  int get jtagIrLength => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 6, // Xilinx 7-series
    HarborFpgaVendor.ecp5 => 8,
    HarborFpgaVendor.ice40 => 8,
  };

  /// The config-JTAG user-register instruction a debug BSCAN tunnel rides.
  /// Xilinx 7-series USER4 = 0x23 (riscv-openocd's bscan tunnel hardcodes USER4
  /// for tunneled DMI scans, so the DM must sit on it); ECP5 ER1 = 0x32.
  int get jtagUserInstruction => switch (vendor) {
    HarborFpgaVendor.vivado || HarborFpgaVendor.openXc7 => 0x23,
    HarborFpgaVendor.ecp5 => 0x32,
    HarborFpgaVendor.ice40 => 0x00,
  };

  /// Known boundary-scan IDCODE for this device, or null to accept any.
  int? get jtagIdcode => switch (device.toLowerCase()) {
    'xc7s50' => 0x0362F093,
    'xc7s25' => 0x0362D093,
    'lfe5u-25f' => 0x41111043,
    'lfe5u-45f' => 0x41112043,
    'lfe5u-85f' => 0x41113043,
    _ => null,
  };

  /// Generates an OpenOCD config to reach a RISC-V debug module that is tunneled
  /// through this FPGA's config JTAG (Xilinx BSCANE2 on USER1, ECP5 JTAGG ER1)
  /// with a SiFive nested-tap BSCAN tunnel. The adapter and outer TAP come from
  /// this target; [innerIrWidth] and [dmIdcode] describe the inner DM (River's
  /// DM is irWidth 5, idcode 0x10000001). The FTDI adapter defaults to the
  /// Digilent Arty FT2232H layout on Xilinx; override for another board.
  String generateOpenocdConfig({
    required int innerIrWidth,
    int? dmIdcode,
    int adapterSpeedKHz = 1000,
    String targetName = 'cpu',
  }) {
    String hex(int v, int width) =>
        '0x${v.toRadixString(16).padLeft(width, '0')}';

    final buf = StringBuffer();
    buf.writeln(
      '# Auto-generated by Harbor. OpenOCD for a RISC-V debug module',
    );
    buf.writeln(
      '# tunneled through the $name config JTAG (BSCAN tunnel on the',
    );
    buf.writeln('# ${vendor.name} TAP). Launch: openocd -f openocd.cfg');
    buf.writeln();

    // Adapter: the config-JTAG entry point.
    switch (vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        buf.writeln('adapter driver ftdi');
        buf.writeln('ftdi vid_pid 0x0403 0x6010');
        buf.writeln('ftdi channel 0');
        buf.writeln('ftdi layout_init 0x0088 0x008b');
      case HarborFpgaVendor.ecp5:
        buf.writeln('adapter driver dirtyjtag');
      case HarborFpgaVendor.ice40:
        buf.writeln('adapter driver ftdi');
    }
    buf.writeln('transport select jtag');
    buf.writeln('adapter speed $adapterSpeedKHz');
    buf.writeln();

    // Outer FPGA TAP.
    buf.writeln('set _CHIPNAME ${device.toLowerCase()}');
    final fid = jtagIdcode;
    buf.writeln(
      'jtag newtap \$_CHIPNAME tap -irlen $jtagIrLength '
      '-expected-id ${fid != null ? hex(fid, 8) : hex(0, 8)}',
    );
    buf.writeln(
      'set _USER ${hex(jtagUserInstruction, 2)}  ;# config-JTAG user register '
      'the DM tunnels through',
    );
    buf.writeln();

    // RISC-V target on the outer TAP. Create it BEFORE any `riscv` subcommand:
    // the `riscv` command group only registers once a riscv target exists.
    buf.writeln('set _TARGETNAME \$_CHIPNAME.$targetName');
    buf.writeln(
      'target create \$_TARGETNAME riscv -chain-position \$_CHIPNAME.tap',
    );
    if (dmIdcode != null) {
      buf.writeln('# inner DM IDCODE ${hex(dmIdcode, 8)}');
    }
    buf.writeln();

    // Enable the nested-tap BSCAN tunnel before init so examination reaches the
    // inner DM through it (hardware-proven: OpenOCD examines the RISC-V DM and
    // reads DDR over SBA through this). Then prefer System Bus Access so memory
    // (e.g. DDR) reads/writes without halting the core.
    buf.writeln(
      '# SiFive nested-tap BSCAN tunnel, inner DM IR width $innerIrWidth.',
    );
    buf.writeln('riscv use_bscan_tunnel $innerIrWidth 0');
    buf.writeln('riscv set_mem_access sysbus progbuf abstract');
    buf.writeln();

    buf.writeln('init');
    buf.writeln('irscan \$_CHIPNAME.tap \$_USER');
    buf.writeln('targets');
    return buf.toString();
  }

  /// Per-device DDR train-SERDES pre-place geometry for the openXC7 flow.
  ///
  /// The DDR PHY's bitslip-reference train SERDES must be pinned off the dead
  /// `_SING` OLOGIC/ILOGIC tile (missing prjxray PIPs make its capture dead).
  /// Lane 0 pins to `X<column>Y<baseY>`, lane `l` to
  /// `X<column>Y<baseY + l*strideY>`; the dead `_SING` tile sits one stride
  /// above lane 0 (`baseY - strideY`). Each lane's OSERDESE2/ISERDESE2 pair
  /// shares the SAME tile (they loop back via OFB).
  ///
  /// Keyed by the lower-case device part. Add an entry per verified part.
  static const Map<String, _DdrPreplaceGeom> _ddrPreplaceGeom = {
    // Verified on the Arty S7 (xc7s50), 2 lanes: lane0 -> X0Y145,
    // lane1 -> X0Y141, dead _SING -> X0Y149.
    'xc7s50': _DdrPreplaceGeom(baseY: 145, strideY: -4, column: 0),
  };

  /// Generates the nextpnr-xilinx `--pre-place` Python script
  /// (`support/nextpnr/constraints.py`) for the openXC7 DDR3 flow.
  ///
  /// It pins each of the [lanes] DDR train SERDES pairs off the dead `_SING`
  /// tile using the [device]-keyed [_ddrPreplaceGeom]. When the device is not
  /// in the map, the xc7s50 geometry is used as a fallback and a warning
  /// header notes that the placement is unverified for the part.
  String generateDdrPreplacePy({required int lanes}) {
    final geom = _ddrPreplaceGeom[device.toLowerCase()];
    // Fallback geometry (xc7s50) when the part is unknown: still emit, but flag.
    final g =
        geom ?? const _DdrPreplaceGeom(baseY: 145, strideY: -4, column: 0);
    final singY =
        g.baseY - g.strideY; // dead _SING tile, one stride above lane 0

    final buf = StringBuffer();
    if (geom == null) {
      buf.writeln(
        '# WARNING: device "$device" has no verified DDR train-SERDES tile',
      );
      buf.writeln(
        '# placement in Harbor. The geometry below is the xc7s50 default and is',
      );
      buf.writeln(
        '# UNVERIFIED for this part - confirm the OLOGIC/ILOGIC tile Y range.',
      );
    }
    buf.writeln(
      '# Pin the bitslip-reference train serdes off the _SING tile '
      '(X${g.column}Y$singY, which has',
    );
    buf.writeln(
      '# missing prjxray PIPs -> dead capture). Each lane\'s '
      'OSERDESE2/ISERDESE2 pair',
    );
    buf.writeln(
      '# must share the SAME ILOGIC/OLOGIC tile (they loop back via OFB).',
    );
    buf.writeln('def get_cells(part):');
    buf.writeln('    return [c.second for c in ctx.cells if part in c.first]');
    final pairs = [
      for (var l = 0; l < lanes; l++)
        "('$l', 'X${g.column}Y${g.baseY + l * g.strideY}')",
    ];
    buf.writeln('pairs = [${pairs.join(', ')}]');
    buf.writeln('for suf, y in pairs:');
    buf.writeln("    for c in get_cells('train_oserdes_' + suf):");
    buf.writeln("        c.setAttr('BEL', 'OLOGIC_' + y + '/OSERDESE2')");
    buf.writeln(
      "        print('PREPLACE train_oserdes_%s -> OLOGIC_%s' % (suf, y))",
    );
    buf.writeln("    for c in get_cells('train_iserdes_' + suf):");
    buf.writeln("        c.setAttr('BEL', 'ILOGIC_' + y + '/ISERDESE2')");
    buf.writeln(
      "        print('PREPLACE train_iserdes_%s -> ILOGIC_%s' % (suf, y))",
    );
    return buf.toString();
  }

  /// Generates the nextpnr-xilinx `--pre-route` BEL-placement diagnostic
  /// (`support/nextpnr/show_bels.py`) for the openXC7 DDR3 flow. It prints
  /// where the train SERDES landed after placement so a bad pin is visible.
  String generateDdrShowBelsPy() {
    final buf = StringBuffer();
    buf.writeln('def show(name_part):');
    buf.writeln('    found=False');
    buf.writeln('    for c in ctx.cells:');
    buf.writeln('        if name_part in c.first:');
    buf.writeln(
      '            print("BELCHK", c.first, "->", c.second.bel); found=True',
    );
    buf.writeln('    if not found: print("BELCHK none:", name_part)');
    buf.writeln("show('ISERDESE2_train')");
    buf.writeln("show('OSERDESE2_train')");
    return buf.toString();
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
    } else if (vendor == HarborFpgaVendor.openXc7) {
      // openXC7 (nextpnr-xilinx + prjxray) flow: json -> fasm -> frames -> bit.
      // The tools nextpnr-xilinx / fasm2frames / xc7frames2bit are assumed on
      // PATH in the dev shell; the data files come from Make variables the
      // caller (nix/user) can override with `?=`.
      buf.writeln();
      buf.writeln(
        '# openXC7 (nextpnr-xilinx + prjxray) place-and-route + pack.',
      );
      buf.writeln(
        '# CHIPDB / XRAY_DB / PART / SEED are overridable (nix supplies them).',
      );
      buf.writeln(
        '# Default CHIPDB is the nextpnr-xilinx chipdb for this device/package.',
      );
      buf.writeln(
        'CHIPDB ?= \$(NEXTPNR_XILINX_CHIPDB)/\$(DEVICE)\$(PACKAGE).bin',
      );
      buf.writeln('XRAY_DB ?= \$(PRJXRAY_DB)');
      buf.writeln('PART ?= \$(DEVICE)\$(PACKAGE)-1');
      buf.writeln('FAMILY = $_prjxrayFamily');
      buf.writeln('SEED ?= 1');
      buf.writeln(
        '# --pre-place/--pre-route hooks activate only when Harbor emitted the',
      );
      buf.writeln(
        '# DDR train-serdes scripts (openXC7 + DDR peripheral); empty otherwise.',
      );
      buf.writeln(
        'PREPLACE := \$(if \$(wildcard support/nextpnr/constraints.py),'
        '--pre-place support/nextpnr/constraints.py '
        '--pre-route support/nextpnr/show_bels.py,)',
      );
      buf.writeln();
      buf.writeln('pnr: \$(TOP).fasm');
      buf.writeln('\$(TOP).fasm: \$(TOP).json \$(TOP).$constraintExtension');
      buf.writeln(
        '\tnextpnr-xilinx --chipdb \$(CHIPDB) --xdc \$(TOP).$constraintExtension '
        '--json \$(TOP).json --write \$(TOP)_routed.json --fasm \$(TOP).fasm '
        '\$(PREPLACE) --seed \$(SEED)',
      );
      buf.writeln();
      buf.writeln('pack: \$(TOP).$bitstreamExtension');
      buf.writeln('\$(TOP).frames: \$(TOP).fasm');
      buf.writeln(
        '\tfasm2frames --db-root \$(XRAY_DB)/\$(FAMILY) --part \$(PART) '
        '\$(TOP).fasm \$(TOP).frames',
      );
      buf.writeln('\$(TOP).$bitstreamExtension: \$(TOP).frames');
      buf.writeln(
        '\txc7frames2bit --part_file \$(XRAY_DB)/\$(FAMILY)/\$(PART)/part.yaml '
        '--part_name \$(PART) --frm_file \$(TOP).frames '
        '--output_file \$(TOP).$bitstreamExtension',
      );
    }

    // Bitstream programming (loads the board over USB/JTAG).
    if (progCommand != null) {
      buf.writeln();
      buf.writeln('.PHONY: prog');
      buf.writeln('prog: all');
      buf.writeln('\t$progCommand');
    }

    buf.writeln();
    buf.writeln('clean:');
    buf.writeln(
      '\trm -f \$(TOP).json \$(TOP).asc \$(TOP).config '
      '\$(TOP).fasm \$(TOP).frames \$(TOP)_routed.json '
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

  /// A pin map value is the site name, optionally followed by
  /// whitespace-separated IO attributes (e.g. `"C17 SSTL135_I
  /// TERMINATION=OFF"`). The site is always the first token.
  static String _site(String value) => value.trim().split(RegExp(r'\s+')).first;

  /// The IO attributes of a pin map value (everything after the site).
  static List<String> _ioAttrs(String value) =>
      value.trim().split(RegExp(r'\s+')).skip(1).toList();

  String _generatePcf() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated PCF for $name');
    for (final entry in pinMap.entries) {
      buf.writeln('set_io ${entry.key} ${_site(entry.value)}');
    }
    if (frequency > 0) {
      final clkPin = pinMap[clockPortName];
      if (clkPin != null) {
        buf.writeln('set_frequency $clockPortName ${frequency / 1e6}');
      }
    }
    return buf.toString();
  }

  /// ECP5 CSFBGA285 ball -> I/O bank, for the DDR3 SSTL135 banks only (the rest
  /// of the package returns null = not a tracked DDR bank). VERIFIED against the
  /// nextpnr iodb / PnR VREF assignment for the OrangeCrab creek_ddrlevel build:
  /// "Using pin C15 as VREF for bank 7" and "Using pin H15 as VREF for bank 6" -
  /// the DQ/DQS input banks are 6 (lane1) and 7 (lane0). VREF is auto-selected by
  /// nextpnr for SSTL135_I, so only the VCCIO declaration is needed.
  ///
  /// Bank 7 carries lane-0 DQ/DQS (balls A13..A17, B13..B17, C16..C17, D15..D16,
  /// + B15 DQS0, C15 VREF). Bank 6 carries lane-1 DQ/DQS (F15..F18, G15..G18,
  /// H16, J16, C18, + G18 DQS1, H15 VREF). Mapped by the ball's row letter +
  /// column band, with the verified per-ball EXCEPTIONS that the row split gets
  /// wrong (C18 is a bank-6 lane-1 DQ ball, NOT bank 7 despite row C).
  static int? _ddrBankOf(String ball) {
    final m = RegExp(r'^([A-Z])(\d+)$').firstMatch(ball);
    if (m == null) return null;
    final row = m.group(1)!;
    final col = int.parse(m.group(2)!);
    if (col < 13) return null; // cmd/addr (SSTL outputs, no VREF) - not tracked
    // Verified per-ball exceptions to the row split (from the iodb / litex
    // OrangeCrab pinout): C18 is a lane-1 DQ ball in bank 6, not bank 7.
    if (ball == 'C18') return 6;
    // Right edge, columns 13..18: rows A..D -> bank 7, rows E..L -> bank 6.
    if ('ABCD'.contains(row)) return 7;
    if ('EFGHJKL'.contains(row)) return 6;
    return null;
  }

  String _generateLpf() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated LPF for $name');
    // Collect the DDR SSTL135 banks (from the DQ/DQS input pins) so each gets a
    // single VCCIO declaration. The SSTL135 input threshold is referenced to
    // VCCIO/2. Without an explicit BANK VCCIO the threshold is left undefined
    // (litex/Lattice ECP5 DDR3 lpf always sets it). Deduped, emitted once.
    final ddrBanks = <int>{};
    for (final entry in pinMap.entries) {
      final attrs = _ioAttrs(entry.value);
      final ioType = attrs.where((a) => !a.contains('=')).firstOrNull;
      if (ioType != null && ioType.startsWith('SSTL135')) {
        final bank = _ddrBankOf(_site(entry.value));
        if (bank != null) ddrBanks.add(bank);
      }
    }
    for (final bank in ddrBanks.toList()..sort()) {
      buf.writeln('BANK $bank VCCIO 1.35 V;');
    }
    for (final entry in pinMap.entries) {
      final attrs = _ioAttrs(entry.value);
      // A bare IO type may be given as the first attribute. Anything with
      // an '=' passes through verbatim (TERMINATION, DIFFRESISTOR, ...).
      final ioType = attrs.where((a) => !a.contains('=')).firstOrNull;
      final extras = attrs.where((a) => a.contains('=')).join(' ');
      buf.writeln('LOCATE COMP "${entry.key}" SITE "${_site(entry.value)}";');
      buf.writeln(
        'IOBUF PORT "${entry.key}" IO_TYPE=${ioType ?? 'LVCMOS33'}'
        '${extras.isEmpty ? '' : ' $extras'};',
      );
    }
    if (frequency > 0) {
      buf.writeln(
        'FREQUENCY PORT "$clockPortName" '
        '${(frequency / 1e6).toStringAsFixed(1)} MHz;',
      );
    }
    return buf.toString();
  }

  String _generateXdc() {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated XDC for $name');
    for (final entry in pinMap.entries) {
      final attrs = _ioAttrs(entry.value);
      final ioStandard = attrs.where((a) => !a.contains('=')).firstOrNull;
      // No braces around the port name in get_ports: the open-source
      // nextpnr-xilinx XDC parser rejects `[get_ports {name}]` (asserts on the
      // brace token), unlike Vivado which accepts either form.
      buf.writeln(
        'set_property -dict {PACKAGE_PIN ${_site(entry.value)} '
        'IOSTANDARD ${ioStandard ?? 'LVCMOS33'}} '
        '[get_ports ${entry.key}]',
      );
    }
    if (frequency > 0) {
      final periodNs = 1e9 / frequency;
      buf.writeln(
        'create_clock -period ${periodNs.toStringAsFixed(3)} '
        '[get_ports $clockPortName]',
      );
    }
    // Extra raw XDC lines (values emitted verbatim). Used for openXC7 clock-BEL
    // placement constraints the auto placer gets wrong, e.g. pinning the DDR3
    // PHY's regional clock buffers (BUFHCE) into the DDR bank's clock region so
    // the BUFG->BUFH dedicated arc routes (nextpnr-xilinx otherwise places them
    // in the wrong clock region and the dedicated clock router rejects the arc).
    // The key is a label only, the value is the full XDC line.
    for (final line in extraConstraints.values) {
      buf.writeln(line);
    }
    return buf.toString();
  }
}

/// DDR train-SERDES pre-place tile geometry for one FPGA part (openXC7 flow).
///
/// See [HarborFpgaTarget.generateDdrPreplacePy]. Lane `l`'s OSERDESE2/ISERDESE2
/// pair pins to `X<column>Y<baseY + l*strideY>`.
class _DdrPreplaceGeom {
  /// OLOGIC/ILOGIC tile Y for lane 0.
  final int baseY;

  /// Per-lane Y delta (negative descends the tile column).
  final int strideY;

  /// OLOGIC/ILOGIC tile X column.
  final int column;

  const _DdrPreplaceGeom({
    required this.baseY,
    required this.strideY,
    required this.column,
  });
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
  /// - `<macro>_final.def`: routed layout
  /// - `<macro>.lef`: LEF abstract for top-level placement
  /// - `<macro>.lib`: Liberty timing model for top-level STA
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

    // Routing: skip lower metal layers in hierarchical mode
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
  /// Lattice iCE40: Yosys + nextpnr-ice40
  ice40,

  /// Lattice ECP5: Yosys + nextpnr-ecp5
  ecp5,

  /// Xilinx Vivado (proprietary)
  vivado,

  /// Xilinx openXC7 (open-source)
  openXc7,
}
