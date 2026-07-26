import 'dart:io' show Platform;

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../clock/wishbone_cdc.dart';
import '../clock/wishbone_cdc_fifo.dart';
import '../clock/wishbone_downsizer.dart';
import '../clock/wishbone_read_retry.dart';
import '../bus/bus.dart';
import 'ddr_phy.dart';
import 'ddr_phy_ecp5.dart';
import 'ddr_phy_xilinx.dart';
import 'ddr_xilinx_read_train.dart';
import 'ddr_sequencer.dart';
import 'ecp5_delay_controller.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
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

/// Which PHY a build target selects.
enum _DdrPhyKind {
  /// Lattice ECP5 / iCE40 (and the default when no target is given).
  ecp5,

  /// Xilinx 7-series (Spartan 7), via Vivado or openXC7.
  xilinx,
}

/// Maps a build target to the PHY it selects.
_DdrPhyKind _ddrPhyKind(HarborDeviceTarget? target) => switch (target) {
  HarborFpgaTarget(vendor: HarborFpgaVendor.vivado) => _DdrPhyKind.xilinx,
  HarborFpgaTarget(vendor: HarborFpgaVendor.openXc7) => _DdrPhyKind.xilinx,
  _ => _DdrPhyKind.ecp5,
};

/// SDRAM memory controller: a bus slave face over a PHY-agnostic
/// [DdrSequencer] and a target-specific PHY.
///
/// DDR3/DDR3L uses [DdrPhyEcp5] (ODDRX1F/IDDRX1F gearing, DLL-off,
/// hardware-verified on the OrangeCrab) on Lattice targets, and [DdrPhyXilinx]
/// (ODDR/IDDR/IDELAYE2, structurally equivalent but not yet board-calibrated)
/// on Xilinx 7-series targets. Both reuse the PHY-agnostic [DdrSequencer].
/// Other memory types are unimplemented shells until their PHYs exist.
class HarborDdrController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborSystemMemoryProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;

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

  /// Opt-in CPU-driven READ TRAINING. When set, a small MMIO control-register
  /// window is decoded just ABOVE the array (offsets in `[size, size+
  /// [trainCtrlSize])`), driving an [Ecp5DelayController] (read-tap walk) and a
  /// runtime read-window slack into the PHY's DYNAMIC delay path (DELAYF), and
  /// makes READCLKSEL + the DQSBUFM read-pointer runtime-trainable. When clear
  /// (the default) NONE of the training control plane is built and the read
  /// capture uses the static DELAYG + fixed-slack path. NOTE: the x2 MODDRX
  /// write/read datapath, the DQS-strobed capture, and the sclk fabric are the
  /// same in both modes (this is not the old x1 ODDRX1F path), the analog
  /// tap/eye and DQS-gate correctness can only be proven on the OrangeCrab, so
  /// the whole PHY needs hardware re-characterization. See project_ddr_training
  /// / project_ddr3_orangecrab.
  final bool trainableRead;

  /// Opt-in JEDEC DDR3 write-leveling (see [DdrSequencer.writeLevel]). DDR3
  /// requires it for writes to land: the fly-by routing skews CK vs DQS per
  /// byte lane, so the controller trains each lane's write DQS output delay to
  /// align DQS to CK at the DRAM, using the DRAM's WL feedback (MR1 A7=1). When
  /// set on an ECP5 DDR3 build, the sequencer runs the WL phase after MR init /
  /// before normal operation, stepping the DQSBUFM write pointer per lane and
  /// applying the trained delay to the normal write path. Off (the default)
  /// builds none of it, so non-DDR3 / read-only bring-up paths are unaffected.
  /// The MPR read path (the proven baseline) runs BEFORE normal ops and is not
  /// disturbed. Ignored on non-ECP5 / non-DDR targets.
  final bool writeLevel;

  /// When set, the bus-face transaction FSM verifies every array WRITE by
  /// reading the just-written word back and comparing it (masked by the write
  /// byte-enable) against the launched data, re-issuing the write until it
  /// matches or [writeVerifyTries] retries are exhausted. This makes CPU writes
  /// to DRAM hardware-guaranteed-correct on a PHY with a marginal (but
  /// read-back-recoverable) write eye: the openXC7 Arty x8 path, where the
  /// write DQ-vs-DQS phase cannot be centred (no output ODELAY, MMCM 90-degree
  /// phase inert) but reads are clean and a re-driven word always lands. Costs
  /// ~3x write latency (write + verify read + occasional retry). Reads are
  /// unaffected (they ack on the first busDone as before). Off = the original
  /// single-shot write path, byte-identical.
  final bool writeVerify;

  /// Bounded retry budget for [writeVerify] (writes past this ack best-effort so
  /// a pathologically stuck word can never hang the bus). 15 is ample: the write
  /// slip is occasional and a retry re-drives the same word on DQ, so the second
  /// attempt lands it with overwhelming probability.
  final int writeVerifyTries;

  /// When set, expose the ECP5 DQSBUFM DYNDELAY dynamic DQS-delay as a
  /// firmware-swept MMIO register (reg8), PER BYTE LANE (bits [8*l +: 8] for
  /// lane l, so [8*laneCount-1:0] total). DYNDELAY is a per-byte-lane 8-bit
  /// delay of the whole DQS strobe (NOT per-DQ-bit, see [Ecp5Dqsbufm.dyndelay]).
  /// Because it shifts the DQS strobe that BOTH the read capture (DQSR90) and the
  /// write launch derive from, sweeping it CENTERS THE READ EYE per DQS group
  /// (the DQS_LI static-delay path) as well as trimming the below-strobe-pad
  /// write skew. ECP5-only, ignored otherwise.
  final bool writeTrimTrainable;

  /// Build target. Selects the PHY: a Xilinx 7-series target (Spartan 7) uses
  /// [DdrPhyXilinx], null or a Lattice target uses the proven [DdrPhyEcp5].
  final HarborDeviceTarget? target;

  /// Static ECP5 DELAYG read tap (DEL_VALUE) for the DLL-off read path. Swept at
  /// build time to centre the read eye when trainableRead is off (no runtime
  /// training controller). Default 40.
  final int readTaps;

  /// Static read-capture window slack (cycles) for the ECP5 PHY. Board/build
  /// read-training knob, default 2. Sweep with [readTaps] to land the burst.
  /// Default 2 (not 1): the faithful DQS-read cosim showed readSlack=1 opens
  /// the capture window one SCLK too early, so the burst's first word reads
  /// stale (MPR word0 = 0x0, the on-bench "mprDebug word0 low read stale"
  /// signature), readSlack=2 lands the window on the burst.
  final int readSlack;

  /// DQSBUFM.READCLKSEL[2:0] read-gate select for the ECP5 DQS read path. The
  /// sub-beat read-gate knob (readTaps is < half-beat, readSlack is a full
  /// cycle), swept at build time alongside them to land the DQS read window.
  /// Default 0x4.
  final int readClkSel;

  /// ECP5 read cross-cycle pairing (preamble/turnaround first-beat fix).
  final bool readCrossPair;

  /// ECP5 x1 (DLL-off) read deserialize-assembly select (see
  /// [DdrPhyEcp5.readPairMode]): 0 same-cycle {q1,q0}, 1 {q0,q1prev},
  /// 2 q1-only {q1,q1prev}. The bench knob for the dead-q0 turnaround, only
  /// affects the x1 DLL-off read. Default 0 (HEAD same-cycle).
  final int readPairMode;

  /// Sample read DQ on clk (0deg, half-beat shift) instead of clk90.
  final bool readOnClk;

  /// DRAM read-retry / read-voting depth. 0 disables it. When > 0, a
  /// [HarborWishboneReadRetry] is inserted in front of the DRAM path so each
  /// DRAM read is re-issued until two consecutive reads agree (capped at this
  /// many issues). Fixes the DLL-off static-read metastability residual (a word
  /// occasionally reads wrong but re-reads correct) that build-time tap/pairing
  /// tuning cannot fully remove and the robust DQS read cannot fit alongside the
  /// L1 icache on a 25F. ~2x read latency. Default 0 (off).
  final int readRetryTries;

  /// When set, the DRAM datapath (sequencer + PHY) runs on a separate `ddr_clk`
  /// input while the bus face stays on `clk`, bridged by a
  /// [HarborWishboneCdcBridge]. [clockHz] must then be the `ddr_clk` rate (the
  /// timing counters derive from it). May be combined with [trainableRead]: the
  /// training config crosses bus-clk -> sclk through 2-flop synchronizers and
  /// the steppers run in the sclk domain (see `_buildDdr3` PART A/PART B).
  final bool asyncClock;

  /// Opt-in real-speed DDR3-667 read datapath on the Xilinx PHY (the UberDDR3 /
  /// LiteDRAM ISERDESE2 gearbox). When set (Xilinx/openXC7 target only), the PHY
  /// captures each DQ bit through IDELAYE2(VAR_LOAD) -> ISERDESE2(DATA_WIDTH=8)
  /// clocked by a DDR3 clock tree (ck333 CLK, ctrl83 CLKDIV, 200 MHz IDELAYCTRL
  /// ref, ck333@90 write), delivering the whole BL8 per controller cycle. The
  /// caller must feed the tree's clocks in via [ck_fast]/[ck90_fast]/[idelay_ref]
  /// ports (see genip), [clockHz] is then the ctrl83 controller rate (~83 MHz).
  /// Off (the default) keeps the proven 48 MHz DLL-off IDDR read path unchanged.
  final bool ddr3Fast;

  /// The ck333 DDR-CK frequency (MHz) the ddr3Fast tree runs at, feeds the PHY's
  /// MR DLL-on selection and IDELAYE2 REFCLK. Only used when [ddr3Fast].
  final double ddr3FastCkMhz;

  /// The ddr3Fast IDELAYCTRL reference (MHz), must equal the tree's idelayref.
  final double ddr3FastIdelayRefMhz;

  /// DDR3-667 JEDEC CAS latency / CAS write latency in CK cycles for the
  /// ddr3Fast path (the >=3000 ps tCK speed bin uses CL=5, CWL=5). Only consumed
  /// when [ddr3Fast], the 48 MHz/144 MHz/ECP5 paths keep the fixed 6/6. Sets the
  /// sequencer MR0/MR2 CL/CWL fields and the PHY read-window / write-launch
  /// offsets.
  final int ddr3FastCl;
  final int ddr3FastCwl;

  /// ddr3Fast write/command timing knobs, forwarded to [DdrPhyXilinx]. Threaded
  /// from the region params / board defaults (previously the HARBOR_DDR_CMDSLOT/
  /// WRSHIFT/WRBEAT env reads). [cmdSlot] picks the command CK edge (0..3),
  /// [writeShift] slides the whole write-launch window, [wrBeatOffset] is the
  /// sub-tick DDR beat rotation (null derives it from CWL). ddr3Fast-only.
  final int cmdSlot;
  final int writeShift;
  final int? wrBeatOffset;

  /// ddr3Fast runtime read-window tap reset value (reg12): the compile-time
  /// window select the firmware starts from before it walks the coarse ctrl83
  /// capture cycle. Previously the HARBOR_DDR_WINDOW env read, default 5.
  final int windowTapReset;

  /// Size (bytes) of the training control-register window above the array.
  static const int trainCtrlSize = 0x1000;

  /// Bus slave port (CPU-side).
  late final BusSlavePort bus;

  HarborDdrController({
    required this.config,
    required this.baseAddress,
    this.clockHz = 48000000,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    this.mprDebug = false,
    this.trainableRead = false,
    this.writeLevel = false,
    this.writeVerify = false,
    this.writeVerifyTries = 15,
    this.writeTrimTrainable = false,
    this.readTaps = 40,
    this.readSlack = 2,
    this.readClkSel = 0x4,
    this.readCrossPair = false,
    this.readPairMode = 0,
    this.readOnClk = false,
    this.readRetryTries = 0,
    this.target,
    this.asyncClock = false,
    this.ddr3Fast = false,
    this.ddr3FastCkMhz = 333.333,
    this.ddr3FastIdelayRefMhz = 200.0,
    this.ddr3FastCl = 5,
    this.ddr3FastCwl = 5,
    this.cmdSlot = 0,
    this.writeShift = 0,
    this.wrBeatOffset,
    this.windowTapReset = 5,
    String? name,
  }) : super('HarborDdrController', name: name ?? 'ddr') {
    // The array size must be a power of two: the address mask
    // (`reqAddr & (size - 1)`) and the single-bit control-window decode
    // (`busOff[log2(size)]`) both assume it. A non-power-of-two size would
    // alias the control window into the array and mis-mask the row address.
    if (config.size <= 0 || (config.size & (config.size - 1)) != 0) {
      throw ArgumentError(
        'HarborDdrConfig.size must be a power of two, got ${config.size}',
      );
    }
    // readSlack must fit the PHY's read pipeline / runtime-slack mux range
    // (0..7, the PHY's maxRdSlack), and readClkSel must fit READCLKSEL[2:0].
    if (readSlack < 0 || readSlack > 7) {
      throw ArgumentError('readSlack must be 0..7, got $readSlack');
    }
    if (readClkSel < 0 || readClkSel > 7) {
      throw ArgumentError(
        'readClkSel must fit READCLKSEL[2:0] (0..7), got $readClkSel',
      );
    }
    if (ddr3Fast) {
      if (_ddrPhyKind(target) != _DdrPhyKind.xilinx) {
        throw ArgumentError(
          'ddr3Fast is a Xilinx-PHY (ISERDESE2) feature; needs a Xilinx/openXC7 '
          'target, got $target.',
        );
      }
      if (!asyncClock) {
        throw ArgumentError(
          'ddr3Fast runs the sequencer/PHY on ddr_clk (ctrl83); set '
          'asyncClock: true.',
        );
      }
    }
    // trainableRead is supported on both PHYs: the ECP5 path walks the DQSBUFM
    // read pointer + DELAYF taps, the Xilinx path walks per-lane IDELAYE2
    // VARIABLE taps + a fabric BITSLIP (both decoded from the same train-control
    // MMIO window, on non-overlapping register numbers).
    // asyncClock + trainableRead now coexist: the training control window
    // decodes on the bus clock, and the steppers + PHY runtime controls are
    // built in the sclk datapath domain with the config 2-flop synchronized
    // across (see _buildDdr3 PART A/PART B). creek needs both (async DDR clock
    // plus runtime read leveling), so the old mutual exclusion is gone.
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // Optional second clock domain for the DRAM datapath. When [asyncClock] is
    // set, the bus face stays on `clk` (the slow core/fabric clock) while the
    // sequencer + PHY run on this `ddr_clk` (the part's qualified rate), bridged
    // by a [HarborWishboneCdcBridge]. Lets a slow core drive DRAM that must clock
    // fast (e.g. creek at 12 MHz with DDR3 at 48 MHz on a 25F).
    if (asyncClock) {
      createPort('ddr_clk', PortDirection.input);
      createPort('ddr_reset', PortDirection.input);
    }
    // ddr3Fast clock-tree inputs: the shared MMCM DDR3 tree (built in genip)
    // feeds ck333 (DDR CK / ISERDESE2 CLK), ck333@90 (write launch) and the
    // ~200 MHz IDELAYCTRL reference. The controller/CLKDIV clock is `ddr_clk`
    // (= ctrl83 = CK/4), so ddr3Fast implies asyncClock.
    if (ddr3Fast) {
      createPort('ddr_ck_fast', PortDirection.input);
      createPort('ddr_ck90_fast', PortDirection.input);
      // Dedicated DQS launch clock (180-deg CK from the tree's CLKOUT4). The
      // DQS OSERDES rides this so the DQS edge is centered in the DQ eye and
      // edge-framed to CK (tDQSS): the never-varied sub-CK DQS-vs-CK phase.
      createPort('ddr_ck_dqs_fast', PortDirection.input);
      createPort('ddr_idelay_ref', PortDirection.input);
    }

    // System-side bus interface. The port carries the SoC bus width when
    // given (the fabric connects same-width interfaces), the address is
    // masked down to the memory's span internally.
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth ?? config.size.bitLength,
      dataWidth:
          busDataWidth ??
          (config.isSdr ? config.dataWidth : config.dataWidth * 2),
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

    // DDR-specific signals (not present on SDR). CK# is an explicit
    // pseudo-differential complement: the part's clock receiver is differential
    // and the FPGA flow does not build the complement side of "D"-suffixed SSTL
    // output types. DQS pad style on the ECP5 PHY is build-time gated on dllOn
    // (= CK > ~60 MHz): DLL-ON it is a TRUE DIFFERENTIAL pad (LDQS _p ball,
    // SSTL135D_I) so nextpnr generates the LDQSN complement and there is NO
    // sdram_dqs_n port. DLL-OFF (the hardware-proven x1 strobe) it is an EXPLICIT
    // pseudo-differential pair, so sdram_dqs_n IS created and the PHY drives it
    // with a complement ODDR (like CK#). The non-ECP5 (Xilinx) PHY always drives
    // an explicit sdram_dqs_n complement.
    if (config.isDdr) {
      final ecp5Phy = _ddrPhyKind(target) == _DdrPhyKind.ecp5;
      final ddrDllOn = (clockHz / 1000000).round() > 60;
      createPort('sdram_ck_n', PortDirection.output);
      createPort(
        'sdram_dqs',
        PortDirection.inOut,
        width: config.dataWidth ~/ 8,
      );
      if (!ecp5Phy || !ddrDllOn) {
        createPort(
          'sdram_dqs_n',
          PortDirection.inOut,
          width: config.dataWidth ~/ 8,
        );
      }
      createPort('sdram_odt', PortDirection.output);
      createPort('sdram_reset_n', PortDirection.output);
    }

    if (config.type == HarborDdrType.ddr3 ||
        config.type == HarborDdrType.ddr3l) {
      _buildDdr3();
    }
    // Other memory types remain unimplemented shells for now.
  }

  /// Wires the DDR3 datapath: bus face -> [DdrSequencer] <-> a target-specific
  /// [DdrPhy] -> pads. Single outstanding transaction, the ack carries read
  /// data latched from the PHY's capture window.
  void _buildDdr3() {
    final clk = input('clk');
    final reset = input('reset');
    final clkMhz = (clockHz / 1000000).round().clamp(1, 400);

    // Datapath clock: the bus FACE runs on `clk`, but when [asyncClock] is set
    // the sequencer + PHY (and the request-side bus-face registers) run on the
    // faster `ddr_clk`, bridged from `clk` by a [HarborWishboneCdcBridge]. The
    // [dv*] signals are the datapath's view of the bus: in [asyncClock] they are
    // the bridge's MASTER side (ddr_clk domain), otherwise they pass straight
    // through to the external [bus] (clk domain). So the bus-face logic below is
    // written once against [dv*] and is identical in both modes.
    final dpClk = asyncClock ? input('ddr_clk') : clk;
    final dpReset = asyncClock ? input('ddr_reset') : reset;

    // Narrow (32-bit) bus face. The DDR datapath is natively 32-bit (one 32-bit
    // word per BL8-selected burst access). On a wider core bus a 2:1 downsizer
    // splits each access into two sequential 32-bit ones (low word at adr, high
    // at adr+4) so the proven 32-bit datapath serves a 64-bit bus. Every RV64
    // instruction fetch is a 64-bit read, which would otherwise lose its upper
    // half. On a 32-bit bus the narrow face IS the external bus directly.
    final wide = bus.dataIn.width > 32;
    final nbStb = Logic(name: 'nb_stb');
    final nbWe = Logic(name: 'nb_we');
    final nbAddr = Logic(name: 'nb_addr', width: bus.addr.width);
    final nbDataIn = Logic(name: 'nb_data_in', width: 32);
    final nbSel = Logic(name: 'nb_sel', width: 4);
    final nbAck = Logic(name: 'nb_ack');
    final nbDataOut = Logic(name: 'nb_data_out', width: 32);

    if (wide) {
      // The train-control window is served DIRECTLY on the wide bus as a single
      // transaction, NOT through the 2:1 downsizer. The control registers are
      // 32-bit, pushing a register access through the downsizer made it a two-
      // beat read whose per-beat acks only completed in single-clock sim but
      // HUNG on the dual-clock (CLKOS bus / CLKOP ddr) OrangeCrab silicon (the
      // ddreye STATUS read never acked). Routing control past the downsizer is
      // both simpler and removes that dual-clock failure mode. Only DRAM
      // (~isCtrlWide) goes through the downsizer.
      // Control window = base-relative offset AT/ABOVE the array span, decoded as
      // a FULL-WIDTH >= compare (NOT a lone bit-[sizeLog2] select). openXC7/yosys
      // DCE'd the single-bit select (tying is_ctrl_wide to 0, misrouting every
      // control read into the array), the >= comparator keeps the decode alive.
      final busOffWide = bus.addr.width > 32
          ? bus.addr.getRange(0, 32)
          : bus.addr.zeroExtend(32);
      final isCtrlWide = trainableRead
          ? busOffWide.gte(Const(config.size, width: 32)).named('is_ctrl_wide')
          : Const(0);

      final ds = HarborWishboneDownsizer(
        addressWidth: bus.addr.width,
        wideWidth: bus.dataIn.width,
        narrowWidth: 32,
        // Space consecutive DDR accesses ~like the spacing data reads get for
        // free between loop iterations: continuous back-to-back instruction
        // fetch corrupts, spaced access (data loads, ddrtest) reads clean. Small
        // value to stay under any bus/fabric latency budget (pace=32 hung).
        // 16: a 64-bit ld/sd (two back-to-back beats) was marginal at pace 8: the
        // read-word CDC payload had not settled between beats, more spacing per beat
        // widens the analog/MTBF margin without approaching the pace=32 hang.
        paceCycles: 16,
        name: 'ddr_downsizer',
      );
      ds.input('clk').srcConnection! <= clk;
      ds.input('reset').srcConnection! <= reset;
      ds.input('m_ack').srcConnection! <= nbAck;
      ds.input('m_dat_r').srcConnection! <= nbDataOut;
      // DRAM ack/read-data source: either the downsizer directly, or, when
      // [readRetryTries] > 0, a read-retry filter in FRONT of the downsizer
      // that re-issues each DRAM read until two consecutive reads agree (the
      // DLL-off static-read metastability fix). Control accesses never go
      // through either (served on the narrow plane).
      final Logic dramAck;
      final Logic dramDatR;
      if (readRetryTries > 0) {
        final rr = HarborWishboneReadRetry(
          addressWidth: bus.addr.width,
          dataWidth: bus.dataIn.width,
          maxTries: readRetryTries,
          name: 'ddr_read_retry',
        );
        rr.input('clk').srcConnection! <= clk;
        rr.input('reset').srcConnection! <= reset;
        rr.input('s_cyc').srcConnection! <= bus.stb & ~isCtrlWide;
        rr.input('s_stb').srcConnection! <= Const(1);
        rr.input('s_we').srcConnection! <= bus.we;
        rr.input('s_adr').srcConnection! <= bus.addr;
        rr.input('s_dat_w').srcConnection! <= bus.dataIn;
        rr.input('s_sel').srcConnection! <= bus.sel;
        // The downsizer is driven by the retry filter's master face.
        ds.input('s_cyc').srcConnection! <=
            rr.output('m_cyc') & rr.output('m_stb');
        ds.input('s_stb').srcConnection! <= Const(1);
        ds.input('s_we').srcConnection! <= rr.output('m_we');
        ds.input('s_adr').srcConnection! <= rr.output('m_adr');
        ds.input('s_dat_w').srcConnection! <= rr.output('m_dat_w');
        ds.input('s_sel').srcConnection! <= rr.output('m_sel');
        rr.input('m_ack').srcConnection! <= ds.output('s_ack');
        rr.input('m_dat_r').srcConnection! <= ds.output('s_dat_r');
        dramAck = rr.output('s_ack');
        dramDatR = rr.output('s_dat_r');
      } else {
        // DRAM only: hold the downsizer idle on a control access.
        ds.input('s_cyc').srcConnection! <= bus.stb & ~isCtrlWide;
        ds.input('s_stb').srcConnection! <= Const(1);
        ds.input('s_we').srcConnection! <= bus.we;
        ds.input('s_adr').srcConnection! <= bus.addr;
        ds.input('s_dat_w').srcConnection! <= bus.dataIn;
        ds.input('s_sel').srcConnection! <= bus.sel;
        dramAck = ds.output('s_ack');
        dramDatR = ds.output('s_dat_r');
      }
      // Control: ack/data straight from the narrow control plane (nbAck =
      // ctrlAck for isCtrl, nbDataOut = the 32-bit register word replicated
      // across the wide word). DRAM: the (optionally retried) result.
      final ctrlDataWide = List.filled(
        bus.dataOut.width ~/ 32,
        nbDataOut,
      ).swizzle();
      bus.ack <= mux(isCtrlWide, nbAck, dramAck);
      bus.dataOut <= mux(isCtrlWide, ctrlDataWide, dramDatR);
      // Narrow request face: the wide bus directly for control, the downsizer's
      // split beats for DRAM.
      nbStb <=
          mux(isCtrlWide, bus.stb, ds.output('m_cyc') & ds.output('m_stb'));
      nbWe <= mux(isCtrlWide, bus.we, ds.output('m_we'));
      nbAddr <= mux(isCtrlWide, bus.addr, ds.output('m_adr'));
      nbDataIn <=
          mux(isCtrlWide, bus.dataIn.getRange(0, 32), ds.output('m_dat_w'));
      nbSel <= mux(isCtrlWide, bus.sel.getRange(0, 4), ds.output('m_sel'));
    } else {
      nbStb <= bus.stb;
      nbWe <= bus.we;
      nbAddr <= bus.addr;
      nbDataIn <= bus.dataIn;
      nbSel <= bus.sel;
      bus.ack <= nbAck;
      bus.dataOut <= nbDataOut;
    }

    // The ECP5 PHY now owns the Lattice edge-clock tree: it derives eclk (CK
    // rate) and sclk (= eclk/2) from the incoming [dpClk] (the CK-rate source -
    // creek option A's 48 MHz ddr_clk) and EXPORTS sclk. The sequencer, the
    // request-side bus-face registers, and the CDC bridge MASTER all run on that
    // exported sclk (the half-rate fabric clock), not on [dpClk] directly. So we
    // must build the PHY before the CDC bridge and the bus-face logic.
    //
    // The command/data channel the PHY consumes comes FROM the sequencer, which
    // we cannot build until sclk exists: a cycle. We break it by creating the
    // channel as plain Logics now, building the PHY against them, then driving
    // them from the sequencer once it is built on sclk.
    // The Xilinx PHY exposes directional dq_out/dq_oe + a dq_in input: the
    // CONTROLLER owns the tristate pad and feeds the captured pad value back in
    // through this Logic (driven from the inout pad below). The ECP5 PHY instead
    // OWNS the DQ/DQS/DQS# tristate buffers (so each write-OE TSH `Q` reaches a
    // pad tristate `T` directly: the nextpnr packing rule), so it takes the
    // inout pad nets and this dq_in feedback Logic is unused on that path.
    final isEcp5Phy = _ddrPhyKind(target) == _DdrPhyKind.ecp5;
    final dqIn = Logic(name: 'ddr_dq_in', width: config.dataWidth);
    // In ddr3Fast the Xilinx PHY owns the DQ pad and reads from its own IOBUF, so
    // the dq_in PORT is unused, tie it to 0 so the (still-present) input port is
    // driven rather than floating.
    if (ddr3Fast) dqIn <= Const(0, width: config.dataWidth);
    // Received DQS strobe per byte lane (Milestone 2 DQS read). Created early
    // (the PHY is built before the pads) and driven from the dqs inout pad
    // below, mirroring dqIn. Unused on the ECP5 (PHY-owns-pad) path.
    final dqsIn = Logic(name: 'ddr_dqs_in', width: config.dataWidth ~/ 8);
    final chCke = Logic(name: 'ch_cke');
    final chCsN = Logic(name: 'ch_cs_n');
    final chCmd = Logic(name: 'ch_cmd', width: 3);
    final chBa = Logic(name: 'ch_ba', width: (config.banks - 1).bitLength);
    final chAddr = Logic(name: 'ch_addr', width: config.rowWidth);
    final chOdt = Logic(name: 'ch_odt');
    final chResetN = Logic(name: 'ch_reset_n');
    final chWrStart = Logic(name: 'ch_wr_start');
    final chWrData = Logic(name: 'ch_wr_data', width: 32);
    final chWrMask = Logic(name: 'ch_wr_mask', width: 4);
    final chBeatSel = Logic(name: 'ch_beat_sel', width: 2);
    final chRdStart = Logic(name: 'ch_rd_start');

    // Write-leveling channel (sequencer WL FSM <-> PHY). Forward-declared so the
    // PHY can be built against them, driven from the sequencer below. Only used
    // when [writeLevel] is set (the creek DDR3 build), tied off otherwise. Both
    // the ECP5 PHY (DQSBUFM write pointer) and the Xilinx ddr3Fast PHY (per-lane
    // OSERDESE2 beat rotation) implement the WL actuator + feedback, so enable it
    // on either, the 48 MHz Xilinx IDDR path has no actuator so it is excluded.
    // The Xilinx ddr3Fast WL actuator+feedback is wired but its DRAM feedback
    // capture is still under debug (fb_map reads flat 0), so PARK it behind the
    // HARBOR_DDR_WL env (default off): the x8-on-lane0 bring-up runs on the proven
    // static lane-0 write timing with NO WL. Set HARBOR_DDR_WL=1 to re-enable the
    // WL debug. The ECP5 path keeps WL unconditionally (it works there).
    final xilWlEnable = Platform.environment['HARBOR_DDR_WL'] == '1';
    final useWriteLevel =
        writeLevel && (isEcp5Phy || (ddr3Fast && xilWlEnable)) && config.isDdr;
    final laneCount = config.dataWidth ~/ 8;
    final laneSelW = laneCount <= 1 ? 1 : (laneCount - 1).bitLength;
    final chWlEn = Logic(name: 'ch_wl_en');
    final chWlDelayRst = Logic(name: 'ch_wl_delay_rst');
    final chWlDelayInc = Logic(name: 'ch_wl_delay_inc');
    final chWlStrobe = Logic(name: 'ch_wl_strobe');
    final chWlLane = Logic(name: 'ch_wl_lane', width: laneSelW);
    final chWlTrained = Logic(name: 'ch_wl_trained', width: 4 * laneCount);
    final chWlDone = Logic(name: 'ch_wl_done');
    // WL feedback witness bitmap (per-tap voted feedback, last lane) -> reg6.
    final chWlFbMap = Logic(name: 'ch_wl_fb_map', width: 8);

    // Firmware write-DQS-delay channel (reg7 WRDLY <-> PHY). The firmware sweeps
    // the write pointer directly via reg7 and finds the write alignment by reading
    // back a written pattern, sidestepping the broken auto-WL DQ feedback. The
    // control window only exists on the trainable-read ECP5 DDR3 build, so the
    // WRDLY path rides that same gate. Driven from PART B (sclk-synced reg7).
    final useWrDly = trainableRead && isEcp5Phy && config.isDdr;
    // reg7 WRDLY field width: [4*laneCount-1:0] per-lane 4-bit write-pointer tap,
    // plus one WRDIRECTION bit at [4*laneCount]. = 4*laneCount + 1.
    final wrDlyW = 4 * laneCount + 1;
    final chWrDly = Logic(name: 'ch_wr_dly', width: wrDlyW);
    final chWrDlyApply = Logic(name: 'ch_wr_dly_apply');
    // reg8 DQS-DELAY TRIM: PER-LANE DQSBUFM DYNDELAY, packed [8*laneCount-1:0]
    // (lane l at bits [8*l +: 8]). DYNDELAY shifts the whole byte lane's DQS
    // strobe, so this is the fine per-DQS-group READ-EYE centering knob (the
    // DQS_LI static-delay path) as well as the write trim. Same trainable gate
    // as the WRDLY path. Quasi-static, rides the bus->sclk sync like the read
    // TAP / RDSLACK regs. For dataWidth=16 (creek) laneCount=2 -> 16 bits, fits
    // the 32-bit reg.
    final useWriteTrim = writeTrimTrainable && isEcp5Phy && config.isDdr;
    final wrTrimW = 8 * laneCount;
    // reg8 is a single 32-bit MMIO word: the per-lane DYNDELAY field must fit.
    // laneCount<=4 (32-bit DDR bus) fits exactly, a wider ECP5 bus would need a
    // second reg (or a narrower per-lane field).
    assert(
      wrTrimW <= 32,
      'reg8 per-lane DYNDELAY ($wrTrimW bits) overflows the 32-bit MMIO word',
    );
    final chWrTrim = Logic(name: 'ch_wr_trim', width: wrTrimW);
    // reg10 PER-BIT DQ DESKEW select: {broadcastBit(MSB), dqIndex}. Selects which
    // single DQ bit the shared DELAYF MOVE/LOADN steps (broadcast bit = all bits,
    // the reset default = the existing group walk). Quasi-static level, rides the
    // bus->sclk sync like the WRITE-TRIM. Only meaningful on the trainable ECP5
    // DDR3 build (per-bit deskew closes the residual 2nd-beat per-DQ scramble).
    final usePerBitDeskew = trainableRead && isEcp5Phy && config.isDdr;
    final dqDeskewSelW =
        config.dataWidth.bitLength + 1; // dqIndex + broadcast bit
    final chDqDeskewSel = Logic(name: 'ch_dq_deskew_sel', width: dqDeskewSelW);
    // WRITE-command diagnostic counter from the sequencer (sclk domain), routed
    // to the bus clock for the WRCTL register. Driven from seq.wrCmdCount after
    // the sequencer is built (forward-reference, same pattern as chWlTrained).
    final chWrCmdCount = Logic(name: 'ch_wr_cmd_count', width: 8);
    // Init/calibration completion witness + raw FSM state code from the
    // sequencer, sampled into STATUS. init_done is a level that asserts once and
    // holds, state_code changes slowly (per FSM transition). Both are safe to
    // sample without pulse-CDC (quasi-static), like chWrCmdCount above.
    final chInitDone = Logic(name: 'ch_init_done');
    final chStateCode = Logic(name: 'ch_state_code', width: 4);
    // DEBUG (write-data-path): the latched write word the PHY launches (rise
    // half). Bus-synced from phy.dbg_wrword after the PHY is built, read via
    // STATUS reg4 to see if the real bus write data reaches the PHY.
    final chWrWord = Logic(name: 'ch_wr_word', width: 16);
    // DEBUG (write launch): the post-gearbox launched line beats 0+1 (OSERDESE2
    // D inputs) from phy.dbg_dataline, read via STATUS reg5.
    final chDataLine = Logic(name: 'ch_data_line', width: 32);
    // DEBUG (DQS clock alive): heartbeat on writeCkDqs from phy.dbg_dqsclk, read
    // via STATUS reg6. Nonzero => DQS launch clock alive, 0 => dead.
    final chDqsClk = Logic(name: 'ch_dqs_clk', width: 8);
    // DEBUG (raw read capture): lane-0's 8 captured beats from phy.dbg_beats,
    // read via STATUS reg7. MPR read => 0xAA/0x55 if the DRAM drives the pattern.
    final chBeats = Logic(name: 'ch_beats', width: 8);
    // ddr3Fast DQ-drive-overlap witness (from the PHY, forward-referenced like
    // chWrCmdCount): counts write bursts where the pad OE overlapped the data
    // serialize. Only meaningful on ddr3Fast, 0 elsewhere.
    final chDriveOverlap = Logic(name: 'ch_drive_overlap', width: 8);

    // Opt-in read-training control block (gated, default builds nothing).
    //
    // CLOCKING / CDC (resolves the old asyncClock x trainableRead exclusion):
    // the MMIO register WRITES happen on the bus clock [clk], but the delay /
    // read-pointer steppers and the PHY runtime controls live in the DATAPATH
    // (sclk) domain. So this block is split in two:
    //   - PART A (here, on [clk]): decode the control window into quasi-static
    //     holding registers and TOGGLE strobes, and forward-declare the
    //     PHY-runtime Logics + the synchronized STATUS bits.
    //   - PART B (built after the PHY exists, on [seqClk] = sclk): 2-flop
    //     synchronize the quasi-static config into the datapath domain, build
    //     the [Ecp5DelayController] (DELAYF walk) and the read-pointer stepper
    //     ON sclk so every MOVE pulse is generated in the domain the primitive
    //     samples (no raw pulse-CDC), edge-detect the synchronized SET/LOAD
    //     toggles to trigger them, and drive the PHY runtime inputs. DATAVALID/
    //     BURSTDET are brought back sclk->clk through a 2-flop synchronizer for
    //     the STATUS register.
    // On the SINGLE-CLOCK path seqClk == clk, so the synchronizers degenerate
    // to plain flops and the behavior matches the original bus-clk controller.
    // Widened 4 -> 7 to match the PHY: the runtime RDSLACK knob now also moves
    // the fabric read-CAPTURE anchor cycle (rdPipe[clSys + rdSlackRt]), so the
    // ddrlevel TAP x RCS x RDSLACK sweep must span enough cycles to hit the real
    // read cycle. slackW = (7+1).bitLength = 4 (was 3), so the RDSLACK CSR field
    // and the PHY rd_slack input are 4 bits, firmware writes 0..7.
    const maxRdSlack = 7;
    final slackW = (maxRdSlack + 1).bitLength;
    // reg11 RDPULSE: independent READ0/READ1 read-pulse position. Positions 0..15
    // are REAL taps. The field is 5 BITS ((maxRdPulse+1).bitLength = 16.bitLength =
    // 5), and the ALL-ONES value (31 = 0x1F) is the "use legacy gate" sentinel /
    // reset default, so firmware writes 0..15 for a real position and 31 (NOT 15)
    // to fall back to the legacy CL/RDSLACK-derived gate. The PHY's maxRdPulse must
    // match this so rdPipe is long enough (max(clSys+maxRdSlack, maxRdPulse+1)).
    const maxRdPulse = 15;
    final pulseW = (maxRdPulse + 1).bitLength; // 5 (0..15 real, 31 = sentinel)
    // The sentinel = 5-bit all-ones (31) = "legacy gate", the reset default so a
    // boot that never writes reg11 keeps the original behavior.
    final pulseSentinel = (1 << pulseW) - 1;
    // Forward-declared PHY-runtime controls (driven in PART B). These are the
    // plain Logics the PHY is constructed against, mirroring the command
    // channel break above.
    Logic? trainLoadn, trainMove, trainDir, trainSlackRt, trainReadClkSel;
    Logic? trainRdpLoadn, trainRdpMove, trainRdpDir;
    // Firmware BURSTDET-seen CLEAR: sclk-domain one-cycle pulse feeding the PHY so
    // firmware can re-arm the sticky BURSTDET/DATAVALID-seen latches per read-level
    // step (reg1 CTL bit2). Lets the FSBL use BURSTDET as a per-step oracle to PIN
    // the DQSBUFM read pointer to a deterministic phase each boot.
    Logic? trainBdetClear;
    // reg11 RDPULSE: the independent READ0/READ1 read-pulse position (0..15,
    // all-ones = legacy gate). Runtime (sclk) net the PHY is built against.
    Logic? trainRdPulsePos;
    // Quasi-static config (clk domain) + the toggles, shared into PART B.
    Logic? rdtapTarget, rdSlackReg, readClkSelReg;
    // reg11 RDPULSE quasi-static holding register (clk domain, synced in PART B).
    Logic? rdPulsePosReg;
    Logic? rdpLoadnReg, rdpDirReg;
    Logic? setToggle, loadToggle, rdpMoveToggle;
    // Firmware BURSTDET-seen CLEAR toggle (reg1 CTL bit2): one edge per write, PART
    // B edge-detects it into a one-sclk clear pulse to the PHY sticky latches.
    Logic? bdetClearToggle;
    // Firmware WRDLY (reg7): the quasi-static per-lane tap and the apply toggle.
    Logic? wrDlyReg, wrDlyApplyToggle;
    // Firmware WRITE-TRIM (reg8): the quasi-static lane-0 DYNDELAY value.
    Logic? wrTrimReg;
    // reg10 PER-BIT DQ DESKEW select: {broadcastBit(MSB), dqIndex}. Quasi-static.
    Logic? dqDeskewSelReg;
    // Bus-domain "walk launching" latch. The delay walk starts a few cycles
    // after the SET/LOAD write (the toggle has to cross into sclk before the
    // controller asserts busy, then busy has to cross back). Without this,
    // firmware that writes SET then immediately polls STATUS.busy could read
    // the not-yet-started 0 and think the walk finished. The latch holds busy
    // from the write until the synchronized [busySync] is actually observed.
    Logic? trainBusyPending;
    // Synchronized status (driven in PART B), read back here in clk domain.
    final dataValidSync = Logic(name: 'train_datavalid_sync');
    final burstDetSync = Logic(name: 'train_burstdet_sync');
    // DQS-read observability, synced sclk -> bus clk in PART B. These all come
    // from SV-leaf DQSBUFM / DLL outputs (X in sim, real on hardware), so they
    // are spliced into the STATUS word OUTSIDE the read mux like the existing
    // DATAVALID/BURSTDET bits.
    final dllLockSync = Logic(name: 'train_dlllock_sync');
    final burstDetSeenSync = Logic(name: 'train_burstdet_seen_sync');
    final dataValidSeenSync = Logic(name: 'train_datavalid_seen_sync');
    // Current-tap / busy from the sclk-domain delay controller, synchronized
    // back for STATUS (driven in PART B).
    final curTapSync = Logic(name: 'train_curtap_sync', width: 7);
    final busySync = Logic(name: 'train_busy_sync');
    // Write-leveling result observability, synced sclk -> bus clk in PART B.
    // These are ORDINARY FABRIC REGS from the sequencer WL FSM (defined in sim
    // and on hardware), NOT X-prone DQS leaves, so they read back through the
    // normal STATUS mux (reg6), never the DQS concat splice. wlTrainedSync packs
    // 4 bits per byte lane (lane0 in [3:0], lane1 in [7:4]), wlDoneSync is the
    // WL-phase-complete latch. Quasi-static (latched once WL finishes), so a
    // 2-flop sync is sufficient.
    final wlTrainedSync = Logic(
      name: 'train_wl_trained_sync',
      width: 4 * laneCount,
    );
    final wlDoneSync = Logic(name: 'train_wl_done_sync');
    // WL feedback witness bitmap synced to the bus clock (reg6 upper bits).
    final wlFbMapSync = Logic(name: 'train_wl_fb_map_sync', width: 8);
    // On-chip write-control diagnostics (scope substitutes), synced sclk -> bus
    // clk in PART B. The OE/DM/DAT counters come from the PHY (oeWindow, the DM
    // mask, the wrData2 launch window) and CMD from the sequencer's WRITE-command
    // counter. All are DEFINED 8-bit fabric counters (sim-visible, not X-prone
    // DQS leaves), so they read back through the normal control mux as reg5
    // (WRCTL). They are quasi-static between firmware polls, so a plain 2-flop
    // sync is sufficient. Packed into one 32-bit word:
    //   reg5[7:0]   OE  count (oeWindow asserts)
    //   reg5[15:8]  CMD count (WRITE commands issued)
    //   reg5[23:16] DM  count (data-mask-low / unmasked writes)
    //   reg5[31:24] DAT count (wrData2 launch window asserts)
    final wrOeSync = Logic(name: 'train_wr_oe_sync', width: 8);
    final wrCmdSync = Logic(name: 'train_wr_cmd_sync', width: 8);
    final wrDmSync = Logic(name: 'train_wr_dm_sync', width: 8);
    final wrDatSync = Logic(name: 'train_wr_dat_sync', width: 8);
    // On-chip write-eye capture (reg9): lane-0's 4 driven sub-beats, synced to bus.
    final wrCapSync = Logic(name: 'train_wr_cap_sync', width: 32);
    // The control window is decoded and served ENTIRELY on the bus clock, on
    // the NARROW (post-downsizer) bus face [nb*], BEFORE the CDC bridge. This is
    // the critical CDC fix: the previous version decoded `isCtrl`/`regSel` from
    // the bus-clk `bus.addr` but consumed them in the sclk datapath sequential
    // and on the bridge `m_dat_r`, an unsynchronized clk -> sclk crossing whose
    // select bit could metastate and which referred to a different transaction
    // than the bridge was serving. Now a control access never enters the bridge
    // at all: the datapath stb is gated (nbStb & ~isCtrl), and the control ack +
    // read data are produced here on [clk]. Only the quasi-static trained CONFIG
    // crosses into sclk (PART B syncToSclk), and only the synchronized STATUS
    // crosses back (PART B syncToBus). Decoding on the narrow face also fixes
    // the 64-bit downsizer split: each 8-byte register is touched as two 32-bit
    // narrow accesses, and the [ctrlAligned] gate makes the toggle/edge logic
    // act on the low (offset bit[2]==0) half only so a wide write cannot double
    // toggle (firmware accesses the control window 32 bits at a time).
    Logic isCtrl = Const(0);
    Logic ctrlAck = Const(0);
    // Defined control-plane read word (no DQS X bits). The DQS status flags are
    // spliced onto bits [9:8] of the FINAL nbDataOut, never inside a mux (ROHD
    // mux amplifies any x to all-x).
    Logic ctrlReadCtl = Const(0, width: 32);
    // [12:8] payload (x in sim): DATAVALID[8], BURSTDET[9], DLL_LOCK[10],
    // BDET_SEEN[11], DVALID_SEEN[12]. (RDPNTR/WRPNTR not fabric-routable on the
    // ECP5, a DQS-toggle bit is impossible too: DQSI is top-level-input-only.)
    Logic ctrlDqsBits = Const(0, width: 5);
    Logic ctrlIsStatus = Const(0); // gates the DQS splice
    // Xilinx read-training controls (Task 5/6): driven by the XilinxReadTrainRegs
    // decode below on the Xilinx trainable path, null otherwise. Fed into the
    // DdrPhyXilinx VARIABLE-IDELAY + fabric-BITSLIP read engine.
    Logic? xilIdelayLd;
    Logic? xilIdelayCntValue;
    Logic? xilIdelayLane;
    Logic? xilBitslip;
    Logic? xilBitslipLane;
    // Runtime read-window tap (ddr3Fast only): selects which ISERDESE2 read-pipe
    // ctrl83 stage the BL8-line capture opens on, so firmware sweeps the coarse
    // "which controller cycle" knob without a rebuild (reg12 @ +0x60).
    Logic? xilWindowTap;
    // Firmware-programmable refresh level (reg13 @ +0x68), bus domain, synced to
    // the sequencer's tempLevel below to scale dynamic tREFI (0=1x/1=2x/2=4x). The
    // openXC7 toolchain has no XADC Bel, so temperature adaptation is done in
    // firmware (FSBL sets 4x, Linux can retune) rather than an on-die sensor.
    Logic? xilRefreshLevel;
    // seqClk-domain refresh level fed to the sequencer (assigned in the sync block).
    Logic? seqTempLevel;
    // IDELAYCTRL RDY read back from the PHY into STATUS (reg3) so firmware can
    // SEE whether the delay-line calibrated (RDY high = taps will move). A named
    // net so the STATUS mux can reference it before the PHY drives it below.
    final xilIdelayRdy = Logic(name: 'xil_idelay_rdy');
    if (trainableRead && isEcp5Phy) {
      final sizeLog2 = config.size.bitLength - 1; // power-of-2 array size
      final busOff = nbAddr.width > 32
          ? nbAddr.getRange(0, 32)
          : nbAddr.zeroExtend(32);
      isCtrl = busOff[sizeLog2].named('ddr_is_ctrl');
      // 8-byte-strided registers: select on bits [6:3] (0x00..0x40). Widened
      // from 3 to 4 bits to add the WRITE-TRIM reg8 (@ +0x40) above reg0-7.
      final regSel = busOff.slice(6, 3);
      // Low 32-bit half of an 8-byte register (offset bit[2]==0). Gates the
      // toggle writes so the downsizer's two narrow halves do not double-act.
      final ctrlAligned = ~busOff[2];

      // PHY-runtime controls: created here so the PHY can be constructed
      // against them, DRIVEN in PART B from the sclk-domain steppers.
      trainLoadn = Logic(name: 'train_loadn');
      trainMove = Logic(name: 'train_move');
      trainDir = Logic(name: 'train_dir');
      trainSlackRt = Logic(name: 'train_slack_rt', width: slackW);
      trainReadClkSel = Logic(name: 'train_readclksel_rt', width: 3);
      trainRdPulsePos = Logic(name: 'train_rd_pulse_pos_rt', width: pulseW);
      trainRdpLoadn = Logic(name: 'train_rdp_loadn_rt');
      trainRdpMove = Logic(name: 'train_rdp_move_rt');
      trainRdpDir = Logic(name: 'train_rdp_dir_rt');
      trainBdetClear = Logic(name: 'train_bdet_clear_rt');

      rdtapTarget = Logic(name: 'train_rdtap', width: 7);
      rdSlackReg = Logic(name: 'train_rdslack', width: slackW);
      readClkSelReg = Logic(name: 'train_readclksel', width: 3);
      // reg11 RDPULSE holding register. Resets to the sentinel (legacy gate).
      rdPulsePosReg = Logic(name: 'train_rd_pulse_pos', width: pulseW);
      rdpLoadnReg = Logic(name: 'train_rdp_loadn', width: 1);
      rdpDirReg = Logic(name: 'train_rdp_dir', width: 1);
      // The MOVE control is edge-driven in the sclk domain, PART A only flips a
      // toggle that PART B edge-detects (one MOVE pulse per write).
      setToggle = Logic(name: 'train_set_tgl');
      loadToggle = Logic(name: 'train_load_tgl');
      rdpMoveToggle = Logic(name: 'train_rdp_move_tgl');
      bdetClearToggle = Logic(name: 'train_bdet_clear_tgl');
      trainBusyPending = Logic(name: 'train_busy_pending');
      // Firmware WRDLY (reg7): the per-lane write-DQS-delay tap (4 bits per byte
      // lane) at [4*laneCount-1:0], plus a WRDIRECTION bit at [4*laneCount], and
      // the apply toggle. A write to reg7 latches the field and flips the toggle
      // so the sclk-domain PHY stepper reloads + steps the write pointer.
      wrDlyReg = Logic(name: 'train_wrdly', width: wrDlyW);
      wrDlyApplyToggle = Logic(name: 'train_wrdly_apply_tgl');
      // Firmware DQS-DELAY TRIM (reg8): per-lane DQSBUFM DYNDELAY packed
      // [8*laneCount-1:0]. Quasi-static (firmware writes it then settles, no
      // apply toggle, the value crosses to sclk and drives the DYNDELAY ports
      // level-wise). The per-DQS-group read-eye center knob.
      wrTrimReg = Logic(name: 'train_wrtrim', width: wrTrimW);
      // reg10 PER-BIT DQ DESKEW select: {broadcastBit(MSB), dqIndex}. Quasi-static
      // level (no apply toggle), crosses to sclk and gates the DELAYF MOVE/LOADN.
      // Reset default = broadcast (MSB set) so a boot that never writes reg10
      // keeps the existing group-walk semantics.
      dqDeskewSelReg = Logic(name: 'train_dqdeskew', width: dqDeskewSelW);

      final wData = nbDataIn; // narrow face is already 32-bit
      // A control access is served with a single-cycle ack on the bus clock, it
      // never enters the datapath. [ctrlAckReg] is set the cycle after a control
      // stb is seen and cleared once the master drops stb (held one cycle).
      final ctrlAckReg = Logic(name: 'ddr_ctrl_ack');
      ctrlAck = ctrlAckReg;
      // One write transaction may span several bus cycles (the master holds stb
      // until ack). [ctrlWrite] is high across them, flip the SET/LOAD/RDMOVE
      // toggles only on its RISING EDGE and only on the aligned half so each
      // write transaction toggles exactly once (an even number of flips would
      // cancel into no CDC edge).
      final ctrlWrite = (isCtrl & ctrlAligned & nbStb & nbWe & ~nbAck).named(
        'ddr_ctrl_write',
      );
      final ctrlWritePrev = Logic(name: 'ddr_ctrl_write_prev');
      final ctrlWriteEdge = (ctrlWrite & ~ctrlWritePrev).named(
        'ddr_ctrl_write_edge',
      );

      // reg0 rdtapTarget (7b), reg1 CTL (bit0 SET, bit1 LOAD), reg2 rdSlack,
      // reg3 STATUS (read-only), reg4 READCLKSEL (3b), reg5 RDPCTL (bit0
      // RDLOADN active-low, bit1 RDDIRECTION, bit2 RDMOVE -> one DQSBUFM read-
      // pointer step). SET/LOAD/RDMOVE are level-TOGGLES so a single CDC edge
      // into sclk triggers exactly one action regardless of bus-vs-sclk rate.
      // A SET or LOAD write launches a walk, mark busy pending until the sclk
      // controller's busy crosses back (see [trainBusyPending] rationale).
      final ctlLaunch =
          ctrlWriteEdge & regSel.eq(Const(1, width: 4)) & (wData[0] | wData[1]);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          // reg10 DQ-deskew select resets to BROADCAST (MSB set) so a boot that
          // never writes reg10 keeps the group-walk semantics (all DQ move
          // together). Every other train reg resets to 0 (the list default).
          dqDeskewSelReg: Const(
            1 << config.dataWidth.bitLength,
            width: dqDeskewSelW,
          ),
          // reg11 RDPULSE resets to the all-ones sentinel = "use legacy gate" so a
          // boot that never programs the read-pulse position is byte-behavior-
          // identical to before the independent pulse knob existed.
          rdPulsePosReg: Const(pulseSentinel, width: pulseW),
        },
        [
          ctrlWritePrev < ctrlWrite,
          // Single-cycle control ack: raise when a control stb arrives unacked,
          // drop once acked (the master releases stb after sampling the ack).
          ctrlAckReg < (isCtrl & nbStb & ~ctrlAckReg),
          If(ctlLaunch, then: [trainBusyPending < 1]),
          If(busySync, then: [trainBusyPending < 0]),
          If(
            ctrlWrite,
            then: [
              Case(regSel, [
                CaseItem(Const(0, width: 4), [rdtapTarget < wData.slice(6, 0)]),
                CaseItem(Const(1, width: 4), [
                  If(ctrlWriteEdge & wData[0], then: [setToggle < ~setToggle]),
                  If(
                    ctrlWriteEdge & wData[1],
                    then: [loadToggle < ~loadToggle],
                  ),
                  // bit2 CLEAR: re-arm the sticky BURSTDET/DATAVALID-seen latches so
                  // firmware can use BURSTDET as a per-step read-level oracle. One edge
                  // per write, PART B edge-detects it into a one-sclk PHY clear pulse.
                  If(
                    ctrlWriteEdge & wData[2],
                    then: [bdetClearToggle < ~bdetClearToggle],
                  ),
                ]),
                CaseItem(Const(2, width: 4), [
                  rdSlackReg < wData.slice(slackW - 1, 0),
                ]),
                // STATUS (3) is read-only.
                CaseItem(Const(4, width: 4), [
                  readClkSelReg < wData.slice(2, 0),
                ]),
                CaseItem(Const(5, width: 4), [
                  rdpLoadnReg < wData[0],
                  rdpDirReg < wData[1],
                  If(
                    ctrlWriteEdge & wData[2],
                    then: [rdpMoveToggle < ~rdpMoveToggle],
                  ),
                ]),
                // reg7 WRDLY (@ +0x38): the firmware write-DQS-delay tap. Latch the
                // per-lane nibble field and, on the write EDGE, flip the apply toggle
                // so the PHY reloads + steps the write pointer to this tap. One edge
                // per firmware write (gated on ctrlWriteEdge), like SET/LOAD/RDMOVE.
                CaseItem(Const(7, width: 4), [
                  wrDlyReg < wData.slice(wrDlyW - 1, 0),
                  If(
                    ctrlWriteEdge,
                    then: [wrDlyApplyToggle < ~wrDlyApplyToggle],
                  ),
                ]),
                // reg8 WRITE-TRIM (@ +0x40): lane-0 DQSBUFM DYNDELAY[7:0]. Quasi-
                // static level (no apply toggle), the value crosses to sclk and drives
                // the DYNDELAY ports directly.
                CaseItem(Const(8, width: 4), [
                  wrTrimReg < wData.slice(wrTrimW - 1, 0),
                ]),
                // reg10 PER-BIT DQ DESKEW select (@ +0x50): {broadcastBit(MSB),
                // dqIndex}. Quasi-static level (no apply toggle), crosses to sclk and
                // gates which DQ bit the DELAYF MOVE/LOADN walk steps. On the ECP5
                // branch reg10 is otherwise unused (reg10/11/12 are the Xilinx map, a
                // separate branch), so this does not collide.
                CaseItem(Const(10, width: 4), [
                  dqDeskewSelReg < wData.slice(dqDeskewSelW - 1, 0),
                ]),
                // reg11 RDPULSE (@ +0x58): the INDEPENDENT READ0/READ1 read-pulse
                // position (5-bit: 0..15 real, 31 = legacy gate). Quasi-static (no apply
                // toggle), crosses to sclk and selects the DQSBUFM read-gate open tap
                // INDEPENDENTLY of the RDSLACK capture anchor, so the FSBL can walk it
                // against BURSTDET until the read window frames the data burst (not the
                // preamble). On the ECP5 branch reg11 was unused (the Xilinx map is a
                // separate branch), so this does not collide.
                CaseItem(Const(11, width: 4), [
                  rdPulsePosReg < wData.slice(pulseW - 1, 0),
                ]),
              ]),
            ],
          ),
        ],
      );

      // STATUS (reg3) bit map:
      //   [0]      busy
      //   [7:1]    currentTap
      //   [8]      DATAVALID     (live lane-0 DQSBUFM)
      //   [9]      BURSTDET      (live lane-0 DQSBUFM)
      //   [10]     DLL_LOCK      (DDRDLLA lock / ddrdel-alive, sclk-registered)
      //   [11]     BDET_SEEN     (sticky BURSTDET-ever, sclk-latched)
      //   [12]     DVALID_SEEN   (sticky DATAVALID-ever, sclk-latched)
      //   (RDPNTR/WRPNTR omitted: the DQSBUFM pointer ports cannot drive fabric
      //   on the ECP5, so nextpnr refuses to pack them onto a status flop.)
      //
      // X-PROPAGATION NOTE: DATAVALID/BURSTDET/DLL/pointers come from the DQSBUFM
      // and DLL (SV leaves with no sim model) so they are X in simulation. ROHD's
      // `mux` amplifies ANY x/z bit in either operand to an all-x result, so the
      // DQS flags must NOT pass through any wide read mux as part of a vector
      // that also carries the defined control plane (busy/tap), or the
      // control-plane sim test would read all-x. So [ctrlReadCtl] (the wide
      // register-read mux) carries ONLY the defined control plane, and the
      // observability bits are spliced onto [18:8] by concatenation (per-bit, no
      // mux), confining the sim X to [18:8]. On hardware all bits are real. This
      // all runs on the bus clock now (the control read is served here, not in
      // the datapath).
      // busy = synced controller-busy OR the bus-domain launch-pending latch
      // (covers the SET-write -> walk-start CDC latency).
      final statusCtrl = [
        curTapSync,
        busySync | trainBusyPending,
      ].swizzle().zeroExtend(32);
      // reg6 WL-RESULT (read-only, @ +0x30): the write-leveling trained taps and
      // the WL-complete latch. wlTrainedSync packs 4 bits per byte lane (lane0
      // [3:0], lane1 [7:4]), wlDone sits at bit [4*laneCount]. All DEFINED fabric
      // regs, so this rides the normal read mux below (NOT the DQS splice).
      //   reg6[4*laneCount-1 : 0]  wlTrained (per-lane, 4b each)
      //   reg6[4*laneCount]        wlDone
      // reg6 is a SEPARATE register from STATUS (reg3): the DQS splice in
      // assembleReadback only fires on ctrlIsStatus (regSel==3), so reg6 rides the
      // plain read mux even where wlDone lands inside the [12:8] slot. Keep the
      // word inside 32 bits.
      assert(
        4 * laneCount + 1 <= 32,
        'WL result must fit in the 32-bit read word',
      );
      // reg6 layout: [3:0]/[7:4] wlTrained, [4*laneCount]=bit8 wlDone,
      // [23:16] wlFbMap witness (per-tap voted feedback, last lane). The FSBL
      // reads reg6>>16 & 0xFF: all-0/all-FF = feedback never flips (RTL fault),
      // a 0..01..1 ramp = the WL edge is present.
      // Gap sized so wlFbMap always lands at [23:16] regardless of laneCount:
      // wlTrained[4*laneCount-1:0], wlDone at bit 4*laneCount, gap, then the
      // witness byte at [23:16]. For creek (laneCount=2) the gap is 7.
      assert(
        4 * laneCount + 1 <= 16,
        'WL trained+done must fit below the witness byte at [23:16]',
      );
      final wlResult = ([
        wlFbMapSync,
        Const(0, width: 16 - (4 * laneCount + 1)),
        wlDoneSync,
        wlTrainedSync,
      ].swizzle()).zeroExtend(32);
      // reg5 WRCTL (read-only, @ +0x28): the on-chip write-control diagnostic
      // word. reg5 is WRITE-only as RDPCTL (RDLOADN/RDDIRECTION/RDMOVE, it read
      // back 0 before), so its READ slot is FREE and now carries the WRCTL
      // counters. Writes to reg5 still program RDPCTL unchanged, this only adds a
      // read meaning. Packed OE[7:0], CMD[15:8], DM[23:16], DAT[31:24]. All
      // defined fabric counters, so this rides the plain mux (NOT the DQS splice).
      final wrCtl = [
        wrDatSync,
        wrDmSync,
        wrCmdSync,
        wrOeSync,
      ].swizzle().zeroExtend(32);
      ctrlReadCtl = mux(
        regSel.eq(Const(0, width: 4)),
        rdtapTarget.zeroExtend(32),
        mux(
          regSel.eq(Const(2, width: 4)),
          rdSlackReg.zeroExtend(32),
          mux(
            regSel.eq(Const(3, width: 4)),
            statusCtrl,
            mux(
              regSel.eq(Const(4, width: 4)),
              readClkSelReg.zeroExtend(32),
              mux(
                regSel.eq(Const(5, width: 4)),
                wrCtl, // reg5 read = WRCTL diagnostics (write side is RDPCTL)
                mux(
                  regSel.eq(Const(6, width: 4)),
                  wlResult,
                  mux(
                    regSel.eq(Const(7, width: 4)),
                    wrDlyReg.zeroExtend(32), // reg7 WRDLY reads back the tap
                    mux(
                      regSel.eq(Const(8, width: 4)),
                      wrTrimReg.zeroExtend(
                        32,
                      ), // reg8 WRITE-TRIM reads back the trim
                      mux(
                        regSel.eq(Const(9, width: 4)),
                        wrCapSync, // reg9 WR-CAP: lane-0 driven sub-beats (loopback)
                        Const(0, width: 32), // CTL read back 0
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // Observability payload [12:8] + the STATUS select, carried to the final
      // nbDataOut splice. LSB-first swizzle: bit 8 first. Layout (relative to the
      // splice base [8]): DATAVALID[0], BURSTDET[1], DLL_LOCK[2], BDET_SEEN[3],
      // DVALID_SEEN[4].
      ctrlDqsBits = [
        dataValidSeenSync, // [12]
        burstDetSeenSync, // [11]
        dllLockSync, // [10]
        burstDetSync, // [9]
        dataValidSync, // [8]
      ].swizzle();
      ctrlIsStatus = (isCtrl & regSel.eq(Const(3, width: 4)));
    } else if (trainableRead) {
      // Xilinx read-training control decode. The bus-side plumbing mirrors the
      // ECP5 branch (isCtrl / regSel / one-cycle ctrlWriteEdge on the bus clock),
      // but the register file is the Xilinx IDELAY/BITSLIP decode instead of the
      // DELAYF stepper. The register numbers (reg10 IDELAY @ +0x50, reg11 BITSLIP
      // @ +0x58) sit ABOVE the ECP5 reg0..9 block so the two maps never collide.
      // reg2 RDSLACK / reg3 STATUS are latched for read-back parity but the
      // Xilinx PHY takes readSlack at build time (no runtime-slack port), so they
      // are informational here.
      final busOff = nbAddr.width > 32
          ? nbAddr.getRange(0, 32)
          : nbAddr.zeroExtend(32);
      // Full-width >= decode (same as isCtrlWide): a bit-select gets DCE'd here too.
      isCtrl = busOff.gte(Const(config.size, width: 32)).named('ddr_is_ctrl');
      final regSel = busOff.slice(6, 3);
      final ctrlAligned = ~busOff[2];
      final wData = nbDataIn;

      final ctrlAckReg = Logic(name: 'ddr_ctrl_ack');
      ctrlAck = ctrlAckReg;
      final ctrlWrite = (isCtrl & ctrlAligned & nbStb & nbWe & ~nbAck).named(
        'ddr_ctrl_write',
      );
      final ctrlWritePrev = Logic(name: 'ddr_ctrl_write_prev');
      final ctrlWriteEdge = (ctrlWrite & ~ctrlWritePrev).named(
        'ddr_ctrl_write_edge',
      );
      // reg2 RDSLACK latch (read-back only on the Xilinx path).
      final rdSlackLatch = Logic(name: 'train_rdslack', width: slackW);
      Sequential(clk, reset: reset, [
        ctrlWritePrev < ctrlWrite,
        ctrlAckReg < (isCtrl & nbStb & ~ctrlAckReg),
        If(
          ctrlWrite,
          then: [
            If(
              regSel.eq(Const(2, width: 4)),
              then: [rdSlackLatch < wData.slice(slackW - 1, 0)],
            ),
          ],
        ),
      ]);

      // The IDELAY VARIABLE (reg10) + BITSLIP (reg11) decode. Built on the bus
      // clock (the controls are quasi-static: firmware writes a tap/slip, waits,
      // reads back a pattern), then fed into the PHY read engine. NOTE: on an
      // asyncClock build these single-cycle pulses cross into the PHY (ddr_clk)
      // domain un-synchronized, acceptable for the current single-clock Arty
      // bring-up (dpClk == clk), a pulse-CDC handshake is a follow-up if the
      // Xilinx PHY is ever run on a separate ddr_clk.
      final xrt = XilinxReadTrainRegs(
        clk,
        reset,
        regSel: regSel,
        wData: wData,
        ctrlWrite: ctrlWrite,
        ctrlWriteEdge: ctrlWriteEdge,
        dataBits: config.dataWidth,
        // The 3D MPR read-window sweep localized the DRAM read burst to
        // ctrl100 read-pipe cycle 5 (windows 4/5/6 carry live tap-varying data,
        // center=5, 0-3/7 are idle preamble). Reset reg12 to 5 so a normal boot
        // comes up landed on the burst without a firmware window sweep. Firmware
        // can still override reg12 at runtime for a retrain. Build-sweepable via
        // HARBOR_DDR_WINDOW for a fresh board whose burst lands on a different
        // read-pipe cycle (the coarse read-alignment knob paired with the fine
        // per-lane IDELAY read tap). Threaded from the region params / board
        // default via [windowTapReset].
        windowTapReset: windowTapReset,
      );
      xilIdelayLd = xrt.idelayLd;
      xilIdelayCntValue = xrt.idelayCntValue;
      xilIdelayLane = xrt.idelayLane;
      xilBitslip = xrt.bitslip;
      xilBitslipLane = xrt.bitslipLane;
      xilWindowTap = xrt.windowTap;
      xilRefreshLevel = xrt.refl;

      // Read-back: reg2 returns the latched slack, reg3 STATUS returns
      // diagnostics: bit0 = IDELAYCTRL RDY (the calibration smoking gun),
      // bits[15:8] = the sequencer WRITE-command counter (saturating), so
      // firmware can SEE whether the controller is actually issuing DDR writes
      // to the array (0 = no writes reaching DRAM = write path / init dead,
      // nonzero + climbing = writes are being issued). Everything else 0.
      final xilStatus = [
        chDriveOverlap, // [23:16] DQ-drive-overlap count (write pad OE witness)
        chWrCmdCount, // [15:8] write-command count
        chStateCode, // [7:4] sequencer FSM state code (stuck-state diagnostic)
        Const(0, width: 2), // [3:2]
        chInitDone, // [1] init/calibration DONE (DRAM brought up = DRAM ALIVE)
        xilIdelayRdy, // [0] IDELAYCTRL RDY
      ].swizzle().zeroExtend(32);
      ctrlReadCtl = mux(
        regSel.eq(Const(2, width: 4)),
        rdSlackLatch.zeroExtend(32),
        mux(
          regSel.eq(Const(3, width: 4)),
          xilStatus,
          // reg4 = PHY latched write word, reg5 = launched line (DEBUG probes).
          mux(
            regSel.eq(Const(4, width: 4)),
            chWrWord.zeroExtend(32),
            mux(
              regSel.eq(Const(5, width: 4)),
              chDataLine,
              mux(
                regSel.eq(Const(6, width: 4)),
                chDqsClk.zeroExtend(32),
                mux(
                  regSel.eq(Const(7, width: 4)),
                  chBeats.zeroExtend(32),
                  Const(0, width: 32),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final DdrPhy phy = switch (_ddrPhyKind(target)) {
      _DdrPhyKind.xilinx => DdrPhyXilinx(
        dpClk,
        dpReset,
        cke: chCke,
        csN: chCsN,
        cmd: chCmd,
        ba: chBa,
        addr: chAddr,
        odt: chOdt,
        resetN: chResetN,
        wrStart: chWrStart,
        wrData: chWrData,
        wrMask: chWrMask,
        beatSel: chBeatSel,
        rdStart: chRdStart,
        dqIn: dqIn,
        rowBits: config.rowWidth,
        baBits: (config.banks - 1).bitLength,
        dataBits: config.dataWidth,
        clkMhz: clkMhz,
        // DDR3-667 speed-bin CL/CWL on the ddr3Fast path (drives the read-window
        // CL anchor and the write-launch CWL offset), fixed 6/6 on the 48 MHz
        // DLL-off path (byte-identical to before).
        cl: ddr3Fast ? ddr3FastCl : 6,
        cwl: ddr3Fast ? ddr3FastCwl : 6,
        // CK/tick ratio: 4 on ddr3Fast (ctrl83 = CK/4), 1 otherwise. Splits the
        // CK-quoted CWL/CL into the whole-tick launch + the sub-tick beat offset.
        ckCyclesPerTick: ddr3Fast ? 4 : 1,
        readSlack: readSlack,
        // REAL-SPEED DDR3-667 read datapath (ISERDESE2 DW8 gearbox). When set,
        // the tree clocks (ck333/ck333@90/200 MHz idelayref) are fed straight
        // from the controller's ddr3Fast input ports, [dpClk] is ctrl83.
        ddr3Fast: ddr3Fast,
        ckFast: ddr3Fast ? input('ddr_ck_fast') : null,
        ck90Fast: ddr3Fast ? input('ddr_ck90_fast') : null,
        // A dedicated 180-deg DQS launch clock is a 4th global clock into the
        // IO region, the HW-proven UberDDR3 openXC7 PHY instead launches DQS on
        // !CK (combinational invert) and routes only 3 IO clocks. Dropping it
        // (PHY falls back to ckFast) matches that clock budget. Env-gated while
        // bringing the Arty DDR clock network up on openXC7.
        ckDqsFast:
            (ddr3Fast && Platform.environment['HARBOR_DDR_NO_DQSCLK'] != '1')
            ? input('ddr_ck_dqs_fast')
            : null,
        idelayRef: ddr3Fast ? input('ddr_idelay_ref') : null,
        idelayRefFastMhz: ddr3FastIdelayRefMhz,
        // ddr3Fast: the PHY owns the DQ/DQS pads so the write OSERDESE2 in-site
        // tristate (TQ) reaches the pad IOBUF T pin directly (the OLOGIC_D1
        // overused=32 fix). Pass the inout pad nets, the controller skips its own
        // TriStateBuffer for these below.
        padDq: ddr3Fast ? inOut('sdram_dq') : null,
        padDqs: ddr3Fast ? inOut('sdram_dqs') : null,
        padDqsN: ddr3Fast ? inOut('sdram_dqs_n') : null,
        // Per-lane read-training controls (null unless trainableRead): VARIABLE
        // IDELAY LD/CE/INC + lane, and the fabric BITSLIP pulse + lane, decoded
        // from the train-control MMIO by XilinxReadTrainRegs above.
        idelayLd: xilIdelayLd,
        idelayCntValue: xilIdelayCntValue,
        idelayLane: xilIdelayLane,
        bitslip: xilBitslip,
        bitslipLane: xilBitslipLane,
        // Runtime read-window select (ddr3Fast): the reg12 window tap.
        windowSel: xilWindowTap,
        // ddr3Fast write/command timing knobs (region params / board defaults).
        cmdSlot: cmdSlot,
        writeShift: writeShift,
        wrBeatOffset: wrBeatOffset,
        // Write-leveling (ddr3Fast only): the PHY drives the per-lane DQS beat
        // rotation from the sequencer's WL FSM controls and returns the
        // lane-selected DQ feedback. Mirrors the ECP5 block below.
        writeLevel: useWriteLevel,
        wlEn: useWriteLevel ? chWlEn : null,
        wlDelayRst: useWriteLevel ? chWlDelayRst : null,
        wlDelayInc: useWriteLevel ? chWlDelayInc : null,
        wlStrobe: useWriteLevel ? chWlStrobe : null,
        wlLane: useWriteLevel ? chWlLane : null,
        wlTrained: useWriteLevel ? chWlTrained : null,
        wlDone: useWriteLevel ? chWlDone : null,
        // The MMCM works on openXC7 too (BUFG feedback + ZHOLD, see
        // XilinxMmcme2Adv / clock_domain), so the PHY uses the real 90-degree
        // MMCM write-launch clock on every Xilinx target.
      ),
      _DdrPhyKind.ecp5 => DdrPhyEcp5(
        dpClk,
        dpReset,
        cke: chCke,
        csN: chCsN,
        cmd: chCmd,
        ba: chBa,
        addr: chAddr,
        odt: chOdt,
        resetN: chResetN,
        wrStart: chWrStart,
        wrData: chWrData,
        wrMask: chWrMask,
        beatSel: chBeatSel,
        rdStart: chRdStart,
        // The ECP5 PHY owns the DQ/DQS tristate pads: pass the inout pad nets
        // straight in. DQ is always present, DQS only on DDR. The DQS _n net is
        // passed ONLY when the controller created sdram_dqs_n (DLL-OFF: the PHY
        // drives an explicit pseudo-differential complement), DLL-ON the single
        // SSTL135D_I diff pad lets nextpnr derive _n, so no _n net.
        padDq: inOut('sdram_dq'),
        padDqs: config.isDdr ? inOut('sdram_dqs') : null,
        padDqsN: (config.isDdr && (clockHz / 1000000).round() <= 60)
            ? inOut('sdram_dqs_n')
            : null,
        rowBits: config.rowWidth,
        baBits: (config.banks - 1).bitLength,
        dataBits: config.dataWidth,
        // SCLK is the half-rate fabric clock, the sequencer below runs on it, so
        // its timing counters must derive from HALF the CK-rate clkMhz to keep
        // every real-time (us/ns) JEDEC delay equivalent. clkMhz stays a PHY knob
        // for real-time JEDEC-delay scaling (the Milestone 4 write path launches
        // off the DQSBUFM strobes, so it no longer sizes an internal PLL).
        clkMhz: clkMhz,
        readTaps: readTaps,
        readSlack: readSlack,
        readClkSel: readClkSel,
        readCrossPair: readCrossPair,
        readPairMode: readPairMode,
        readOnClk: readOnClk,
        trainable: trainableRead,
        delayLoadn: trainLoadn,
        delayMove: trainMove,
        delayDirection: trainDir,
        rdSlackRuntime: trainSlackRt,
        readClkSelRuntime: trainReadClkSel,
        // reg11 RDPULSE: the independent READ0/READ1 read-pulse position, so the
        // FSBL frames the burst (not the preamble) via BURSTDET.
        rdPulsePos: trainRdPulsePos,
        maxRdPulse: maxRdPulse,
        rdLoadn: trainRdpLoadn,
        rdMove: trainRdpMove,
        rdDirection: trainRdpDir,
        // Firmware BURSTDET-seen CLEAR (reg1 bit2) so the FSBL can read-level with
        // BURSTDET as a per-step oracle to pin the read pointer per boot.
        bdetClear: trainBdetClear,
        maxRdSlack: maxRdSlack,
        // Write-leveling: the PHY drives the per-lane DQS write pointer from the
        // sequencer's WL FSM controls and returns the lane-selected DQ feedback.
        writeLevel: useWriteLevel,
        wlEn: useWriteLevel ? chWlEn : null,
        wlDelayRst: useWriteLevel ? chWlDelayRst : null,
        wlDelayInc: useWriteLevel ? chWlDelayInc : null,
        wlStrobe: useWriteLevel ? chWlStrobe : null,
        wlLane: useWriteLevel ? chWlLane : null,
        wlTrained: useWriteLevel ? chWlTrained : null,
        wlDone: useWriteLevel ? chWlDone : null,
        // Firmware write-DQS-delay (reg7): the PHY steps the per-lane write
        // pointer to the firmware tap on each apply edge, taking precedence over
        // the auto-WL trained tap. Wired on the trainable ECP5 DDR3 build.
        wrDlyTrainable: useWrDly,
        wrDly: useWrDly ? chWrDly : null,
        wrDlyApply: useWrDly ? chWrDlyApply : null,
        // Firmware WRITE-TRIM (reg8): lane-0 DQSBUFM DYNDELAY[7:0]. Wired on the
        // writeTrimTrainable ECP5 DDR3 build, the PHY drives lane 0's DQS delay.
        writeTrimTrainable: useWriteTrim,
        wrTrim: useWriteTrim ? chWrTrim : null,
        // Per-bit DQ read deskew (reg10): {broadcastBit, dqIndex}. Gates the
        // shared DELAYF MOVE/LOADN to one DQ bit so the FSBL can deskew each bit
        // into the DQS eye (closes the 2nd-beat per-DQ scramble). Rides the same
        // trainable ECP5 DDR3 gate as the read tap, also restores DQ0/DQ8 full
        // read + sources the WL feedback from the captured qBeats.
        perBitDeskew: usePerBitDeskew,
        dqDeskewSelect: usePerBitDeskew ? chDqDeskewSel : null,
      ),
    };

    // STATUS witnesses cross the sequencer/PHY clock (seqClk/dpClk) into the bus
    // `clk` the reg3 STATUS is READ on. On the ddr3Fast + async ECP5 paths those
    // are DIFFERENT domains, so sampling seq.initDone / seq.stateCode /
    // seq.wrCmdCount and the PHY witnesses straight into STATUS returns
    // metastable / stale values. This is exactly why the reg3 STATUS LIED on the
    // Arty (reported init_done=0, state=sCkeWait) while the logic analyzer showed
    // the sequencer clock alive, init_done=1, and state=sIdle with the command
    // bus firing. Route each witness through a 2-flop bus-clk synchronizer.
    // init_done / idelay_rdy are clean levels, state_code and the saturating
    // counters are quasi-static (hold many cycles per FSM step, constant when the
    // init settles or wedges), so a per-bit 2-flop sync yields the correct
    // settled value and only a rare, benign transient skew mid-transition, which
    // is fine for a read-only diagnostic. On the single-clock path seqClk == clk,
    // so these degrade to plain flops (one cycle of latency, no functional
    // change). clk / reset are the bus-face clock+reset from the top of build().
    Logic statusToBus(Logic src, String label, {int width = 1}) {
      final q0 = Logic(name: '${label}_q0', width: width);
      final q1 = Logic(name: '${label}_q1', width: width);
      Sequential(clk, reset: reset, [q0 < src, q1 < q0]);
      return q1;
    }

    // Drive the IDELAYCTRL RDY read-back on the trainable Xilinx path (the PHY
    // exposes it as an 'idelay_rdy' output). On every other build xilIdelayRdy
    // has no consumer, so it stays undriven and is optimized away. Bus-synced so
    // the STATUS bit0 reflects the real RDY, not a cross-domain sample.
    if (trainableRead && _ddrPhyKind(target) == _DdrPhyKind.xilinx) {
      xilIdelayRdy <= statusToBus((phy as DdrPhyXilinx).idelayRdy, 'st_idlrdy');
    }

    // The fabric clock for the sequencer + bus-face datapath. On the ASYNC ECP5
    // path (creek's real target) it is the PHY-exported sclk (= dpClk/2 = the
    // CK/2 fabric clock from CLKDIVF), so the sequencer + request-side bus-face
    // registers + the CDC master all run in the half-rate fabric domain: the
    // Milestone 1 restructure. The Xilinx PHY keeps its gearing internal and
    // stays on dpClk.
    //
    // The SINGLE-CLOCK ECP5 path (the legacy / read-training bring-up, NOT the
    // async creek target) keeps the fabric on the real dpClk. Reason: ROHD's
    // [Sequential] cannot be clocked off a derived clock in SIMULATION (CLKDIVF
    // is an unmodelled SV leaf, its behavioral stand-in is a register output,
    // which ROHD's sim rejects as a clock: the rohd-rtl-gotchas z/"No element"
    // trap). The single-clock path is the one with functional sims (ddr_train),
    // so it must stay on the SimpleClockGenerator clock. asyncClock and
    // trainableRead now COEXIST (the training control window decodes on the bus
    // clock and is gated out of the sclk datapath, only the trained config is
    // 2-flop synchronized across, see the control block PART A/PART B), and the
    // async path is exercised functionally (ddr_async_roundtrip, including the
    // async+trainable control-plane case). This split keeps every test faithful
    // while delivering the sclk fabric for the target that actually ships it
    // (creek).
    // DLL engagement (mirrors the PHY's build-time `dllOn = clkMhz > 60`). The
    // sclk (CK/2) fabric + x2 DQSBUFM datapath are DLL-ON only: at DLL-off (e.g.
    // 48 MHz CK) the ECP5 DDRDLLA never locks, so the PHY builds the x1 (CK-rate)
    // datapath (IDDRX1F/ODDRX1F on a dedicated PHY-PLL clk90, single clock = CK).
    // The sequencer MUST then run on the CK-rate clock (dpClk), not the halved
    // sclk, with ckCyclesPerTick = 1. So the sclk fabric is selected only when the
    // DLL is engaged. (On the single-clock / non-async path useSclkFabric was
    // already false.)
    final dllOn = clkMhz > 60;
    final useSclkFabric = phy is DdrPhyEcp5 && asyncClock && dllOn;
    final seqClk = useSclkFabric ? phy.sclkOut : dpClk;

    // FINDING M3: reset domain for the sclk-clocked fabric. The house reset
    // convention (see HarborClockGenerator._domainReset) is ASYNC-ASSERT,
    // SYNC-DEASSERT: assertion is immediate so it holds even before a domain
    // clock runs, but deassertion is re-timed through a two-flop synchronizer in
    // the target clock domain to avoid recovery/removal hazards when the source
    // releases asynchronously to that clock.
    //
    // On the single-clock path the sequencer runs on dpClk, which is the same
    // domain dpReset belongs to, so dpReset is used directly. On the sclk fabric
    // path the sequencer + PHY-fabric + CDC-master flops run on sclk = ddr_clk/2,
    // a clock that only exists inside the PHY, so the external ddr_reset cannot
    // have been pre-synchronized to it. We synchronize the deassert here: assert
    // immediately on dpReset, deassert two clean sclk edges later.
    final Logic seqReset;
    if (useSclkFabric) {
      final rstSync = Logic(name: 'ddr_sclk_rst_sync', width: 2);
      Sequential(seqClk, reset: dpReset, [
        rstSync < [rstSync[0], Const(1)].swizzle(),
      ]);
      // Gate the sequencer on the PHY's DDRDEL-load init FSM (initDone): hold
      // it in reset until the ECP5DDRPHYInit handshake has latched the
      // calibrated DDRDEL code into the DQSBUFMs, so NO read/write command
      // issues before the read path's delay code is loaded (the root-cause fix
      // for the "DLL locks but no burst detected" silicon failure). The PHY's
      // init FSM runs on the ungated init [clk] (it asserts eclkStop, which
      // stops eclk/sclk, so it cannot run on sclk without freezing itself), and
      // the PHY already 2-flop resynchronizes initDone back into its sclk fabric
      // before exposing initDoneOut, so it is sclk-clean here (seqClk =
      // phy.sclkOut) and used directly. This is minimal:
      // the sequencer simply stays in its sPower reset state until the PHY is
      // ready, then walks JEDEC init as before. On the single-clock (Xilinx /
      // non-async) path there is no such FSM and the gate is not applied.
      final initDone = phy.initDoneOut;
      seqReset = (dpReset | ~rstSync[1] | ~initDone).named('ddr_sclk_reset');
    } else if (asyncClock) {
      // Xilinx ddr3Fast async path: the sequencer runs on dpClk (= ddr_clk =
      // the ~100 MHz controller CLKOUT), but dpReset (ddr_reset) is synchronised
      // to the SoC bus/core clock (a DIFFERENT ~25 MHz CLKOUT of the same PLL) -
      // NOT dpClk's domain, despite the single-clock comment above. Using it raw
      // gives the FSM an unsynchronised reset DEASSERT: a recovery/removal hazard
      // that (because both clocks share one PLL and thus a FIXED phase) resolves
      // the SAME way every build: a DETERMINISTIC hang near the reset-exit state
      // (observed: sequencer wedged at sCkeWait, init never completes). Re-time
      // the deassert into dpClk (async-assert immediate, sync-deassert two dpClk
      // edges later), exactly as the sclk-fabric path above.
      final rstSync = Logic(name: 'ddr_seq_rst_sync', width: 2);
      Sequential(seqClk, reset: dpReset, [
        rstSync < [rstSync[0], Const(1)].swizzle(),
      ]);
      seqReset = (dpReset | ~rstSync[1]).named('ddr_seq_reset');
    } else {
      seqReset = dpReset;
    }
    // SCLK runs at half the CK rate, so the sequencer counts time at half the
    // clkMhz to keep the same real-time JEDEC delays. The dpClk paths keep the
    // full clkMhz.
    final seqClkMhz = useSclkFabric
        ? (clkMhz / 2).ceil().clamp(1, 400)
        : clkMhz;

    // Built here (after seqClk/seqReset exist) so the DELAYF walk and the DQS
    // read-pointer step run in the same domain the PHY primitives sample. The
    // quasi-static config crosses clk -> sclk through 2-flop synchronizers, the
    // SET / LOAD / RDMOVE level toggles cross the same way and are edge-detected
    // on sclk to fire exactly one action each. Status (currentTap, busy,
    // DATAVALID, BURSTDET) crosses back sclk -> clk through 2-flop syncs for the
    // STATUS register read. On the single-clock path seqClk == clk, so the
    // syncs are plain same-domain flops (behavior identical to before).
    if (trainableRead && isEcp5Phy) {
      // 2-flop synchronizer into the sclk domain.
      Logic syncToSclk(Logic src, String label, {int width = 1}) {
        final s0 = Logic(name: '${label}_s0', width: width);
        final out = Logic(name: '${label}_s1', width: width);
        Sequential(seqClk, reset: seqReset, [s0 < src, out < s0]);
        return out;
      }

      // 2-flop synchronizer back into the bus-clk domain.
      Logic syncToBus(Logic src, String label, {int width = 1}) {
        final s0 = Logic(name: '${label}_b0', width: width);
        final out = Logic(name: '${label}_b1', width: width);
        Sequential(clk, reset: reset, [s0 < src, out < s0]);
        return out;
      }

      // Quasi-static config into sclk. These change rarely (firmware writes
      // then waits), so a plain 2-flop sync is sufficient, no handshake needed.
      trainSlackRt! <= syncToSclk(rdSlackReg!, 'sl_rdslack', width: slackW);
      trainReadClkSel! <= syncToSclk(readClkSelReg!, 'sl_readclksel', width: 3);
      trainRdPulsePos! <=
          syncToSclk(rdPulsePosReg!, 'sl_rd_pulse_pos', width: pulseW);
      trainRdpLoadn! <= syncToSclk(rdpLoadnReg!, 'sl_rdploadn');
      trainRdpDir! <= syncToSclk(rdpDirReg!, 'sl_rdpdir');
      final targetSclk = syncToSclk(rdtapTarget!, 'sl_rdtap', width: 7);

      // SET / LOAD / RDMOVE toggles into sclk, then rising/falling edge detect
      // (a toggle is one edge per firmware write). The edge is the strobe.
      Logic toggleEdge(Logic tgl, String label) {
        final synced = syncToSclk(tgl, label);
        final prev = Logic(name: '${label}_prev');
        Sequential(seqClk, reset: seqReset, [prev < synced]);
        return synced ^ prev;
      }

      final setEdge = toggleEdge(setToggle!, 'sl_set');
      final loadEdge = toggleEdge(loadToggle!, 'sl_load');
      final rdpMoveEdge = toggleEdge(rdpMoveToggle!, 'sl_rdpmove');

      // The DELAYF tap walker, now CLOCKED ON sclk. The PHY's per-DQ DELAYF
      // primitives sit in the sclk fabric, so the MOVE pulses must be generated
      // here, not on the bus clock (that is the pulse-CDC hazard we avoid).
      final delayCtl = Ecp5DelayController(
        seqClk,
        seqReset,
        targetTap: targetSclk,
        setStrobe: setEdge,
        loadStrobe: loadEdge,
        tapWidth: 7,
      );
      trainLoadn! <= delayCtl.loadn;
      trainMove! <= delayCtl.move;
      trainDir! <= delayCtl.direction;

      // DQS read-pointer MOVE: one single-cycle MOVE pulse per RDMOVE write
      // edge, in the sclk domain (RDLOADN/RDDIRECTION are the synchronized
      // levels). The DQSBUFM steps its read pointer on the rising edge, the
      // pulse returns low the next cycle, so two firmware RDMOVE writes give two
      // clean, separated edges. REVIEWER NOTE: confirm against Lattice TN1265
      // that a single-sclk-cycle RDMOVE reliably steps the read pointer once on
      // this silicon (read-pointer training is bench-verified, not sim-able).
      final rdpMove = Logic(name: 'train_rdp_move_pulse');
      Sequential(seqClk, reset: seqReset, [
        rdpMove < 0,
        If(rdpMoveEdge, then: [rdpMove < 1]),
      ]);
      trainRdpMove! <= rdpMove;

      // BURSTDET-seen CLEAR: one sclk pulse per reg1-bit2 write edge, same shape
      // as the RDMOVE pulse. Feeds the PHY sticky-latch clear.
      final bdetClearEdge = toggleEdge(bdetClearToggle!, 'sl_bdet_clear');
      final bdetClearPulse = Logic(name: 'train_bdet_clear_pulse');
      Sequential(seqClk, reset: seqReset, [
        bdetClearPulse < 0,
        If(bdetClearEdge, then: [bdetClearPulse < 1]),
      ]);
      trainBdetClear! <= bdetClearPulse;

      // Firmware WRDLY (reg7) into the sclk PHY domain. The per-lane tap is
      // quasi-static (firmware writes it then settles), so a plain 2-flop sync is
      // enough. The apply TOGGLE crosses the same way: the PHY stepper edge-detects
      // it on sclk and fires one reload + step. (No edge-detect here: the PHY owns
      // the edge, exactly like the WL apply rides wl_done's edge.)
      if (useWrDly) {
        chWrDly <= syncToSclk(wrDlyReg!, 'sl_wrdly', width: wrDlyW);
        chWrDlyApply <= syncToSclk(wrDlyApplyToggle!, 'sl_wrdly_apply');
      }
      // Firmware WRITE-TRIM (reg8) into the sclk PHY domain. Quasi-static 8-bit
      // DYNDELAY value, a plain 2-flop level sync (no apply edge).
      if (useWriteTrim) {
        chWrTrim <= syncToSclk(wrTrimReg!, 'sl_wrtrim', width: wrTrimW);
      }
      // reg10 DQ-deskew select into the sclk PHY domain. Quasi-static level, a
      // plain 2-flop sync (no apply edge, the gating is combinational off the
      // synced value).
      if (usePerBitDeskew) {
        chDqDeskewSel <=
            syncToSclk(dqDeskewSelReg!, 'sl_dqdeskew', width: dqDeskewSelW);
      }

      // Status back to the bus clock for the STATUS register. currentTap (7b)
      // and busy are synchronized independently, so during a walk the synced
      // currentTap can show transient skewed codes and may lag/lead busy by a
      // cycle. FIRMWARE CONTRACT: read currentTap only AFTER STATUS.busy reads 0
      // (the walk has settled), the ddr_train_test and the FSBL both poll busy
      // first. A gray-code or capture-on-busy-fall would remove the contract but
      // is not needed for the quasi-static training use.
      curTapSync <= syncToBus(delayCtl.currentTap, 'bs_curtap', width: 7);
      busySync <= syncToBus(delayCtl.busy, 'bs_busy');
      dataValidSync <= syncToBus((phy as DdrPhyEcp5).rdDataValid, 'bs_dv');
      burstDetSync <= syncToBus(phy.rdBurstDet, 'bs_bd');
      // DQS-read observability. Same 2-flop sclk -> bus-clk sync. The DLL-lock
      // and sticky BURSTDET/DATAVALID-seen bits are quasi-static, so a 2-flop
      // sync samples them cleanly.
      dllLockSync <= syncToBus(phy.dllAliveOut, 'bs_dll');
      burstDetSeenSync <= syncToBus(phy.rdBurstDetSeen, 'bs_bds');
      dataValidSeenSync <= syncToBus(phy.rdDataValidSeen, 'bs_dvs');
      // Write-leveling result back to the bus clock for STATUS reg6. chWlTrained
      // / chWlDone are the sequencer WL FSM outputs (defined fabric regs, tied to
      // 0 / 1 off the writeLevel build), so this is a plain 2-flop sync, no DQS
      // X involved. The firmware contract mirrors the read-train one: read these
      // only after wlDone reads 1.
      wlTrainedSync <= syncToBus(chWlTrained, 'bs_wltr', width: 4 * laneCount);
      wlDoneSync <= syncToBus(chWlDone, 'bs_wldone');
      wlFbMapSync <= syncToBus(chWlFbMap, 'bs_wlfbmap', width: 8);
      // On-chip write-control diagnostics (WRCTL reg5) back to the bus clock.
      // The OE/DM/DAT counters come straight off the ECP5 PHY (defined fabric
      // counters over the write datapath), CMD comes from the sequencer's WRITE-
      // command counter via chWrCmdCount (driven after seq is built). Each is an
      // 8-bit MONOTONE saturating counter crossed through a plain 2-flop
      // synchronizer per field. Because the fields are multi-bit, a poll that
      // lands mid-burst can sample a count on either side of a carry (a
      // transient that never existed), the same multi-bit CDC skew the curTapSync
      // contract above handles. FIRMWARE CONTRACT: read WRCTL (reg5) only when NO
      // write burst is in flight (between bursts / after the write+read test
      // completes), so the counters are quasi-static when sampled. The ddrlevel
      // firmware reads WRCTL after the whole two-pattern sweep, satisfying this.
      // [phy] is the ECP5 PHY here (type-promoted by the DATAVALID/BURSTDET
      // syncs above, trainableRead is only ever set on the ECP5 DDR3 build).
      wrOeSync <= syncToBus(phy.wrOeCount, 'bs_wroe', width: 8);
      wrDmSync <= syncToBus(phy.wrDmCount, 'bs_wrdm', width: 8);
      wrDatSync <= syncToBus(phy.wrDatCount, 'bs_wrdat', width: 8);
      wrCapSync <= syncToBus(phy.wrCap, 'bs_wrcap', width: 32);
      wrCmdSync <= syncToBus(chWrCmdCount, 'bs_wrcmd', width: 8);
    }

    // Logic-analyzer debug taps (read-only mirrors, no datapath change):
    // dbg_wr_cap = the bus-synced loopback of what the PHY actually launches on
    // DQ each write (the period-4 [stale,good,good,stale] write pattern is
    // directly visible here), dbg_wr_oe = the OE-window assert count (its low
    // bit toggles per write, a free write strobe to delineate writes on the LA).
    // Tied to 0 on the non-trainable build (the syncs only exist with
    // trainableRead). Fanned to the la_* pads by genip's DDR la-bridge mode.
    createPort('dbg_wr_cap', PortDirection.output, width: 32);
    createPort('dbg_wr_oe', PortDirection.output, width: 8);
    output('dbg_wr_cap') <=
        (trainableRead && isEcp5Phy ? wrCapSync : Const(0, width: 32));
    output('dbg_wr_oe') <=
        (trainableRead && isEcp5Phy ? wrOeSync : Const(0, width: 8));
    // #136 CDC-wedge debug: the async bridge's 8 handshake state bits, driven from
    // the bridge below (0 when there is no bridge / no async clock).
    final dbgCdc = Logic(name: 'dbg_cdc_int', width: 8);
    createPort('dbg_cdc', PortDirection.output, width: 8);
    output('dbg_cdc') <= dbgCdc;

    final dvStb = Logic(name: 'dv_stb');
    final dvWe = Logic(name: 'dv_we');
    final dvAddr = Logic(name: 'dv_addr', width: nbAddr.width);
    final dvDataIn = Logic(name: 'dv_data_in', width: 32);
    final dvSel = Logic(name: 'dv_sel', width: 4);
    final dvAck = Logic(name: 'dv_ack');
    final dvDataOut = Logic(name: 'dv_data_out', width: 32);

    // Bus-clk readback assembly: pick control-window vs array (both DEFINED, so
    // the mux does not amplify X), then splice the DQS observability field onto
    // bits [12:8] by per-bit concatenation OUTSIDE the mux (so the unmodeled-leaf
    // X stays confined to [12:8]). The field is the 5-bit [ctrlDqsBits]
    // (DATAVALID[8], BURSTDET[9], DLL_LOCK[10], BDET_SEEN[11], DVALID_SEEN[12]),
    // so the slot MUST be 5 bits wide ([8,13)) to match its width, the high
    // remainder is [13,32). [arrayWord] is the datapath read word.
    Logic assembleReadback(Logic arrayWord) {
      if (!trainableRead) return arrayWord;
      final picked = mux(isCtrl, ctrlReadCtl, arrayWord);
      final dqs = mux(ctrlIsStatus, ctrlDqsBits, picked.getRange(8, 13));
      return [picked.getRange(13, 32), dqs, picked.getRange(0, 8)].swizzle();
    }

    if (asyncClock) {
      // ddr3Fast (Xilinx) derives BOTH the sys bus clock and the sclk datapath
      // clock from the ONE DDR MMCM, so they are phase-locked (mesochronous).
      // The small gray-counter handshake bridge wedged on that: its req/done
      // synchronizer sat at the pathological fixed phase and the payload
      // multi-cycle path sampled marginally (observed as a hung DRAM load with a
      // healthy sequencer). Cross through async gray-pointer FIFOs instead: the
      // payload is captured into FIFO storage and only read out after the write
      // pointer has safely crossed, and the depth gives the pointer sync a
      // moving target. On the ECP5 25F (area-tight, not ddr3Fast) keep the small
      // gray-counter bridge. Block-RAM FIFO storage lands later, flops for now.
      final BridgeModule bridge = ddr3Fast
          ? HarborWishboneCdcFifoBridge(
              addressWidth: nbAddr.width,
              dataWidth: 32,
              selWidth: 4,
              depth: 16,
              target: target,
              name: 'ddr_cdc',
            )
          : HarborWishboneCdcBridge(
              addressWidth: nbAddr.width,
              dataWidth: 32,
              selWidth: 4,
              // Deeper synchronizers: a continuous back-to-back fetch stream
              // corrupts otherwise (cross-domain payload sampled before it
              // settled). 6: the 64-bit two-beat read exposed exactly this.
              syncStages: 6,
              // Liveness backstop, ~100x a normal completion, only breaks a
              // permanent wedge (a frozen master never crossing a completion
              // back), never trips in normal operation.
              completionTimeout: 4096,
              name: 'ddr_cdc',
            );
      addSubModule(bridge);
      // Slave side: the narrow bus face (clk domain). Control-window accesses
      // are served locally on the bus clock (see the control block above), so
      // they are GATED OUT of the bridge (~isCtrl): only DRAM-array accesses
      // cross into the sclk datapath.
      bridge.input('s_clk').srcConnection! <= clk;
      bridge.input('s_reset').srcConnection! <= reset;
      bridge.input('s_cyc').srcConnection! <= (nbStb & ~isCtrl);
      bridge.input('s_stb').srcConnection! <= Const(1);
      bridge.input('s_we').srcConnection! <= nbWe;
      bridge.input('s_adr').srcConnection! <= nbAddr;
      bridge.input('s_dat_w').srcConnection! <= nbDataIn;
      bridge.input('s_sel').srcConnection! <= nbSel;
      // Bus-clk read/ack: control window served here, array via the bridge.
      nbDataOut <= assembleReadback(bridge.output('s_dat_r'));
      nbAck <= mux(isCtrl, ctrlAck, bridge.output('s_ack'));
      // Master side: the datapath (the PHY-exported sclk = ddr_clk/2 on ECP5).
      bridge.input('m_clk').srcConnection! <= seqClk;
      bridge.input('m_reset').srcConnection! <= seqReset;
      bridge.input('m_ack').srcConnection! <= dvAck;
      bridge.input('m_dat_r').srcConnection! <= dvDataOut;
      dvStb <= bridge.output('m_cyc') & bridge.output('m_stb');
      dvWe <= bridge.output('m_we');
      dvAddr <= bridge.output('m_adr');
      dvDataIn <= bridge.output('m_dat_w');
      dvSel <= bridge.output('m_sel');
      dbgCdc <= bridge.output('dbg'); // #136 CDC handshake state to the LA
    } else {
      // Single clock: the datapath view is the narrow bus directly. Control
      // accesses are still served on the bus clock (here == datapath clock) and
      // gated out of the datapath, so the control plane is identical in both
      // modes.
      dvStb <= (nbStb & ~isCtrl);
      dvWe <= nbWe;
      dvAddr <= nbAddr;
      dvDataIn <= nbDataIn;
      dvSel <= nbSel;
      nbAck <= mux(isCtrl, ctrlAck, dvAck);
      nbDataOut <= assembleReadback(dvDataOut);
      dbgCdc <= Const(0, width: 8); // no bridge in single-clock mode
    }

    // Bus face: latch one request, run it, ack on completion. These all run on
    // [seqClk] (the PHY-exported sclk on ECP5), not dpClk.
    final busy = Logic(name: 'ddr_busy');
    final req = Logic(name: 'ddr_req');
    final reqWe = Logic(name: 'ddr_req_we');
    final reqAddr = Logic(name: 'ddr_req_addr', width: 32);
    final reqData = Logic(name: 'ddr_req_data', width: 32);
    final reqSel = Logic(name: 'ddr_req_sel', width: 4);
    final rdWord = Logic(name: 'ddr_rd_word', width: 32);

    // Sync the firmware refresh level (reg13, bus-clk domain) into the sequencer's
    // clock with a plain 2-flop synchronizer, it changes rarely (firmware writes
    // then waits), so no handshake is needed. Only the ddr3Fast/Xilinx path has
    // the register, other paths leave tempLevel null (safe 2x default inside).
    if (xilRefreshLevel != null) {
      final r0 = Logic(name: 'refl_s0', width: 2);
      final r1 = Logic(name: 'refl_s1', width: 2);
      Sequential(
        seqClk,
        reset: seqReset,
        resetValues: {r0: Const(2, width: 2), r1: Const(2, width: 2)},
        [r0 < xilRefreshLevel, r1 < r0],
      );
      seqTempLevel = r1;
    }

    // The PHY-agnostic sequencer runs on the fabric clock (sclk on ECP5). Its
    // timing counters derive from [seqClkMhz] (half the CK rate on ECP5) so the
    // real-time JEDEC delays are preserved across the clock-rate change.
    final seq = DdrSequencer(
      seqClk,
      seqReset,
      req,
      reqWe,
      reqAddr,
      reqData,
      reqSel,
      // WL feedback bit from the PHY (lane-selected DQ during write-leveling).
      // Wired from whichever PHY is built (both expose wlFeedbackOut on the
      // writeLevel build), null otherwise ties it off inside the sequencer.
      // useWriteLevel implies isEcp5Phy || ddr3Fast, so the non-ECP5 branch is the
      // Xilinx ddr3Fast PHY.
      wlFeedback: useWriteLevel
          ? (isEcp5Phy
                ? (phy as DdrPhyEcp5).wlFeedbackOut
                : (phy as DdrPhyXilinx).wlFeedbackOut)
          : null,
      // On-die die-temperature level for dynamic refresh scaling (ddr3Fast/XADC),
      // null on other paths ties it to the safe 2x default inside the sequencer.
      tempLevel: seqTempLevel,
      config: config,
      clkMhz: seqClkMhz,
      // CK -> sequencer-tick bridge: on the sclk fabric the sequencer ticks at
      // CK/2, so CK-cycle JEDEC constants (CL/CWL/burst/tWR/...) count two CK per
      // tick, on the single-clock path it ticks at the CK rate (1:1), on the
      // ddr3Fast Xilinx path the controller ticks on ctrl83 = CK/4 while the
      // ISERDESE2/OSERDESE2 gearbox owns the CK-granular alignment (4:1). This is
      // the true CK-rate threading: with clkMhz=83 and ckCyclesPerTick=4 the
      // sequencer's ckMhz = 83*4 = 333 MHz, so DLL-on init runs and the MR/
      // CK-relative timings compute against the real DDR3-667 CK.
      ckCyclesPerTick: ddr3Fast ? 4 : (useSclkFabric ? 2 : 1),
      // DDR3-667 speed-bin CL/CWL on the ddr3Fast path, the fixed 6/6 elsewhere.
      cl: ddr3Fast ? ddr3FastCl : 6,
      cwl: ddr3Fast ? ddr3FastCwl : 6,
      mprDebug: mprDebug,
      writeLevel: useWriteLevel,
    );

    // Drive the PHY command/data channel from the sequencer (closes the cycle
    // we broke above: the PHY was built against these plain Logics).
    chCke <= seq.cke;
    chCsN <= seq.csN;
    chCmd <= seq.cmd;
    chBa <= seq.ba;
    chAddr <= seq.addr;
    chOdt <= seq.odt;
    chResetN <= seq.resetN;
    chWrStart <= seq.wrStart;
    chWrData <= seq.wrData;
    chWrMask <= seq.wrMask;
    chBeatSel <= seq.beatSel;
    chRdStart <= seq.rdStart;
    // WRITE-command diagnostic counter from the sequencer -> WRCTL reg5 / STATUS.
    // Always driven (the sequencer counter exists unconditionally). Bus-synced
    // here so the ddr3Fast xilStatus read is clean, the ECP5 WRCTL path re-syncs
    // it (redundant, harmless) through syncToBus.
    chWrCmdCount <= statusToBus(seq.wrCmdCount, 'st_wrcmd', width: 8);
    // Init-DONE witness + FSM state code into STATUS (the DRAM-alive oracle).
    // Bus-synced: these are the bits the LA proved the raw STATUS was lying about.
    chInitDone <= statusToBus(seq.initDone, 'st_initdone');
    chStateCode <= statusToBus(seq.stateCode, 'st_state', width: 4);
    // ddr3Fast DQ-drive-overlap witness from the PHY (the write pad-OE probe).
    // The 'wr_overlap_count' output only exists on the ddr3Fast read path, tie 0
    // otherwise so the STATUS field is a benign 0 on non-ddr3Fast builds.
    if (ddr3Fast) {
      chDriveOverlap <=
          statusToBus(phy.output('wr_overlap_count'), 'st_overlap', width: 8);
      chWrWord <= statusToBus(phy.output('dbg_wrword'), 'st_wrword', width: 16);
      chDataLine <=
          statusToBus(phy.output('dbg_dataline'), 'st_dataline', width: 32);
      chDqsClk <= statusToBus(phy.output('dbg_dqsclk'), 'st_dqsclk', width: 8);
      chBeats <= statusToBus(phy.output('dbg_beats'), 'st_beats', width: 8);
    } else {
      chDriveOverlap <= Const(0, width: 8);
      chWrWord <= Const(0, width: 16);
      chDataLine <= Const(0, width: 32);
      chDqsClk <= Const(0, width: 8);
      chBeats <= Const(0, width: 8);
    }
    // Write-leveling channel: drive the PHY-facing WL logics from the sequencer.
    // Off the writeLevel build these PHY inputs are tied off (the PHY was built
    // with null WL ports), so tie the channel logics to a benign default to keep
    // them driven (no undriven-net elaboration error).
    if (useWriteLevel) {
      chWlEn <= seq.wlEn;
      chWlDelayRst <= seq.wlDelayRst;
      chWlDelayInc <= seq.wlDelayInc;
      chWlStrobe <= seq.wlStrobe;
      chWlLane <= seq.wlLane;
      chWlTrained <= seq.wlTrained;
      chWlDone <= seq.wlDone;
      chWlFbMap <= seq.wlFbMap;
    } else {
      chWlEn <= Const(0);
      chWlDelayRst <= Const(0);
      chWlDelayInc <= Const(0);
      chWlStrobe <= Const(0);
      chWlLane <= Const(0, width: laneSelW);
      chWlTrained <= Const(0, width: 4 * laneCount);
      chWlDone <= Const(1);
      chWlFbMap <= Const(0, width: 8);
    }
    // Firmware WRDLY channel: driven from the sclk-synced reg7 in PART B when
    // [useWrDly], tied off otherwise so the nets stay driven (the PHY was built
    // with null WRDLY ports off the trainable build).
    if (!useWrDly) {
      chWrDly <= Const(0, width: wrDlyW);
      chWrDlyApply <= Const(0);
    }
    // Firmware WRITE-TRIM channel: tied off when not [useWriteTrim] (the PHY was
    // built with a null dyndelay port off the trim build, the Const(0) tie-off).
    if (!useWriteTrim) {
      chWrTrim <= Const(0, width: wrTrimW);
    }
    // reg10 DQ-deskew channel: tied off (broadcast) when not [usePerBitDeskew] so
    // the net stays driven (the PHY dqDeskewSelect port is null off that build).
    if (!usePerBitDeskew) {
      chDqDeskewSel <=
          Const(1 << config.dataWidth.bitLength, width: dqDeskewSelW);
    }

    // WRITE-VERIFY-RETRY state (only meaningful when [writeVerify]). vfActive
    // marks a CPU write whose read-back verify is in flight, vfPhase 0 = the
    // write burst is issued, 1 = the verify-read is issued, vfRetry is the
    // remaining retry budget. The compare masks by the write byte-enable so a
    // sub-word (sb/sh) write only checks the bytes it actually wrote.
    final vfActive = Logic(name: 'vf_active');
    final vfPhase = Logic(name: 'vf_phase');
    final vfRetryW = (writeVerifyTries + 1).bitLength;
    final vfRetry = Logic(name: 'vf_retry', width: vfRetryW);
    Logic vfByteBad(int b) =>
        reqSel[b] &
        ~reqData
            .getRange(8 * b, 8 * b + 8)
            .eq(rdWord.getRange(8 * b, 8 * b + 8));
    final vfMismatch =
        (vfByteBad(0) | vfByteBad(1) | vfByteBad(2) | vfByteBad(3)).named(
          'vf_mismatch',
        );

    // Per-transaction read-data-fresh gate. [rdWord] is a single shared register
    // updated on phy.rdValid, the sequencer's busDone is a FIXED-timing pulse that
    // can fire BEFORE this transaction's capture lands in rdWord. A 32-bit lw/sw
    // only ever consumes the downsizer's first (low) beat, so this never mattered,
    // a 64-bit ld/sd's SECOND beat (or the write-verify's verify-read) is the first
    // consumer that can ack/compare against a stale rdWord. [gotRd] marks "rdWord
    // was refreshed since this request started" (set on rdValid, cleared at each
    // fresh read the FSM launches), [doneSeen] latches the busDone pulse so the ack
    // can wait for gotRd without missing the one-cycle done. A read/verify-compare
    // only completes once BOTH the sequencer is done AND its data is in rdWord.
    final gotRd = Logic(name: 'got_rd');
    final doneSeen = Logic(name: 'done_seen');
    final opDone = (busy & (seq.busDone | doneSeen)).named('op_done');

    Sequential(seqClk, reset: seqReset, [
      dvAck < 0,
      // Control-window accesses never reach the datapath (gated out on the bus
      // clock and served there), so [dvStb] here is always a DRAM-array access.
      // ~ack keeps the ack-cycle strobe overhang from re-latching the same
      // request: the master drops stb only after it has sampled the ack.
      If(
        ~busy & ~dvAck & dvStb,
        then: [
          busy < 1,
          req < 1,
          reqWe < dvWe,
          // Fresh transaction: no read data captured yet, done not seen.
          gotRd < 0,
          doneSeen < 0,
          // Base-relative: only the span's bits address the part, so a set
          // bit of an (aligned) base can never leak into the row address.
          reqAddr <
              ((dvAddr.width > 32
                      ? dvAddr.getRange(0, 32)
                      : dvAddr.zeroExtend(32)) &
                  Const(BigInt.from(config.size - 1), width: 32)),
          reqData <
              (dvDataIn.width > 32
                  ? dvDataIn.getRange(0, 32)
                  : dvDataIn.zeroExtend(32)),
          reqSel <
              (dvSel.width > 4 ? dvSel.getRange(0, 4) : dvSel.zeroExtend(4)),
          // Arm verify for this txn only if it is a WRITE (dvWe) and verify is
          // built, reads and the verify-off build leave vfActive 0.
          if (writeVerify) ...[
            vfActive < dvWe,
            vfPhase < Const(0),
            vfRetry < Const(writeVerifyTries, width: vfRetryW),
          ],
        ],
      ),
      // The sequencer consumes the request at its IDLE state, drop the
      // strobe once it leaves IDLE (it latched everything it needs).
      If(seq.rdStart | seq.wrStart, then: [req < 0]),
      If(phy.rdValid, then: [rdWord < phy.rdData, gotRd < 1]),
      // Latch the one-cycle busDone so the completion below can wait for gotRd.
      If(busy & seq.busDone, then: [doneSeen < 1]),
      if (writeVerify)
        // A sequencer op finished. For a verify-managed write, chain the
        // write -> verify-read -> compare -> (retry | ack), a plain read acks
        // only once its captured data is in rdWord (gotRd).
        If(
          opDone,
          then: [
            If(
              vfActive,
              then: [
                If(
                  vfPhase.eq(0),
                  then: [
                    // The write burst landed (a write yields no rdValid, so gotRd is
                    // irrelevant here), re-issue the SAME address as a READ to verify
                    // (reqAddr/reqData/reqSel persist). Clear gotRd/doneSeen for it.
                    reqWe < 0,
                    req < 1,
                    vfPhase < Const(1),
                    gotRd < 0,
                    doneSeen < 0,
                  ],
                  orElse: [
                    // Verify-read done: compare ONLY when its data is in (gotRd), else
                    // wait (a busDone that beats rdValid must not compare stale rdWord).
                    If(
                      gotRd,
                      then: [
                        If(
                          vfMismatch & ~vfRetry.eq(Const(0, width: vfRetryW)),
                          then: [
                            // Stored word wrong, retries remain: re-drive the write.
                            reqWe < 1,
                            req < 1,
                            vfPhase < Const(0),
                            vfRetry < vfRetry - 1,
                            gotRd < 0,
                            doneSeen < 0,
                          ],
                          orElse: [
                            // Verified good (or retries exhausted -> best-effort): ack.
                            busy < 0,
                            dvAck < 1,
                            vfActive < 0,
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              orElse: [
                // Plain read: ack only once rdWord holds THIS transaction's capture.
                If(gotRd, then: [busy < 0, dvAck < 1]),
              ],
            ),
          ],
        )
      else
        // No write-verify: writes ack on done, reads wait for their capture.
        If(opDone & (reqWe | gotRd), then: [busy < 0, dvAck < 1]),
    ]);
    // The datapath read word is always the DRAM-array capture now: the control
    // window is served on the bus clock (above), never through the datapath.
    dvDataOut <= rdWord.zeroExtend(dvDataOut.width);

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

    // Bidirectional DQ/DQS pads.
    //
    // ECP5: the PHY OWNS the tristate buffers (Ecp5Bb) so each write-OE TSH `Q`
    // drives its pad tristate `T` directly (the nextpnr ECP5 packer rejects a
    // TSH `Q` that hops a module boundary or passes through fabric logic before
    // reaching a top-level tristate). The PHY took the inout pad nets at
    // construction and instantiated the Ecp5Bb cells against them, so there is
    // nothing to wire here: the pads are already driven/read inside the PHY.
    //
    // Xilinx: the controller owns the tristate (the directional dq_out/dq_oe
    // model), so it builds the TriStateBuffers and feeds the captured pad value
    // back into the PHY's dq_in/dqs_in.
    // ddr3Fast: the Xilinx PHY OWNS the DQ/DQS pads (the write OSERDESE2 in-site
    // tristate drives the pad IOBUF T pin directly), so there is NO fabric
    // TriStateBuffer here: the pads were passed into the PHY. Only the 48 MHz
    // Xilinx path builds the directional dq_out/dq_oe fabric tristate.
    if (!isEcp5Phy && !ddr3Fast) {
      final dqPad = inOut('sdram_dq');
      final dqDrive = TriStateBuffer(phy.dqOut, enable: phy.dqOe);
      dqPad <= dqDrive.out;
      dqIn <= dqPad;
      if (config.isDdr) {
        final dqsPad = inOut('sdram_dqs');
        final dqsDrive = TriStateBuffer(phy.dqsOut, enable: phy.dqsOe);
        dqsPad <= dqsDrive.out;
        // Received DQS strobe (reads): sample the pad into the PHY's dqs_in.
        dqsIn <= dqsPad;
        final dqsNPad = inOut('sdram_dqs_n');
        final dqsNDrive = TriStateBuffer(phy.dqsNOut, enable: phy.dqsOe);
        dqsNPad <= dqsNDrive.out;
      }
      // DDR bring-up logic-analyzer probe (env HARBOR_DDR_LA=1). A 12-bit bundle
      // of fabric nets (NO ODDR Q pad outputs, those fault nextpnr) fanned to
      // Pmod pins by genip so the LA can watch the DDR datapath during a
      // write-then-read and decouple write vs read vs address:
      //   [11:7] phy.dbg_probe = {rdActive,wrActive,windowOpen,beatHit,dqRise[0]}
      //   [6] dq_in[0]  (DRAM->FPGA read data)   [5] dqs_in[0] (read strobe)
      //   [4] dq_oe     (FPGA drives DQ = write) [3] cs_n      (command issued)
      //   [2] cmd[0]=WE (read vs write)          [1] addr[0]   [0] ba[0]
      if (Platform.environment['HARBOR_DDR_LA'] == '1' && config.isDdr) {
        createPort('dbg_la', PortDirection.output, width: 12);
        if (Platform.environment['HARBOR_DDR_LA_INIT'] == '1') {
          // INIT-WATCH bundle: see the JEDEC init sequence LIVE on the LA,
          // bypassing the (suspect, constant-0x20) STATUS-bus readout. A
          // heartbeat placed on seqClk INSIDE this controller proves the
          // sequencer clock actually toggles in the FSM's region, state_code
          // shows whether the FSM advances past sCkeWait, cke/reset_n/cs_n show
          // the DRAM command bus fire.
          final seqHb = Logic(name: 'ddr_seq_hb', width: 8);
          Sequential(seqClk, [seqHb < seqHb + 1]);
          output('dbg_la') <=
              [
                seqHb[4], // [11] seqClk heartbeat (clock alive AT the sequencer?)
                seq.initDone, // [10] init/calibration complete
                seq.stateCode, // [9:6] FSM state code (advances past 2=sCkeWait?)
                seq.cke, // [5] CKE to DRAM
                seq.resetN, // [4] DRAM reset_n (released?)
                chCsN, // [3] command issued (low)
                chCmd[0], // [2] cmd bit
                chBa[0], // [1]
                chAddr[0], // [0]
              ].swizzle();
        } else {
          output('dbg_la') <=
              [
                phy.output('dbg_probe'),
                dqIn[0],
                dqsIn[0],
                phy.dqOe,
                chCsN,
                chCmd[0],
                chAddr[0],
                chBa[0],
              ].swizzle();
        }
      }
    }

    // ddr3Fast (Arty Xilinx) LA init-watch: the dbg_la block above lives inside
    // the !ddr3Fast branch (there the fabric owns the tristate, on ddr3Fast the
    // PHY owns the pads), so it NEVER runs on the Arty path. Recreate the
    // init-watch bundle here so the LA can watch the JEDEC init live, bypassing
    // the suspect STATUS-bus readout.
    if (Platform.environment['HARBOR_DDR_LA'] == '1' &&
        Platform.environment['HARBOR_DDR_LA_INIT'] == '1' &&
        config.isDdr &&
        ddr3Fast) {
      createPort('dbg_la', PortDirection.output, width: 12);
      // SELF-DECODING init-watch bundle. The physical probe->channel order on the
      // LA is unknown, so three heartbeat taps at DISTINCT, widely-spaced divisors
      // (seqClk = 100 MHz -> 0.39 / 1.56 / 6.25 MHz) act as frequency ANCHORS: the
      // capture's per-channel transition counts identify exactly which channels
      // carry [11]/[10]/[9], and the Const 1/0 markers at [1]/[0] cross-check
      // polarity. Once the three anchors are located the whole permutation is
      // pinned, so seq.stateCode[3:0] and seq.initDone can be read off
      // UNAMBIGUOUSLY, settling the LA-vs-STATUS (sIdle vs sCkeWait) contradiction
      // without trusting any probe-order assumption.
      final seqHb = Logic(name: 'ddr_seq_hb', width: 8);
      Sequential(seqClk, [seqHb < seqHb + 1]);
      if (Platform.environment['HARBOR_DDR_LA_WR'] == '1') {
        // WRITE-TIMING bundle: the PHY dbg_wr ctrl100 markers (launch / DQ-burst /
        // DQS-burst / OE / pre+postambles) + the write command, with one heartbeat
        // anchor for the probe-order/timebase. Run under DDRTEST_HAMMER (constant
        // write bursts) so these pulse densely on the LA: the DQS-burst vs DQ-burst
        // alignment (the write-latch question) is read directly off the trace.
        final dbgWr = phy.output('dbg_wr'); // [7..0], see ddr_phy_xilinx
        output('dbg_la') <=
            [
              seqHb[3], // [11] ANCHOR seqClk/16 = 6.25 MHz (timebase)
              dbgWr[7], // [10] write LAUNCH pulse (cycle N)
              dbgWr[6], // [9]  DQ serialize burst (N+1)
              dbgWr[5], // [8]  DQ postamble (N+2)
              dbgWr[4], // [7]  DQS preamble
              dbgWr[3], // [6]  DQS burst cycle
              dbgWr[2], // [5]  DQS postamble
              dbgWr[1], // [4]  pad OE window (driven)
              dbgWr[0], // [3]  write-active envelope
              seq.csN, // [2] command strobe (low = command)
              seq.wrStart, // [1] write-start pulse
              seq.cmd[0], // [0] cmd bit0 (WE)
            ].swizzle();
      } else {
        output('dbg_la') <=
            [
              seqHb[7], // [11] ANCHOR-SLOW  seqClk/256 = 0.39 MHz
              seqHb[5], // [10] ANCHOR-MED   seqClk/64  = 1.56 MHz
              seqHb[3], // [9]  ANCHOR-FAST  seqClk/16  = 6.25 MHz
              seq.initDone, // [8] init/calibration complete
              seq.stateCode[3], // [7] FSM state code bit3
              seq.stateCode[2], // [6] FSM state code bit2
              seq.stateCode[1], // [5] FSM state code bit1
              seq.stateCode[0], // [4] FSM state code bit0
              seq.csN, // [3] command issued (low)
              seq.cke, // [2] CKE to DRAM
              Const(1), // [1] STATIC-HIGH marker (polarity + map cross-check)
              Const(0), // [0] STATIC-LOW marker
            ].swizzle();
      }
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
    // When read training is enabled the mapped span includes the control-
    // register window just above the array, so the CPU can reach it.
    reg: BusAddressRange(
      baseAddress,
      config.size + (trainableRead ? trainCtrlSize : 0),
    ),
    properties: {
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
    },
  );

  /// The usable RAM span: the array only, excluding any read-training control
  /// window folded into [dtNode]'s bus-mapping `reg`. Matches the ACPI memory
  /// view so both generators describe the same RAM.
  @override
  List<BusAddressRange> get systemMemory => [
    BusAddressRange(baseAddress, config.size),
  ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, config.size)],
    properties: {
      'compatible': [
        'harbor,sdram-controller',
        if (config.isSdr) 'harbor,sdr-sdram',
        if (config.type == HarborDdrType.ddr3 ||
            config.type == HarborDdrType.ddr3l)
          'harbor,ddr3-sdram',
      ],
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DDR',
    groupName: 'DDR',
    description: 'SDRAM memory controller',
    baseAddress: baseAddress,
    size: config.size + (trainableRead ? trainCtrlSize : 0),
  );
}
