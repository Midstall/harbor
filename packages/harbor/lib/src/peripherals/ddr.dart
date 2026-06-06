import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import 'ddr_phy_ecp5.dart';
import 'ddr_sequencer.dart';
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

/// SDRAM memory controller: a bus slave face over a PHY-agnostic
/// [DdrSequencer] and a target-specific PHY.
///
/// DDR3/DDR3L is implemented with [DdrPhyEcp5] (ODDRX1F/IDDRX1F gearing,
/// DLL-off, hardware-verified on the OrangeCrab). Other memory types are
/// unimplemented shells until their PHYs exist; a Xilinx 7-series PHY for
/// the Arty S7 reuses the sequencer.
class HarborDdrController extends BridgeModule
    with HarborDeviceTreeNodeProvider {
  /// Memory configuration.
  final HarborDdrConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// The controller/bus clock in Hz. All DRAM timing counters derive from
  /// this clock, not from [HarborDdrConfig.frequency] (the part's rated
  /// speed): in the DLL-off bring-up configuration, DDR CK runs at the
  /// system clock.
  final int clockHz;

  /// Bring-up diagnostic, see [DdrSequencer.mprDebug]: every read returns
  /// the part's MPR training pattern (0xFFFF0000) instead of array data.
  final bool mprDebug;

  /// Bus slave port (CPU-side).
  late final BusSlavePort bus;

  HarborDdrController({
    required this.config,
    required this.baseAddress,
    this.clockHz = 48000000,
    int? busAddressWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    this.mprDebug = false,
    String? name,
  }) : super('HarborDdrController', name: name ?? 'ddr') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // System-side bus interface. The port carries the SoC bus width when
    // given (the fabric connects same-width interfaces); the address is
    // masked down to the memory's span internally.
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth ?? config.size.bitLength,
      dataWidth: config.isSdr ? config.dataWidth : config.dataWidth * 2,
    );

    // SDRAM pin signals (active-low control)
    createPort('sdram_ck', PortDirection.output);
    createPort('sdram_cke', PortDirection.output);
    createPort('sdram_cs_n', PortDirection.output);
    createPort('sdram_ras_n', PortDirection.output);
    createPort('sdram_cas_n', PortDirection.output);
    createPort('sdram_we_n', PortDirection.output);
    // Bank address is log2(banks) wide (8 banks -> ba[2:0]).
    createPort(
      'sdram_ba',
      PortDirection.output,
      width: (config.banks - 1).bitLength,
    );
    createPort('sdram_addr', PortDirection.output, width: config.rowWidth);
    createPort('sdram_dm', PortDirection.output, width: config.dataWidth ~/ 8);
    createPort('sdram_dq', PortDirection.inOut, width: config.dataWidth);

    // DDR-specific signals (not present on SDR). CK# and DQS# are explicit
    // pseudo-differential complements: the part's clock and strobe
    // receivers are differential, and the FPGA flow does not build the
    // complement side of "D"-suffixed SSTL output types.
    if (config.isDdr) {
      createPort('sdram_ck_n', PortDirection.output);
      createPort(
        'sdram_dqs',
        PortDirection.inOut,
        width: config.dataWidth ~/ 8,
      );
      createPort(
        'sdram_dqs_n',
        PortDirection.inOut,
        width: config.dataWidth ~/ 8,
      );
      createPort('sdram_odt', PortDirection.output);
      createPort('sdram_reset_n', PortDirection.output);
    }

    if (config.type == HarborDdrType.ddr3 ||
        config.type == HarborDdrType.ddr3l) {
      _buildDdr3();
    }
    // Other memory types remain unimplemented shells for now.
  }

  /// Wires the DDR3 datapath: bus face -> [DdrSequencer] <-> [DdrPhyEcp5] ->
  /// pads. Single outstanding transaction; the ack carries read data latched
  /// from the PHY's capture window.
  void _buildDdr3() {
    final clk = input('clk');
    final reset = input('reset');
    final clkMhz = (clockHz / 1000000).round().clamp(1, 400);

    // Bus face: latch one request, run it, ack on completion.
    final busy = Logic(name: 'ddr_busy');
    final req = Logic(name: 'ddr_req');
    final reqWe = Logic(name: 'ddr_req_we');
    final reqAddr = Logic(name: 'ddr_req_addr', width: 32);
    final reqData = Logic(name: 'ddr_req_data', width: 32);
    final reqSel = Logic(name: 'ddr_req_sel', width: 4);
    final rdWord = Logic(name: 'ddr_rd_word', width: 32);

    final seq = DdrSequencer(
      clk,
      reset,
      req,
      reqWe,
      reqAddr,
      reqData,
      reqSel,
      config: config,
      clkMhz: clkMhz,
      mprDebug: mprDebug,
    );

    final dqIn = Logic(name: 'ddr_dq_in', width: config.dataWidth);
    final phy = DdrPhyEcp5(
      clk,
      reset,
      cke: seq.cke,
      csN: seq.csN,
      cmd: seq.cmd,
      ba: seq.ba,
      addr: seq.addr,
      odt: seq.odt,
      resetN: seq.resetN,
      wrStart: seq.wrStart,
      wrData: seq.wrData,
      wrMask: seq.wrMask,
      beatSel: seq.beatSel,
      rdStart: seq.rdStart,
      dqIn: dqIn,
      rowBits: config.rowWidth,
      baBits: (config.banks - 1).bitLength,
      dataBits: config.dataWidth,
      clkMhz: clkMhz,
    );

    Sequential(clk, reset: reset, [
      bus.ack < 0,
      // ~ack keeps the ack-cycle strobe overhang from re-latching the same
      // request: the master drops stb only after it has sampled the ack.
      If(
        ~busy & ~bus.ack & bus.stb,
        then: [
          busy < 1,
          req < 1,
          reqWe < bus.we,
          // Base-relative: only the span's bits address the part, so a set
          // bit of an (aligned) base can never leak into the row address.
          reqAddr <
              (bus.addr.zeroExtend(32) &
                  Const(BigInt.from(config.size - 1), width: 32)),
          reqData < bus.dataIn.getRange(0, 32),
          reqSel < bus.sel.getRange(0, 4),
        ],
      ),
      // The sequencer consumes the request at its IDLE state; drop the
      // strobe once it leaves IDLE (it latched everything it needs).
      If(seq.rdStart | seq.wrStart, then: [req < 0]),
      If(phy.rdValid, then: [rdWord < phy.rdData]),
      If(busy & seq.busDone, then: [busy < 0, bus.ack < 1]),
    ]);
    bus.dataOut <= rdWord.zeroExtend(bus.dataOut.width);

    // Pads.
    output('sdram_ck') <= phy.ckOut;
    output('sdram_cke') <= phy.ckeOut;
    output('sdram_cs_n') <= phy.csNOut;
    output('sdram_ras_n') <= phy.rasNOut;
    output('sdram_cas_n') <= phy.casNOut;
    output('sdram_we_n') <= phy.weNOut;
    output('sdram_ba') <= phy.baOut;
    output('sdram_addr') <= phy.addrOut;
    output('sdram_dm') <= phy.dmOut;
    if (config.isDdr) {
      output('sdram_ck_n') <= phy.ckNOut;
      output('sdram_odt') <= phy.odtOut;
      output('sdram_reset_n') <= phy.resetNOut;
    }

    // Bidirectional DQ/DQS through tristate drivers; reads sample the pad.
    final dqPad = inOut('sdram_dq');
    final dqDrive = TriStateBuffer(phy.dqOut, enable: phy.dqOe);
    dqPad <= dqDrive.out;
    dqIn <= dqPad;
    if (config.isDdr) {
      final dqsPad = inOut('sdram_dqs');
      final dqsDrive = TriStateBuffer(phy.dqsOut, enable: phy.dqsOe);
      dqsPad <= dqsDrive.out;
      final dqsNPad = inOut('sdram_dqs_n');
      final dqsNDrive = TriStateBuffer(phy.dqsNOut, enable: phy.dqsOe);
      dqsNPad <= dqsNDrive.out;
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
