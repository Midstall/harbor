import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// SDRAM memory type.
enum HarborDdrType {
  /// SDR SDRAM (single data rate, legacy).
  sdr,

  /// DDR SDRAM (double data rate, first generation).
  ddr,

  /// DDR2 SDRAM.
  ddr2,

  /// DDR3 SDRAM (e.g., OrangeCrab).
  ddr3,

  /// DDR3L (low-voltage DDR3, e.g., Arty S7).
  ddr3l,

  /// DDR4 SDRAM.
  ddr4,

  /// DDR5 SDRAM.
  ddr5,

  /// LPDDR4 (low-power).
  lpddr4,

  /// LPDDR5 (low-power).
  lpddr5,
}

/// SDRAM memory configuration.
class HarborDdrConfig with HarborPrettyString {
  /// Memory type.
  final HarborDdrType type;

  /// Total memory size in bytes.
  final int size;

  /// Data bus width in bits (typically 8, 16, or 32).
  final int dataWidth;

  /// Clock frequency in Hz.
  final int frequency;

  /// Number of ranks.
  final int ranks;

  /// Number of bank groups (DDR4/5) or banks (SDR/DDR/DDR2/DDR3).
  final int banks;

  /// Row address width.
  final int rowWidth;

  /// Column address width.
  final int colWidth;

  /// CAS latency.
  final int casLatency;

  const HarborDdrConfig({
    required this.type,
    required this.size,
    this.dataWidth = 16,
    required this.frequency,
    this.ranks = 1,
    this.banks = 8,
    this.rowWidth = 15,
    this.colWidth = 10,
    this.casLatency = 6,
  });

  /// Generic SDR SDRAM config (e.g., IS42S16160G: 32MB, 16-bit, 133 MHz).
  const HarborDdrConfig.sdr({
    this.size = 32 * 1024 * 1024,
    this.dataWidth = 16,
    this.frequency = 133000000,
    this.banks = 4,
    this.rowWidth = 13,
    this.colWidth = 9,
    this.casLatency = 3,
  }) : type = HarborDdrType.sdr,
       ranks = 1;

  /// OrangeCrab DDR3 config (128MB, 16-bit, 400 MHz).
  const HarborDdrConfig.orangeCrab()
    : type = HarborDdrType.ddr3,
      size = 128 * 1024 * 1024,
      dataWidth = 16,
      frequency = 400000000,
      ranks = 1,
      banks = 8,
      rowWidth = 15,
      colWidth = 10,
      casLatency = 6;

  /// Arty S7 DDR3L config (256MB, 16-bit, 333 MHz).
  const HarborDdrConfig.artyS7()
    : type = HarborDdrType.ddr3l,
      size = 256 * 1024 * 1024,
      dataWidth = 16,
      frequency = 333333333,
      ranks = 1,
      banks = 8,
      rowWidth = 15,
      colWidth = 10,
      casLatency = 5;

  /// Whether this is single data rate (SDR) SDRAM.
  bool get isSdr => type == HarborDdrType.sdr;

  /// Whether this is any DDR variant (double data rate).
  bool get isDdr => !isSdr;

  /// Frequency in MHz.
  double get frequencyMhz => frequency / 1e6;

  /// Data rate in MT/s (DDR = 2x clock, SDR = 1x clock).
  int get dataRate => isSdr ? frequency : frequency * 2;

  /// Bandwidth in MB/s.
  double get bandwidthMBs => dataRate * dataWidth / 8 / 1e6;

  @override
  String toString() =>
      'HarborDdrConfig(${type.name}, ${size ~/ (1024 * 1024)} MB, '
      '${frequencyMhz.toStringAsFixed(0)} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDdrConfig(\n');
    buf.writeln('${c}type: ${type.name},');
    buf.writeln('${c}size: ${size ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}dataWidth: $dataWidth bits,');
    buf.writeln(
      '${c}frequency: ${frequencyMhz.toStringAsFixed(0)} MHz (${dataRate ~/ 1000000} MT/s),',
    );
    buf.writeln('${c}bandwidth: ${bandwidthMBs.toStringAsFixed(0)} MB/s,');
    buf.writeln('${c}CL: $casLatency,');
    buf.writeln('${c}banks: $banks, rows: $rowWidth, cols: $colWidth,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SDRAM memory controller.
///
/// Supports SDR SDRAM through DDR5, providing a bus slave interface
/// to external memory. The actual PHY is target-specific:
/// - SDR: direct pin connection (no serialization needed)
/// - ECP5: uses ECLK/DQSBUF primitives (LiteDRAM pattern)
/// - Xilinx 7: uses MIG (Memory Interface Generator) IP
///
/// This module provides the controller logic. The PHY is
/// instantiated separately or via a vendor-specific wrapper.
class HarborDdrController extends BridgeModule
    with HarborDeviceTreeNodeProvider {
  /// Memory configuration.
  final HarborDdrConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (CPU-side).
  late final BusSlavePort bus;

  HarborDdrController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborDdrController', name: name ?? 'ddr') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // System-side bus interface
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: config.size.bitLength,
      dataWidth: config.isSdr ? config.dataWidth : config.dataWidth * 2,
    );

    // SDRAM pin signals (active-low control)
    createPort('sdram_ck', PortDirection.output);
    createPort('sdram_cke', PortDirection.output);
    createPort('sdram_cs_n', PortDirection.output);
    createPort('sdram_ras_n', PortDirection.output);
    createPort('sdram_cas_n', PortDirection.output);
    createPort('sdram_we_n', PortDirection.output);
    createPort('sdram_ba', PortDirection.output, width: config.banks.bitLength);
    createPort('sdram_addr', PortDirection.output, width: config.rowWidth);
    createPort('sdram_dm', PortDirection.output, width: config.dataWidth ~/ 8);
    createPort('sdram_dq', PortDirection.inOut, width: config.dataWidth);

    // DDR-specific signals (not present on SDR)
    if (config.isDdr) {
      createPort(
        'sdram_dqs',
        PortDirection.inOut,
        width: config.dataWidth ~/ 8,
      );
      createPort('sdram_odt', PortDirection.output);
      createPort('sdram_reset_n', PortDirection.output);
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: [
      'harbor,sdram-controller',
      if (config.isSdr) 'harbor,sdr-sdram',
      if (config.type == HarborDdrType.ddr3 ||
          config.type == HarborDdrType.ddr3l)
        'harbor,ddr3-sdram',
    ],
    reg: BusAddressRange(baseAddress, config.size),
    properties: {
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
    },
  );
}
