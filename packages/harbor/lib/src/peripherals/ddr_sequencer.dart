import 'package:rohd/rohd.dart';
import 'ddr.dart';

/// DDR3 command encoding on {ras_n, cas_n, we_n} with cs_n low.
class Ddr3Cmd {
  static const int mrs = 0; // 000
  static const int refresh = 1; // 001
  static const int precharge = 2; // 010
  static const int activate = 3; // 011
  static const int write = 4; // 100
  static const int read = 5; // 101
  static const int zqcl = 6; // 110 (ras_n=1, cas_n=1, we_n=0; ZQ calibration)
  static const int nop = 7; // 111
}

/// PHY-agnostic DDR3 sequencer: JEDEC init, closed-page single-outstanding
/// transactions, BL8 with DM masking, and an auto-refresh timer. Commands leave
/// as {cke, csN, cmd[2:0]=ras/cas/we, ba, addr, odt} at one command per clock
/// (1T). The PHY translates them to pins and owns the data path timing.
///
/// The init picks DLL-off vs DLL-on from the DDR CK rate (derived as
/// [clkMhz] * [ckCyclesPerTick]). Below ~125 MHz the DRAM DLL cannot lock, so
/// the proven DLL-off init runs (CK = the system clock, no DRAM DLL). At/above
/// 125 MHz (e.g. the 144 MHz PLL'd DRAM domain) the init programs DLL-ON (MR1
/// A0=0 DLL enable, MR0 A8=1 DLL reset, tDLLK = 512 CK settle) so the DRAM DLL
/// locks and the DQSBUFM DQS-strobed read scheme works as designed. CL and CWL
/// are 6 in both modes (JEDEC-legal at 144 MHz), so only the MR DLL bits and the
/// post-MR0 settle differ. The burst-timing taps are identical.
class DdrSequencer extends Module {
  /// Cycles per microsecond at the sequencer's OWN clock (the clock this module
  /// is instantiated on). On the async ECP5 path the sequencer runs on sclk =
  /// CK/2, so the controller passes HALF the CK-rate MHz here. On the
  /// single-clock path the sequencer runs at the CK rate and this is the full
  /// CK MHz. Either way the real-time (us/ns) JEDEC helpers below stay correct,
  /// because they measure time in THIS clock's cycles.
  final int clkMhz;

  /// CK cycles per sequencer-clock tick: 1 when the sequencer runs at the DDR CK
  /// rate (single-clock path), 2 when it runs on sclk = CK/2 (async ECP5 path),
  /// 4 on the ddr3Fast Xilinx path (the sequencer/controller ticks on ctrl83 =
  /// CK/4 while the ISERDESE2/OSERDESE2 gearbox does the 4:1 CK-granular
  /// serialize). This is the explicit CK-vs-tick unit bridge: JEDEC constants
  /// quoted in CK cycles (CL, CWL, burst, tWR, tMRD, tMOD, tZQinit) are divided
  /// by this to get the sequencer-tick count via [_ckToTicks], so a CK-quoted
  /// latency spans the same REAL time no matter which clock the sequencer ticks
  /// on. At ratio 4 the CK-granular burst/CWL/CL alignment is owned by the PHY
  /// (write-launch offset + beat rotate + read window), NOT the sequencer, so
  /// the sequencer's tick-granular clTicks/burstCk only need to be
  /// over-conservative (they gate the post-burst precharge, never the data
  /// landing).
  final int ckCyclesPerTick;

  /// JEDEC CAS latency (CL) in CK cycles. DLL-off / DLL-on-at-144MHz use 6. The
  /// DDR3-667 ddr3Fast path uses 5 (the >=3000 ps tCK speed bin). Threaded from
  /// the controller so the MR0 CL field + the CK-relative read timing match the
  /// real speed grade instead of a hardcoded 6.
  final int cl;

  /// JEDEC CAS write latency (CWL) in CK cycles. 6 on the 48 MHz/144 MHz paths,
  /// 5 for DDR3-667. Sets the MR2 CWL field and (via the PHY) the write-data
  /// launch offset.
  final int cwl;

  /// Memory geometry.
  final HarborDdrConfig config;

  /// Bring-up diagnostic: leave MR3's MPR bit set after init, so every
  /// READ returns the part's predefined 0101 training pattern instead of
  /// array data (a captured word reads back 0xFFFF0000). Proves the
  /// command, init, and read-capture paths on real silicon without
  /// depending on writes.
  final bool mprDebug;

  /// Run the JEDEC DDR3 write-leveling sequence as an init phase after MR
  /// programming / ZQ and before normal operation. DDR3 (unlike DDR/DDR2)
  /// REQUIRES write-leveling: the fly-by command/address routing skews CK vs
  /// DQS per byte lane, so each lane's write DQS output delay must be trained
  /// so the DQS edge aligns to CK at the DRAM. When set, the FSM enters WL
  /// (MR1 A7=1, ODT asserted so the DRAM's RTT drives the DQ feedback), sweeps
  /// the per-lane write DQS delay from minimum stepping the DQSBUFM write
  /// pointer, samples the DQ feedback the DRAM returns (it samples CK on the
  /// DQS rising edge and drives it back on DQ), latches the delay at the
  /// feedback 0->1 transition (DQS now aligned to CK), then exits WL (MR1
  /// A7=0). Mirrors litex `sdram_write_leveling_scan` (liblitedram/sdram.c)
  /// and the JEDEC DDR3 write-leveling procedure. Off (the default) skips the
  /// phase entirely, so non-DDR3 / read-only bring-up paths are unaffected.
  final bool writeLevel;

  /// Run the MPR-based read-calibration phase (see the [readLevel] ctor param).
  final bool readLevel;

  /// Run the post-calibration write-read-compare self-test (see the ctor param).
  final bool selfTest;

  // Read-calibration control channel to the PHY (only meaningful when
  // [readLevel]). During the phase the PHY muxes its read-train controls from
  // these instead of the firmware MMIO train regs.
  /// High across the whole read-cal phase (the PHY takes its IDELAY/bitslip/
  /// window from the rd_cal_* channel while asserted).
  Logic get rdCalActive => output('rd_cal_active');

  /// Pulses to load [rdCalTap] into the [rdCalLane] IDELAYE2 (VAR_LOAD).
  Logic get rdCalIdelayLd => output('rd_cal_idelay_ld');

  /// Absolute 5-bit IDELAYE2 tap to load on [rdCalIdelayLd].
  Logic get rdCalTap => output('rd_cal_tap');

  /// Which byte lane the current tap/window/bitslip applies to.
  Logic get rdCalLane => output('rd_cal_lane');

  /// Per-lane read window (which ctrl-cycle the BL8 line captures). Latched by
  /// the PHY into [rdCalLane]'s per-lane window register while held.
  Logic get rdCalWindow => output('rd_cal_window');

  /// Pulses to advance [rdCalLane]'s ISERDESE2 bitslip by one.
  Logic get rdCalBitslip => output('rd_cal_bitslip');

  /// High once the read-cal phase has completed (locked every lane's eye centre
  /// and passed the verify). The controller gates the wishbone on this so any
  /// master inherits a verified-working read path (UberDDR3 final_calibration).
  Logic get rdCalDone => output('rd_cal_done');

  /// Read-cal observability word (STATUS reg6 on the readLevel build). Layout:
  /// [15] done, [14] reached-sRdCal, [13] watchdog-fired, [12] window-found,
  /// [11:7] final tap, [6:3] final window, [2:0] final sub-state. All held after
  /// read-cal exits so the outcome is inspectable once the bus re-opens.
  Logic get rdCalDbg => output('rd_cal_dbg');

  /// 1 = the post-cal self-test found a cadence-verified read point (see the
  /// [selfTest] ctor param). 0 = it fell back without verifying.
  Logic get selfTestPassOut => output('self_test_pass');

  /// Number of write DQS delay taps the WL sweep walks (the DQSBUFM write
  /// pointer range). litex's ECP5 PHY exposes SDRAM_PHY_DELAYS taps. The ECP5
  /// DQSBUFM write pointer is a 3-bit (8-position) pointer, so 8 is the natural
  /// full sweep. Kept a parameter so the sim test can force a transition at a
  /// known tap.
  final int wlDelayTaps;

  // Write-leveling control channel to the PHY (only meaningful when
  // [writeLevel], tied off / ignored by the PHY otherwise).
  /// High across the whole WL phase: the PHY drives DQS as an output while DQ
  /// stays an input (the WL feedback comes back on DQ), and gates the normal
  /// write/read OE windows off.
  Logic get wlEn => output('wl_en');

  /// Pulses to reset the trained write DQS delay to minimum (DQSBUFM WRLOADN,
  /// active-high pulse here, the PHY drives the active-low primitive port).
  Logic get wlDelayRst => output('wl_delay_rst');

  /// Pulses to step the write DQS delay one tap up (DQSBUFM WRMOVE).
  Logic get wlDelayInc => output('wl_delay_inc');

  /// Pulses to emit one WL DQS strobe so the DRAM samples CK and drives the
  /// feedback back on DQ (litex `ddrphy_wlevel_strobe_write`).
  Logic get wlStrobe => output('wl_strobe');

  /// Which byte lane is currently being trained (the PHY routes its DQS strobe
  /// and feedback select to this lane).
  Logic get wlLane => output('wl_lane');

  /// Packed per-lane trained write DQS delay (4 bits per byte lane). The PHY
  /// applies it to the normal write datapath (steps the DQSBUFM write pointer
  /// to the trained tap) so writes use the CK-aligned DQS.
  Logic get wlTrained => output('wl_trained');

  /// High once the write-leveling phase has completed (the sequencer has
  /// reached normal idle). The PHY gates applying the trained delay on it.
  Logic get wlDone => output('wl_done');

  /// WITNESS (diagnostic): the per-tap voted WL feedback bitmap for the LAST
  /// lane scanned. Bit `t` = the majority-voted feedback ([wlFbMaj]) sampled at
  /// write-DQS tap `t`, for taps 0..wlDelayTaps-1. This is the raw evidence the
  /// FSBL needs to tell an RTL feedback-wiring fault (map all-0 or all-1 = the
  /// feedback never flips, so the FSM can never find the 0->1 edge -> trains to
  /// tap 0) apart from a genuine training result (a 0..01..1 transition means
  /// the edge IS there). Only meaningful on the writeLevel build, 0 otherwise.
  Logic get wlFbMap => output('wl_fb_map');

  // Command channel to the PHY.
  Logic get cke => output('cke');
  Logic get csN => output('cs_n');
  Logic get cmd => output('cmd'); // {ras_n, cas_n, we_n}
  Logic get ba => output('ba');
  Logic get addr => output('addr');
  Logic get odt => output('odt');
  Logic get resetN => output('reset_n');

  // Data channel to the PHY.
  /// Pulses when a write burst's data phase should start (CWL-aligned by the
  /// PHY). The beat data/masks are valid alongside.
  Logic get wrStart => output('wr_start');
  Logic get wrData => output('wr_data'); // one bus word
  Logic get wrMask => output('wr_mask'); // byte enables for the word

  /// Which beat-pair of the BL8 burst holds the bus word (the word index
  /// within the 16-byte line, reqAddr[3:2]).
  Logic get beatSel => output('beat_sel');

  /// Pulses when a read burst was issued (PHY counts CL and captures).
  Logic get rdStart => output('rd_start');

  /// On-chip write-control diagnostic (scope substitute): a SATURATING count of
  /// how many WRITE commands this sequencer has issued since reset. Increments
  /// on the same condition that pulses [wrStart] in the issue state. Firmware
  /// reads this (via the controller WRCTL register) to tell, without a scope,
  /// whether writes are being SENT at all: CMD=0 means the sequencer never
  /// issued a WRITE command. 8-bit saturating (stops at 0xFF) so a busy loop
  /// does not wrap to a misleading low count.
  Logic get wrCmdCount => output('wr_cmd_count');

  // Bus-side handshake.
  Logic get busDone => output('bus_done');

  /// Init/calibration completion witness: HIGH once the sequencer has finished
  /// the DDR3 bring-up (power-up, reset-hold, CKE, the MR2/MR3/MR1/MR0 MRS walk,
  /// ZQCL, and any write-leveling) and reached normal operation (refresh
  /// running, ready to accept read/write bursts). Firmware reads this (via the
  /// controller STATUS register) to distinguish a real init hang from a
  /// read-capture problem: if init_done never asserts at a new clock the DRAM was
  /// never brought up. Directly analogous to the UberDDR3 DONE_CALIBRATE LED.
  Logic get initDone => output('init_done');

  /// Raw sequencer FSM state code (4-bit). Exposed so firmware can read a stuck
  /// state if [initDone] never asserts (e.g. wedged in sMrs=3 or sZq=4).
  Logic get stateCode => output('state_code');

  DdrSequencer(
    Logic clk,
    Logic reset,
    Logic req,
    Logic we,
    Logic reqAddr, // word-aligned byte address within the DDR space
    Logic reqData,
    Logic reqSel, {
    Logic? wlFeedback,
    Logic? tempLevel,
    // Per-lane read-calibration feedback from the PHY: bit[l] high when lane l's
    // currently-captured MPR read line matches the canonical alternating pattern
    // at the presently-driven window/tap/bitslip. Tied off when [readLevel] off.
    Logic? rdCalMatch,
    required this.config,
    required this.clkMhz,
    this.ckCyclesPerTick = 1,
    this.cl = 6,
    this.cwl = 6,
    this.mprDebug = false,
    this.writeLevel = false,
    this.wlDelayTaps = 8,
    // Run an MPR-based read-calibration phase after ZQ (before write-leveling):
    // per lane, sweep the read window x IDELAY tap while reading the DDR3 MPR
    // predefined 0101 pattern, lock each lane's eye-centre window/tap, then gate
    // the bus until it passes. Makes CK-based read capture reliable per-boot
    // (the fix for the marginal fixed-firmware window/tap). Off = byte-identical.
    this.readLevel = false,
    // Post-calibration self-test verify (UberDDR3 final_calibration_done idea):
    // after the read-cal sweep locks a window/tap, re-read the DDR3 MPR 0101
    // pattern at that point but at VARIED (Ferrite-like) inter-read spacing, and
    // require EVERY read to still match. This proves the capture is cadence-robust
    // (not just clean at the calibration spacing). The bus stays gated until a
    // point passes; on failure it advances the window and retries. Requires
    // [readLevel]. Off = the read-cal path is byte-identical.
    this.selfTest = false,
    super.name = 'ddr_seq',
  }) {
    assert(
      wlDelayTaps >= 1 && wlDelayTaps <= 8,
      'wlDelayTaps must be 1..8 (the ECP5 DQSBUFM write pointer is 3-bit).',
    );
    assert(
      ckCyclesPerTick == 1 || ckCyclesPerTick == 2 || ckCyclesPerTick == 4,
      'ckCyclesPerTick must be 1 (CK-rate sequencer), 2 (sclk = CK/2) or 4 '
      '(ddr3Fast ctrl83 = CK/4).',
    );
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    req = addInput('req', req);
    we = addInput('we', we);
    reqAddr = addInput('req_addr', reqAddr, width: 32);
    reqData = addInput('req_data', reqData, width: 32);
    reqSel = addInput('req_sel', reqSel, width: 4);

    // All boards capture reads at the fixed beatSel-1 burst position (A[2:0]=0),
    // so no per-read column reorder is applied.
    // WL feedback bit from the PHY (lane-0 DQ during write-leveling). Tied off
    // to 0 when WL is disabled or no feedback is wired. The FSM never samples it
    // outside the WL phase.
    final wlFb = addInput('wl_feedback', wlFeedback ?? Const(0));
    // Temperature level for dynamic refresh: 0 = cool (<85C, nominal tREFI),
    // 1 = warm (85-95C, 2x), 2 = hot (>95C, 4x). Driven by the on-die XADC/DTR
    // via the controller, defaults to 1 (2x, high-temp-safe) when not wired, so a
    // build with no temperature source still gets safe retention.
    final tempLvl = addInput(
      'temp_level',
      tempLevel ?? Const(1, width: 2),
      width: 2,
    );

    final rowBits = config.rowWidth;
    final colBits = config.colWidth;
    final baBits = (config.banks - 1).bitLength; // 8 banks -> 3
    final laneCount = config.dataWidth ~/ 8;
    final laneSelW = laneCount <= 1 ? 1 : (laneCount - 1).bitLength;

    addOutput('cke');
    addOutput('cs_n');
    addOutput('cmd', width: 3);
    addOutput('ba', width: baBits);
    addOutput('addr', width: rowBits);
    addOutput('odt');
    addOutput('reset_n');
    addOutput('wr_start');
    addOutput('wr_data', width: 32);
    addOutput('wr_mask', width: 4);
    addOutput('beat_sel', width: 2);
    addOutput('rd_start');
    addOutput('wr_cmd_count', width: 8);
    addOutput('bus_done');
    addOutput('wl_en');
    addOutput('wl_delay_rst');
    addOutput('wl_delay_inc');
    addOutput('wl_strobe');
    addOutput('wl_lane', width: laneSelW);
    addOutput('wl_trained', width: 4 * laneCount);
    addOutput('wl_done');
    addOutput('wl_fb_map', width: 8);
    addOutput('init_done');
    addOutput('state_code', width: 4);
    // Read-calibration channel to the PHY.
    addOutput('rd_cal_active');
    addOutput('rd_cal_idelay_ld');
    addOutput('rd_cal_tap', width: 5);
    addOutput('rd_cal_lane', width: laneSelW);
    addOutput('rd_cal_window', width: 4);
    addOutput('rd_cal_bitslip');
    addOutput('rd_cal_done');
    // Read-cal observability word (read via STATUS reg6): the held outcome.
    addOutput('rd_cal_dbg', width: 16);
    // Self-test outcome: 1 = a cadence-verified read point was found; 0 = the
    // self-test fell back (never verified). Sticky after the self-test exits.
    addOutput('self_test_pass');
    // Per-lane MPR match feedback from the PHY (tied off when no read-cal).
    final rdCalMatchIn = addInput(
      'rd_cal_match',
      rdCalMatch ?? Const(0, width: laneCount),
      width: laneCount,
    );

    // These count THIS sequencer's clock cycles, derived from [clkMhz] (the
    // sequencer's own clock MHz, already halved on the sclk path). They stay
    // real-time-correct on either clock with no conversion: a microsecond is a
    // microsecond regardless of clock rate.
    int us(double n) => (n * clkMhz).ceil();
    int ns(double n) => ((n * clkMhz) / 1000).ceil();
    final tPowerUp = us(200);
    final tResetHold = us(500);
    final tXpr = ns(280); // tRFC(min) + 10ns, generous for 1-2Gb parts
    final tRcd = ns(15) + 1;
    final tRp = ns(15) + 1;
    final tRfc = ns(260); // covers up to 4Gb parts
    // Nominal (cool, <=85C) JEDEC tREFI = 7.8us. DDR3 cell retention HALVES above
    // 85C, so a fixed 7.8us lets cells decay between refreshes as the part heats
    // (clean at boot, garbage minutes in). Instead of always paying 2x, the
    // interval is scaled DYNAMICALLY by [tempLvl] from the on-die temperature
    // sensor: >>0 (7.8us) cool, >>1 (3.9us, 2x) warm, >>2 (1.95us, 4x) hot. So the
    // common cool case stays full-speed and only a hot die pays the refresh tax.
    final tRefiNom = us(7.8 / 1.0) ~/ 1; // 7.8us cool baseline (fits refCount)
    final tRefiDyn = (Const(tRefiNom, width: 10) >> tempLvl).named('tRefiDyn');

    // These are quoted in DDR CK cycles. The sequencer counts in ITS OWN clock
    // ticks, which are CK ticks on the single-clock path but sclk = CK/2 ticks
    // on the async ECP5 path. [_ckToTicks] converts a CK-cycle latency into the
    // number of sequencer ticks that span the SAME real time, rounding UP so the
    // wait is never tighter than the CK spec (over-conservative is acceptable,
    // under is not). On the single-clock path ([ckCyclesPerTick] == 1) it is the
    // identity, so behavior there is byte-for-byte unchanged.
    int ckToTicks(int ckCycles) => (ckCycles / ckCyclesPerTick).ceil();

    // DLL-on vs DLL-off selection, gated on the DDR CK rate. The DRAM DLL only
    // locks above ~125 MHz (the DDRDLLA / DQSBUFM DQS-strobed read scheme is the
    // DLL-ON Lattice path), so below that we keep the proven DLL-off init and CK
    // tracks the system clock. The sequencer ticks on its own clock (sclk on the
    // async ECP5 path), so the real CK rate is [clkMhz] scaled back UP by the
    // CK/tick ratio. At/above 125 MHz the init programs DLL-ON: MR1 A0=0 (DLL
    // enable), MR0 A8=1 (DLL reset), and the post-MR0 tDLLK = 512 CK settle.
    final ckMhz = clkMhz * ckCyclesPerTick;
    final dllOn = ckMhz >= 125;

    // CL and CWL come from the controller ([cl]/[cwl], defaulting to 6). On the
    // 1:1 and 2:1 (sclk = CK/2) paths CL/CWL MUST divide evenly by the CK/tick
    // ratio: a half-tick read/write latency cannot be expressed and would
    // silently round, mis-aligning the burst. CL=6 / CWL=6 is JEDEC-legal at 144
    // MHz (tCK ~6.94 ns: CL*tCK = 41.6 ns >> tAA(min), CWL=6 >= the part
    // minimum), so the DLL-off/DLL-on-144 paths reuse the same burst-timing taps
    // and only the MR DLL bits + the tDLLK wait change. On the 4:1 ddr3Fast path
    // the CK-granular CL/CWL alignment is owned by the PHY (the ISERDESE2/
    // OSERDESE2 gearbox launches the whole BL8 in one tick and shifts the beats
    // by CWL mod 4, the read window centres on CL), so a non-multiple-of-4 CL/CWL
    // (DDR3-667 uses 5/5) is legal here and the sequencer's tick-granular
    // clTicks/burstCk only need to be over-conservative (they gate the
    // post-burst precharge, never the data landing). So the divisibility asserts
    // apply only for ratios <= 2, where the sequencer itself times the burst.
    assert(
      ckCyclesPerTick > 2 || cl % ckCyclesPerTick == 0,
      'CL ($cl CK) must divide evenly into sequencer ticks '
      '(ckCyclesPerTick=$ckCyclesPerTick) on the 1:1/2:1 paths.',
    );
    assert(
      ckCyclesPerTick > 2 || cwl % ckCyclesPerTick == 0,
      'CWL ($cwl CK) must divide evenly into sequencer ticks '
      '(ckCyclesPerTick=$ckCyclesPerTick) on the 1:1/2:1 paths.',
    );

    final tMrd = ckToTicks(4);
    final tMod = ckToTicks(12);
    final tZqInit = ckToTicks(512);
    // tDLLK: JEDEC DDR3 requires 512 CK after a DLL RESET (MR0 A8=1) before any
    // DLL-dependent op (a read, or the ZQCL the read path needs). The sZq state
    // already waits tMod + tZqInit (= 512 CK) after the final MRS write (MR0
    // issues on the sZq-entry cycle), so the DLL-reset-to-read settle is covered
    // by the same window. tDllk is named here for the DLL-on path so the
    // requirement is explicit and the wait can never be shortened below it.
    final tDllk = ckToTicks(512);
    final tWr = ckToTicks(8); // write recovery incl. CWL slack, generous
    // Post-write bus turnaround: OFF. A HW experiment holding the write ack off
    // extra ticks did NOT change the beat-duplication glitch rate, so it is not a
    // write->read turnaround gap.
    final wrTurn = ckToTicks(0);
    final burstCk = ckToTicks(4); // BL8 on a x16 part: 4 beat-pairs
    final clTicks = ckToTicks(cl);

    // tWLMRD: first DQS edge may not come before this many CK after the MR1 WL
    // enable (JEDEC min 40 CK). tWLDQSEN: DQS driven low for this long before
    // the first strobe so the DRAM's WL circuit settles (JEDEC min 25 CK). tWLO:
    // the DRAM presents the WL feedback on DQ within ~7.5ns (tWLO max) of the DQS
    // rising edge. We wait a few CK to sample comfortably after. All quoted in CK
    // and converted to sequencer ticks, so they span the same real time on either
    // clock. Held generous (over-conservative on the sclk path is fine).
    final tWlMrd = ckToTicks(40);
    final tWlDqsEn = ckToTicks(25);
    final tWlo = ckToTicks(8); // > tWLO(max) 7.5ns at the DLL-off CK

    // Feedback-propagation delay. After the DQS strobe the DRAM drives its WL
    // result (CK sampled on the DQS rising edge) onto DQ after tWLO, but that bit
    // only reaches [wlFb] AFTER the whole read-capture pipeline: DQ -> IOBUF ->
    // IDELAYE2 -> the free-running ISERDESE2 (DATA_WIDTH=8) -> ctrl83. That is ~a
    // read latency, NOT within tWLO. The old scan voted in a tWlo-tick window
    // right on the strobe, sampling pre-feedback zeros -> fbmap=0 -> the edge-find
    // never fires -> the tap parks at the fallback and garbages writes (why WL was
    // force-disabled on Xilinx). Wait this long AFTER the strobe before voting
    // (ported from UberDDR3's DELAY_BEFORE_WRITE_LEVEL_FEEDBACK = data-pipe depth
    // + tWLO+tWLOE + margin).
    final wlFbDelay = clTicks + burstCk + tWlo + 4;

    // Address slicing, generalized for the device data width. A BL8 spans
    // [dataWidth] BYTES (8 beats * dataWidth/8 B), so the low log2(dataWidth)
    // byte-address bits index WITHIN the burst: [1:0] = byte-in-32b-word, then
    // [beatSelBits] = beatSel (which 32-bit word of the burst). x16: 16 B burst,
    // 4 words, beatSel = addr[3:2]. x8: 8 B burst, 2 words, beatSel = addr[2].
    // Everything ABOVE the burst is the BL8 index, split into an 8-column-aligned
    // DDR column group (A[2:0] issued as 0 for writes), then bank, then row. For
    // dataWidth=16 this is byte-identical to the old {col=wordAddr[colBits-2:0],
    // bank, row} scheme. dataWidth=8 shifts every split down one bit (8 B burst).
    // Two modes by data width:
    //  - x16: a 16 B BL8 holds 4 words, beatSel = addr[3:2] (byte-identical to the
    //    original scheme).
    //  - x8 (x8Narrow): the DLL-off read preamble kills the beatSel-0 word (beats
    //    0-3) while beatSel-1 (beats 4-7) is ALWAYS clean, and no naive burst
    //    reorder recovered beatSel-0 (the col->captured-beat map is HW-specific and
    //    did not match A[2:0]=0/1/4). So map EVERY 32-bit word to its OWN BL8 at
    //    beatSel-1: robust, no reorder, at the cost of half the burst (64 MB
    //    usable of the 128 MB part). beatSel = const 1, BL8 index = word index.
    final x8Narrow = config.dataWidth < 16;
    final bl8ByteBits = x8Narrow
        ? 2
        : config.dataWidth.bitLength - 1; // word=BL8 (x8) / log2 (x16)
    final busBeatSel = x8Narrow
        ? Const(
            1,
            width: 2,
          ) // every word at beatSel-1 (beats 4-7, always clean)
        : reqAddr.getRange(2, bl8ByteBits).zeroExtend(2);
    final bl8Idx = reqAddr.getRange(
      bl8ByteBits,
      32,
    ); // burst index (col/bank/row)
    final colGroup = bl8Idx.getRange(0, colBits - 3); // -> DDR col[colBits-1:3]
    final bank = bl8Idx.getRange(colBits - 3, colBits - 3 + baBits);
    final row = bl8Idx
        .getRange(colBits - 3 + baBits, colBits - 3 + baBits + rowBits)
        .zeroExtend(rowBits);

    // State machine.
    final state = Logic(name: 'state', width: 4);
    const sPower = 0;
    const sResetHold = 1;
    const sCkeWait = 2;
    const sMrs = 3; // walks MR2, MR3, MR1, MR0
    const sZq = 4;
    const sIdle = 5;
    const sSelfTest =
        6; // post-cal write-read-compare verify (sub-stepped via stSub)
    const sRcd = 7; // (was a separate activate state)
    const sIssue = 8; // READ or WRITE command cycle
    const sData = 9; // burst in flight
    const sPrecharge = 10;
    const sRefresh = 11;
    // Write-leveling phase states (4-bit state, 12..15 were free). The phase
    // runs between sZq and sIdle: sZq hands off to sWlEnter when [writeLevel],
    // else straight to sIdle (the proven read path is untouched).
    const sWlEnter = 12; // MR1 A7=1 issued, settle tWLMRD, prep DQS-low
    const sWlScan = 13; // per-lane delay sweep: strobe DQS, sample DQ feedback
    const sWlExit = 14; // MR1 A7=0 issued, settle tMOD, then sIdle
    // Read-calibration phase (the one remaining 4-bit state, sub-stepped via
    // rdSub). Runs after sZq (before write-leveling): MPR read, per-lane window x
    // tap eye-scan, lock the centre, then hand off. Gated on [readLevel].
    const sRdCal = 15;

    final wait = Logic(name: 'waitCount', width: 24);
    final mrsStep = Logic(name: 'mrsStep', width: 2);
    final refCount = Logic(name: 'refCount', width: 10);
    final refDue = Logic(name: 'refDue');
    // Inter-transaction dwell: a minimum idle (in sequencer ticks) that must
    // elapse between one transaction's busDone and the sIdle acceptance of the
    // next request. Each transaction already enforces its own tRCD/tRAS/tWR/tRP,
    // but nothing gated the gap BETWEEN back-to-back transactions. Software-paced
    // access supplied it for free, so a 64-bit ld/sd (two beats issued as fast as
    // the CDC round-trip allows) put beat0's ACTIVATE/READ too soon after the
    // prior transaction and captured a stable-but-wrong word (tWTR/tRC class).
    // Raised from 16 (5-bit) to 40 (6-bit): the inter-transaction dwell is a
    // FLOOR on the read-to-read gap. Pure-data (dcache) reads are pipeline-spaced
    // well above it so they never bind. The icache-refill + dcache-load INTERLEAVE
    // (execute-from-DRAM) serializes reads back-to-back right on the floor, and 16
    // ticks was too little settling for the read capture on that tight cadence
    // (silicon: i+d reads intermittently corrupt/hang while pure data is perfect).
    const dwellTicks = 40;
    final dwell = Logic(name: 'dwell', width: 6);
    final isWrite = Logic(name: 'isWrite');
    // MPR-mode read latch (only ever set on the mprDebug bring-up path). When a
    // read is issued while MR3.MPR=1 the DRAM is in MPR mode: ACTIVATE and array
    // reads are ILLEGAL, only RD to the MPR is valid. So an MPR read must SKIP
    // the ACTIVATE (go straight to the READ) and SKIP the PRECHARGE afterwards
    // (no bank is open). This flag steers those two skips. It is always 0 when
    // mprDebug is false so the normal array path is byte-identical.
    final isMprRead = Logic(name: 'isMprRead');

    // Write-leveling working registers.
    final wlLaneReg = Logic(name: 'wlLane', width: laneSelW);
    final wlTap = Logic(name: 'wlTap', width: 4); // current delay tap 0..taps
    // Per-lane trained delay (the tap at the feedback 0->1 transition). One
    // 4-bit register per lane, packed into wl_trained for the PHY to apply.
    final wlTrainedLane = List.generate(
      laneCount,
      (l) => Logic(name: 'wlTrained_$l', width: 4),
    );
    final wlFbPrev = Logic(name: 'wlFbPrev'); // last (VOTED) feedback bit
    // 2-tap-ago feedback. DEBOUNCE: the WL used to accept the FIRST 0->1 voted
    // edge, but at 144MHz a spurious early high (tap 1/2) wins, training a too-
    // low write-DQS tap (the "one-tap-low marginal DQS" -> DQ float -> writes do
    // not land). Require the feedback to be stably 0 for TWO prior taps before
    // accepting the rising edge, so the real DQS-to-CK alignment tap is trained.
    final wlFbPrev2 = Logic(name: 'wlFbPrev2');
    final wlFound = Logic(name: 'wlFound'); // this lane's transition latched
    // WL feedback MAJORITY-VOTE accumulator. The WL feedback used to be sampled
    // ONCE at a single DQS edge: a marginal, jittery sample, so the converged
    // per-lane tap landed 0 or 1 across builds (lane1 jitter) and word0 only read
    // when lane1=1. The DQ1/5/9 float on word0 was a SYMPTOM of that one-tap-low
    // marginal DQS. Instead, accumulate the feedback over the whole settled
    // [tWlo] strobe window (sub-step 1) and decide by majority in sub-step 2, so
    // the trained tap is deterministic. 4 bits holds up to tWlo=8 votes
    // (single-clock path, tWlo=4 on the async sclk path).
    final wlFbVotes = Logic(name: 'wlFbVotes', width: 4);
    // Combinational majority: the feedback counted high on at least half the
    // settled-window ticks. Threshold derives from the SAME [tWlo] constant the
    // strobe window uses (tWlo=4 async / 8 single-clock), so it stays correct if
    // the path changes. Used in sub-step 2 in place of the single [wlFb] sample.
    final wlFbMaj = wlFbVotes.gte(Const(tWlo ~/ 2, width: 4)).named('wlFbMaj');
    // WITNESS bitmap: bit t = the voted feedback ([wlFbMaj]) at write-DQS tap t
    // for the LAST lane scanned. Recorded in sub-step 2 each tap. Read back via
    // reg6 (WL result) upper bits so the FSBL can SEE whether the feedback ever
    // flips as the write-DQS delay sweeps. All-0 / all-1 = the feedback never
    // moves (an RTL feedback-path fault, or DQS not strobing in WL mode), a
    // 0..01..1 pattern = the edge is present and training is a firmware/latch
    // question. 8 bits = the full 8-tap DQSBUFM write pointer sweep.
    final wlFbMapReg = Logic(name: 'wlFbMap', width: 8);
    // DIAGNOSTIC: sticky "wlFb was EVER high at any tick during the whole WL
    // scan" (all taps/lanes/sub-steps). Exposed as bit 7 of the wl_fb_map
    // output. 0 = the feedback truly never appears (capture/DRAM-drive dead,
    // not a sample-timing miss); 1 = feedback present somewhere (timing).
    final wlFbEver = Logic(name: 'wlFbEver');
    // On-chip WRITE-command diagnostic: a saturating count of WRITE commands
    // issued. Held across cycles (NOT reset each cycle in the FSM body), so it
    // accumulates over the whole sweep, reset to 0 at sequencer reset. Drives
    // the wr_cmd_count output for the controller's WRCTL register.
    final wrCmdCount = Logic(name: 'wrCmdCount', width: 8);
    // WL sub-step within sWlScan: 0 settle DQS-low, 1 strobe + wait feedback
    // propagation ([wlFbDelay]), 2 accumulate the majority vote, 3 decide.
    final wlSub = Logic(name: 'wlSub', width: 2);

    // Read-calibration working registers (the sRdCal phase). Per lane, sweep the
    // read window (coarse ctrl-cycle) x IDELAY tap (fine DQ-in-CK-eye) reading
    // the MPR 0101 pattern, lock the eye centre. Held (not defaulted each cycle).
    final rdSub = Logic(name: 'rdSub', width: 3); // sub-phase within sRdCal
    final rdLane = Logic(name: 'rdLane', width: laneSelW);
    final rdTap = Logic(name: 'rdTap', width: 5); // current IDELAY tap 0..31
    final rdWindow = Logic(name: 'rdWindow', width: 4); // current read window
    // Widest-CONTIGUOUS-run eye tracking. A first..last midpoint lands in a
    // FAILING gap when the passing taps split into islands; the firmware trainer
    // avoids this by centring on the widest contiguous run, and so do we.
    // [rdRunLo]/[rdRunActive] track the current contiguous run of passing taps;
    // [rdBestLo]/[rdBestHi] hold the widest run seen; [rdBestValid] = >=1 pass.
    final rdRunActive = Logic(name: 'rdRunActive'); // inside a contiguous run
    final rdRunLo = Logic(name: 'rdRunLo', width: 5); // current run's first tap
    final rdBestLo = Logic(
      name: 'rdBestLo',
      width: 5,
    ); // widest run's first tap
    final rdBestHi = Logic(name: 'rdBestHi', width: 5); // widest run's last tap
    final rdBestValid = Logic(
      name: 'rdBestValid',
    ); // >=1 tap matched this window
    final rdWinFound = Logic(name: 'rdWinFound'); // this lane's window located
    final rdDoneReg = Logic(name: 'rdDoneReg'); // latched read-cal complete
    // Watchdog: read-cal MUST terminate (the sim-clean sweep is a few thousand
    // ctrl cycles). If the unsimmable PHY path ever hangs it, this forces a safe
    // exit so the bus gate (chRdCalDone) can never wedge the boot. Reset on entry
    // to sRdCal, incremented each cycle there. Bound well above any real sweep.
    final rdWatch = Logic(name: 'rdWatch', width: 24);
    const rdWatchBound = 1 << 20; // ~1M ctrl cycles (~20 ms @ 50 MHz)
    // Observability (read via STATUS reg6 on the readLevel build): sticky flags
    // that survive read-cal exit so the outcome is inspectable AFTER the bus
    // re-opens. rdReached = the FSM entered sRdCal (rules out an init-side hang);
    // rdWatchFired = the watchdog had to abort (read-cal was hanging). The
    // held rdSub/rdWindow/rdTap show WHERE it stopped.
    final rdWatchFired = Logic(name: 'rdWatchFired');
    final rdReached = Logic(name: 'rdReached');
    // --- Self-test verify (state sSelfTest=6, runs after sRdCal when [selfTest]).
    // At the read-cal-locked window/tap, re-read the MPR 0101 pattern at VARIED
    // inter-read spacing and require EVERY read to match = the capture is cadence-
    // robust. On failure advance the window and retry; the bus stays gated until a
    // point passes (or all windows fail -> fallback open, flagged). Reuses the
    // read-cal MPR + per-lane match; the DRAM is still in MPR mode on entry. ---
    final stSub = Logic(name: 'stSub', width: 4); // self-test sub-state
    final stReadNum = Logic(
      name: 'stReadNum',
      width: 3,
    ); // which BIST read (0..stReads-1)
    final stGap = Logic(name: 'stGap', width: 6); // inter-read spacing counter
    final stRetry = Logic(
      name: 'stRetry',
      width: 4,
    ); // window-advance retries done
    final selfTestDone = Logic(
      name: 'selfTestDone',
    ); // passed OR gave up -> bus opens
    final selfTestPass = Logic(
      name: 'selfTestPass',
    ); // sticky: a clean cadence verify
    final stAllMatch = Logic(
      name: 'stAllMatch',
    ); // every read at this point matched
    const stReads = 6; // BIST reads per point, at increasing spacing
    const stMaxRetry = 8; // window advances before giving up (fallback open)
    // Read latency: cycles from rd_start to rd_cal_match being valid (same shape
    // as the sweep's rdCapDelay: CL + burst + window-depth(8) + margin).
    final stReadDelay = clTicks + burstCk + 16;
    // Per-read inter-read GAP = stReadNum * 4 (0,4,8,..20 cycles) so the BIST
    // exercises a spread of read cadences, not just the calibration spacing.
    final stGapTarget = [
      stReadNum,
      Const(0, width: 2),
    ].swizzle().zeroExtend(6).named('stGapTarget');
    // Level control outputs to the PHY, held from these registers.
    final rdWindowOut = Logic(name: 'rdWindowOut', width: 4);
    final rdTapOut = Logic(name: 'rdTapOut', width: 5);
    // The eye-centre tap = the CENTRE of the WIDEST CONTIGUOUS passing run
    // (rdBestLo..rdBestHi): (rdBestLo + rdBestHi) / 2. Add in 6 bits so the sum
    // (up to 31+31=62) does not overflow the 5-bit lanes and wrap, then halve and
    // take the low 5 bits.
    final rdEyeTap = ((rdBestLo.zeroExtend(6) + rdBestHi.zeroExtend(6)) >>> 1)
        .getRange(0, 5)
        .named('rdEyeTap');
    // Max read window to sweep (the BL8 lands within the first few ctrl cycles;
    // 8 is generous). Tap is the full 0..31 IDELAYE2 range.
    const rdWindowMax = 8;
    // The currently-swept lane's MPR match (dynamic select over the per-lane
    // match vector from the PHY).
    Logic matchNow = rdCalMatchIn[0];
    for (var l = 1; l < laneCount; l++) {
      matchNow = mux(
        rdLane.eq(Const(l, width: laneSelW)),
        rdCalMatchIn[l],
        matchNow,
      );
    }
    matchNow = matchNow.named('rdMatchNow');
    // First tap of the run the current (matching) tap belongs to: the live run's
    // start if a run is open, else this tap starts a fresh run.
    final effRunLo = mux(rdRunActive, rdRunLo, rdTap).named('rdEffRunLo');
    // Cycles from rd_start to rd_cal_match being valid: CL landing tap + the
    // window sweep depth + capture/assemble slack. Generous (init-time only).
    final rdCapDelay = clTicks + burstCk + rdWindowMax + 6;
    // Advance to the next lane's window sweep, or to the exit (rdSub 4) after the
    // last lane. Built fresh per call (ROHD conditionals are single-use).
    List<Conditional> rdAdvanceLane() => [
      If(
        rdLane.lt(Const(laneCount - 1, width: laneSelW)),
        then: [
          rdLane < rdLane + 1,
          rdWindow < 0,
          rdTap < 0,
          rdRunActive < 0,
          rdBestValid < 0,
          rdWinFound < 0,
          rdSub < 1,
          wait < 0,
        ],
        orElse: [rdSub < 4, wait < 0],
      ),
    ];

    // Mode registers. MR0 = A1A0=00 (BL8), the CL field, A8=1 (DLL RESET),
    // A11A10A9=010 (WR=6, tWR=15ns@333MHz or the 48MHz equivalent -> A10, 0x400).
    // A8=1 (DLL reset) is harmless in DLL-off (the DLL is then disabled by MR1
    // A0) and REQUIRED in DLL-on. JEDEC MR0 CL encoding (UberDDR3 layout): the
    // field value is (CL-4)*2, whose bits[3:1] land at A6:A4 and bit[0] at A2. So
    // CL=6 -> (2)*2=4=0b0100 -> A5=1 (0x20) => 0x520. CL=5 -> (1)*2=2=0b0010 ->
    // A4=1 (0x10) => 0x510 (the DDR3-667 speed bin). MR2 A5A4A3 = CWL-5 (0 for
    // CWL=5, 001 for CWL=6). MR3 zeros (or MPR bit for the diagnostic).
    final clField = (cl - 4) * 2; // JEDEC (CL-4)*2, 4 bits {A6,A5,A4,A2-lsb}
    final mr0Val =
        0x0400 | // WR=6 (A10)
        0x0100 | // DLL RESET (A8)
        (((clField >> 1) & 0x7) << 4) | // A6:A4 = clField[3:1]
        ((clField & 0x1) << 2); // A2 = clField[0]
    final mr0 = Const(
      mr0Val,
      width: rowBits,
    ); // CL from [cl], BL8, WR=6, DLL rst
    // MR1: A0 is the DLL enable bit (A0=1 = DLL DISABLE, A0=0 = DLL ENABLE). The
    // DLL-off base set A0=1, the DLL-on base clears A0 and carries RTT_Nom=RZQ/4
    // (60 ohm) so the part's on-die termination is active for the DQS-strobed
    // read/write path. JEDEC MR1 RTT_Nom = {A9,A6,A2}: RZQ/4 (60 ohm) = 0b001 =
    // A2 = 0x04 (NOT A6=0x40, which is RZQ/2 = 120 ohm. The old value was wrong
    // and inconsistent with MR2 RTT_WR=RZQ/4). DLL-off ALSO enables it. The
    // OrangeCrab DLL-off WRITE
    // eye was marginal (transition-dependent, 1s-worse errors) because the FPGA
    // drove DQ into an UNTERMINATED DRAM input -> reflections/ISI. RTT_Nom (with
    // ODT asserted in normal ops, below) terminates the write. The DRAM auto-
    // disables RTT_Nom during its own reads, so the clean read path is untouched.
    final mr1Base = dllOn ? 0x0004 : 0x0005;
    final mr1 = Const(mr1Base, width: rowBits);
    // MR1 with write-leveling enabled (A7=1, DDRX_MR_WRLVL_BIT per
    // litedram/init.py) plus RTT_Nom active so the DRAM's ODT drives the DQ
    // feedback during WL. RTT_Nom=RZQ/4 (60ohm) = A2 = 0x04. So MR1(WL) =
    // base | A7 | A2 (A2 already in the base, re-OR'd is idempotent).
    final mr1WlOn = mr1Base | 0x80 | 0x04;
    final mr1Wl = Const(mr1WlOn, width: rowBits);
    // MR2 CWL field A5:A3 = CWL-5. Comes from the [cwl] parameter (6 on the
    // 48/144 MHz paths, 5 for DDR3-667).
    final ddrCwl = cwl;
    // + RTT_WR = RZQ/4 (A9=1, 0x200): DDR3 DYNAMIC write ODT, engaged during the
    // write burst when ODT is asserted. Belt-and-suspenders with RTT_Nom for the
    // marginal DLL-off write eye (was 0 = dynamic ODT off).
    final mr2 = Const(
      ((ddrCwl - 5) << 3) | 0x200,
      width: rowBits,
    ); // CWL + RTT_WR
    final mr3 = Const(mprDebug ? 0x0004 : 0x0000, width: rowBits);

    Logic cmdConst(int c) => Const(c, width: 3);

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: Const(sPower, width: 4),
        wait: Const(0, width: 24),
        cke: Const(0),
        resetN: Const(0),
        csN: Const(1),
        cmd: cmdConst(Ddr3Cmd.nop),
        wrCmdCount: Const(0, width: 8),
        isMprRead: Const(0),
        dwell: Const(0, width: 6),
        if (writeLevel) wlFbMapReg: Const(0, width: 8),
      },
      [
        // Refresh interval timer runs whenever initialized.
        If(
          state.gte(Const(sIdle, width: 4)),
          then: [
            refCount < refCount + 1,
            If(
              // gte (not eq): tRefiDyn shrinks when the die heats, so a level
              // change must never let refCount step past the new threshold
              // without firing.
              refCount.gte(tRefiDyn),
              then: [refDue < 1, refCount < 0],
            ),
          ],
        ),
        // Inter-transaction dwell countdown (see [dwell] above).
        If(dwell.gt(Const(0, width: 6)), then: [dwell < dwell - 1]),

        // Default command each cycle: deselect.
        csN < 1,
        cmd < cmdConst(Ddr3Cmd.nop),
        wrStart < 0,
        rdStart < 0,
        busDone < 0,
        // WL control pulses default low (one-cycle pulses asserted in the WL
        // states only), wl_en/wl_lane are level outputs driven below.
        wlDelayRst < 0,
        wlDelayInc < 0,
        wlStrobe < 0,
        // Read-cal pulses default low (asserted for one cycle in sRdCal only).
        if (readLevel) rdCalIdelayLd < 0,
        if (readLevel) rdCalBitslip < 0,

        Case(state, [
          CaseItem(Const(sPower, width: 4), [
            resetN < 0,
            cke < 0,
            wait < wait + 1,
            If(
              wait.eq(Const(tPowerUp, width: 24)),
              then: [state < sResetHold, wait < 0, resetN < 1],
            ),
          ]),
          CaseItem(Const(sResetHold, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tResetHold, width: 24)),
              then: [state < sCkeWait, wait < 0, cke < 1],
            ),
          ]),
          CaseItem(Const(sCkeWait, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tXpr, width: 24)),
              then: [state < sMrs, wait < 0, mrsStep < 0],
            ),
          ]),
          CaseItem(Const(sMrs, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tMrd + tMod, width: 24)),
              then: [
                wait < 0,
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.mrs),
                // MRS order: MR2, MR3, MR1, MR0
                ba <
                    mux(
                      mrsStep.eq(Const(0, width: 2)),
                      Const(2, width: baBits),
                      mux(
                        mrsStep.eq(Const(1, width: 2)),
                        Const(3, width: baBits),
                        mux(
                          mrsStep.eq(Const(2, width: 2)),
                          Const(1, width: baBits),
                          Const(0, width: baBits),
                        ),
                      ),
                    ),
                addr <
                    mux(
                      mrsStep.eq(Const(0, width: 2)),
                      mr2,
                      mux(
                        mrsStep.eq(Const(1, width: 2)),
                        mr3,
                        mux(mrsStep.eq(Const(2, width: 2)), mr1, mr0),
                      ),
                    ),
                mrsStep < mrsStep + 1,
                If(
                  mrsStep.eq(Const(3, width: 2)),
                  then: [state < sZq, wait < 0],
                ),
              ],
            ),
          ]),
          CaseItem(Const(sZq, width: 4), [
            // ZQCL waits out tMOD after the final MRS (the sMrs state hands
            // off the same cycle MR0 issues), then needs tZQinit before any
            // other command. In DLL-on the post-MR0 DLL RESET also needs tDLLK =
            // 512 CK before any DLL-dependent (read/ZQ) op, tDllk == tZqInit here
            // so the same window satisfies both, but take the max so a future
            // change to either can never shorten the DLL-on settle below tDLLK.
            If(
              wait.eq(Const(tMod, width: 24)),
              then: [
                csN < 0,
                // ZQCL = ras_n=1, cas_n=1, we_n=0 (opcode 6) with A10=1 (long
                // calibration). Was wrongly a PRECHARGE (opcode 2) so ZQ
                // calibration never ran and the DRAM output-driver/ODT impedance
                // stayed uncalibrated. JEDEC init requires ZQCL here.
                cmd < cmdConst(Ddr3Cmd.zqcl),
                addr < (Const(1, width: rowBits) << 10),
              ],
            ),
            wait < wait + 1,
            If(
              wait.eq(
                Const(tMod + (tZqInit > tDllk ? tZqInit : tDllk), width: 24),
              ),
              then: [
                wait < 0,
                // After init: enter read-calibration first (MPR-based read
                // eye-scan) when [readLevel], then write-leveling if enabled,
                // else straight to idle (the proven path byte-for-byte unchanged).
                if (readLevel) ...[
                  state < sRdCal,
                  rdSub < 0,
                  rdLane < 0,
                  rdWindow < 0,
                  rdTap < 0,
                  rdRunActive < 0,
                  rdBestValid < 0,
                  rdWinFound < 0,
                  rdDoneReg < 0,
                  rdWatch < 0, // arm the read-cal watchdog
                  rdReached < 1, // sticky: FSM entered read-cal (observability)
                  // Enter MPR mode: MR3 with MPR_EN (A2=1) = 0x0004.
                  csN < 0,
                  cmd < cmdConst(Ddr3Cmd.mrs),
                  ba < Const(3, width: baBits),
                  addr < Const(0x0004, width: rowBits),
                ] else if (writeLevel) ...[
                  state < sWlEnter,
                  // Issue MR1 with A7=1 to put the DRAM in write-leveling mode.
                  // ODT is asserted (wlEn drives it below) so RTT_Nom drives the
                  // DQ feedback. This MRS rides the same cs/cmd path as init.
                  csN < 0,
                  cmd < cmdConst(Ddr3Cmd.mrs),
                  ba < Const(1, width: baBits), // MR1
                  addr < mr1Wl,
                  wlLaneReg < 0,
                  wlTap < 0,
                  wlSub < 0,
                  wlFound < 0,
                  wlFbPrev < 0,
                  wlFbPrev2 < 0,
                  // DIAGNOSTIC: clear the feedback WAVEFORM accumulator at WL
                  // entry so it OR-accumulates over the whole sweep.
                  wlFbMapReg < 0,
                  wlFbEver < 0,
                ] else
                  state < sIdle,
              ],
            ),
          ]),
          // MPR-based read-calibration phase (compile-time gated on [readLevel]).
          // Per lane, sweep read window x IDELAY tap reading the DRAM MPR 0101
          // pattern; the PHY reports rd_cal_match when the captured line is the
          // canonical alternating pattern. Lock each lane's eye-centre tap at its
          // located window, then exit MPR mode and gate the bus on rd_cal_done.
          if (readLevel)
            CaseItem(Const(sRdCal, width: 4), [
              wait < wait + 1,
              rdWatch < rdWatch + 1,
              Case(rdSub, [
                // Sub 0: MR3-MPR=1 (issued at sZq exit) settle tMOD, begin sweep.
                CaseItem(Const(0, width: 3), [
                  If(
                    wait.eq(Const(tMod, width: 24)),
                    then: [rdSub < 1, wait < 0],
                  ),
                ]),
                // Sub 1: drive lane/window and LOAD the current IDELAY tap.
                CaseItem(Const(1, width: 3), [
                  rdWindowOut < rdWindow,
                  rdTapOut < rdTap,
                  rdCalIdelayLd < 1, // load rdTap into rdLane's IDELAYE2
                  If(wait.eq(Const(4, width: 24)), then: [rdSub < 2, wait < 0]),
                ]),
                // Sub 2: issue the MPR READ, wait the capture latency.
                CaseItem(Const(2, width: 3), [
                  If(
                    wait.eq(Const(0, width: 24)),
                    then: [
                      csN < 0,
                      cmd < cmdConst(Ddr3Cmd.read),
                      ba < Const(0, width: baBits),
                      addr < Const(0, width: rowBits), // MPR page0 column
                      beatSel < Const(0, width: 2),
                      rdStart < 1,
                      isMprRead < 1,
                    ],
                  ),
                  If(
                    wait.eq(Const(rdCapDelay, width: 24)),
                    then: [rdSub < 3, wait < 0],
                  ),
                ]),
                // Sub 3: evaluate this lane's match and advance the sweep.
                CaseItem(Const(3, width: 3), [
                  If(
                    matchNow,
                    then: [
                      // Extend (or start) the current contiguous run, and keep the
                      // widest run seen so far ([rdBestLo]..[rdBestHi]).
                      rdRunLo < effRunLo,
                      rdRunActive < 1,
                      If(
                        ~rdBestValid |
                            (rdTap - effRunLo).gte(rdBestHi - rdBestLo),
                        then: [
                          rdBestLo < effRunLo,
                          rdBestHi < rdTap,
                          rdBestValid < 1,
                        ],
                      ),
                    ],
                    orElse: [rdRunActive < 0], // a miss closes the run
                  ),
                  If(
                    rdTap.lt(Const(31, width: 5)),
                    then: [rdTap < rdTap + 1, rdSub < 1, wait < 0],
                    orElse: [
                      // tap sweep done at this window
                      If(
                        rdBestValid,
                        then: [
                          // window found: lock the eye-centre tap, next lane
                          rdTapOut < rdEyeTap,
                          rdCalIdelayLd < 1,
                          rdWinFound < 1,
                          ...rdAdvanceLane(),
                        ],
                        orElse: [
                          If(
                            rdWindow.lt(Const(rdWindowMax - 1, width: 4)),
                            then: [
                              rdWindow < rdWindow + 1,
                              rdTap < 0,
                              rdRunActive < 0,
                              rdBestValid < 0,
                              rdSub < 1,
                              wait < 0,
                            ],
                            orElse: [
                              // No window matched: fall back to tap 0 = the
                              // UNCALIBRATED power-up delay the firmware-trained
                              // (readLevel-off) build boots on, so a cal that
                              // finds nothing is never WORSE than no cal. (A mid
                              // tap here was worse than 0 and corrupted the FSBL's
                              // first DRAM read.) Then advance to the next lane.
                              rdTapOut < Const(0, width: 5),
                              rdCalIdelayLd < 1,
                              ...rdAdvanceLane(),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),
                // Sub 4: exit MPR mode (MR3 MPR=0).
                CaseItem(Const(4, width: 3), [
                  csN < 0,
                  cmd < cmdConst(Ddr3Cmd.mrs),
                  ba < Const(3, width: baBits),
                  addr < Const(0, width: rowBits),
                  rdSub < 5,
                  wait < 0,
                ]),
                // Sub 5: settle tMOD, then either hand to the self-test verify
                // (which re-enters MPR and cadence-stresses the locked point) or,
                // without self-test, mark done and open the bus directly.
                CaseItem(Const(5, width: 3), [
                  If(
                    wait.eq(Const(tMod, width: 24)),
                    then: [
                      if (selfTest) ...[
                        state < sSelfTest,
                        stSub < 0,
                        stReadNum < 0,
                        stAllMatch < 1,
                        stRetry < 0,
                        stGap < 0,
                      ] else ...[
                        rdDoneReg < 1,
                        state < sIdle,
                      ],
                      wait < 0,
                    ],
                  ),
                ]),
              ]),
              // Watchdog escape (placed AFTER the sub-Case so it wins): if read-
              // cal has not finished by the bound, load tap 0 (the uncalibrated
              // firmware-boot delay, never worse than no cal) and force-open the
              // bus (bypassing the self-test since read-cal itself failed). Boot
              // can never wedge on an unsimmable read-cal hang.
              If(
                rdWatch.gt(Const(rdWatchBound, width: 24)),
                then: [
                  rdTapOut < Const(0, width: 5),
                  rdWindowOut < Const(2, width: 4),
                  if (readLevel) rdCalIdelayLd < 1,
                  (selfTest ? selfTestDone : rdDoneReg) < 1,
                  rdWatchFired <
                      1, // sticky: read-cal was hanging (observability)
                  state < sIdle,
                ],
              ),
            ]),
          // Self-test verify (sSelfTest): re-enter MPR, then re-read the 0101
          // pattern at the read-cal-locked window/tap [stReads] times at
          // INCREASING inter-read spacing (0,4,..20 cycles) and require every read
          // to match. All match => the capture is cadence-robust => open the bus.
          // Any miss => advance the window + retry; after stMaxRetry, fallback-open
          // (flagged). Compile-time gated on [selfTest]; the read-cal path is
          // byte-identical off it.
          if (selfTest)
            CaseItem(Const(sSelfTest, width: 4), [
              wait < wait + 1,
              Case(stSub, [
                // sub0: re-enter MPR mode (MR3 A2=1 = 0x0004), settle tMOD.
                CaseItem(Const(0, width: 4), [
                  If(
                    wait.eq(Const(0, width: 24)),
                    then: [
                      csN < 0,
                      cmd < cmdConst(Ddr3Cmd.mrs),
                      ba < Const(3, width: baBits),
                      addr < Const(0x0004, width: rowBits),
                    ],
                  ),
                  If(
                    wait.eq(Const(tMod, width: 24)),
                    then: [stSub < 1, wait < 0],
                  ),
                ]),
                // sub1: reload the locked IDELAY tap, brief settle.
                CaseItem(Const(1, width: 4), [
                  rdCalIdelayLd < 1,
                  If(wait.eq(Const(4, width: 24)), then: [stSub < 2, wait < 0]),
                ]),
                // sub2: issue an MPR read at the locked point.
                CaseItem(Const(2, width: 4), [
                  If(
                    wait.eq(Const(0, width: 24)),
                    then: [
                      csN < 0,
                      cmd < cmdConst(Ddr3Cmd.read),
                      ba < Const(0, width: baBits),
                      addr < Const(0, width: rowBits),
                      beatSel < Const(0, width: 2),
                      rdStart < 1,
                      isMprRead < 1,
                    ],
                  ),
                  If(
                    wait.eq(Const(stReadDelay, width: 24)),
                    then: [stSub < 3, wait < 0],
                  ),
                ]),
                // sub3: sample the match; accumulate; advance the BIST or evaluate.
                CaseItem(Const(3, width: 4), [
                  If(~matchNow, then: [stAllMatch < 0]),
                  If(
                    stReadNum.lt(Const(stReads - 1, width: 3)),
                    then: [
                      stReadNum < stReadNum + 1,
                      stGap < 0,
                      stSub < 4,
                      wait < 0,
                    ],
                    orElse: [stSub < 5, wait < 0],
                  ),
                ]),
                // sub4: inter-read GAP (= stReadNum*4 cycles) then the next read.
                CaseItem(Const(4, width: 4), [
                  stGap < stGap + 1,
                  If(stGap.gte(stGapTarget), then: [stSub < 2, wait < 0]),
                ]),
                // sub5: all reads done. All matched -> exit MPR + mark verified;
                // else advance the window + retry, or fallback after stMaxRetry.
                CaseItem(Const(5, width: 4), [
                  If(
                    stAllMatch,
                    then: [
                      csN < 0,
                      cmd < cmdConst(Ddr3Cmd.mrs),
                      ba < Const(3, width: baBits),
                      addr < Const(0, width: rowBits), // MR3 A2=0 exit MPR
                      selfTestPass < 1,
                      stSub < 6,
                      wait < 0,
                    ],
                    orElse: [
                      If(
                        stRetry.lt(Const(stMaxRetry, width: 4)),
                        then: [
                          stRetry < stRetry + 1,
                          rdWindowOut <
                              mux(
                                rdWindowOut.lt(
                                  Const(rdWindowMax - 1, width: 4),
                                ),
                                rdWindowOut + 1,
                                Const(0, width: 4),
                              ),
                          rdCalIdelayLd < 1,
                          stReadNum < 0,
                          stAllMatch < 1,
                          stGap < 0,
                          stSub < 2,
                          wait < 0,
                        ],
                        orElse: [
                          csN < 0,
                          cmd < cmdConst(Ddr3Cmd.mrs),
                          ba < Const(3, width: baBits),
                          addr < Const(0, width: rowBits), // exit MPR, fallback
                          stSub < 6,
                          wait < 0,
                        ],
                      ),
                    ],
                  ),
                ]),
                // sub6: settle tMOD after MPR exit, clear isMprRead, open the bus.
                CaseItem(Const(6, width: 4), [
                  If(
                    wait.eq(Const(tMod, width: 24)),
                    then: [
                      isMprRead < 0,
                      selfTestDone < 1,
                      state < sIdle,
                      wait < 0,
                    ],
                  ),
                ]),
              ]),
            ]),
          // JEDEC DDR3 write-leveling phase (litex sdram_write_leveling_scan).
          // Compile-time gated on [writeLevel]: creek (DLL-off, no WL) never
          // enters these states, so building them is dead logic that yosys keeps
          // (the state reg could hold sWl*). Excluding them frees the WL FSM +
          // per-lane feedback/vote/delay registers from the fit.
          if (writeLevel) ...[
            // sWlEnter: MR1 A7=1 already issued by the sZq exit. Settle tWLMRD
            // (>= 40 CK before the first DQS edge) then tWLDQSEN (DQS held low so
            // the DRAM WL circuit settles). Reset the first lane's write DQS delay
            // to minimum (DQSBUFM WRLOADN) at entry. Then drop into the scan.
            CaseItem(Const(sWlEnter, width: 4), [
              wait < wait + 1,
              // Pulse the per-lane delay reset once, early, after MR1 settle.
              If(wait.eq(Const(tWlMrd, width: 24)), then: [wlDelayRst < 1]),
              If(
                wait.eq(Const(tWlMrd + tWlDqsEn, width: 24)),
                then: [state < sWlScan, wait < 0, wlSub < 0],
              ),
            ]),
            // sWlScan: per (lane, tap) sweep. Sub-step 0 settles, sub-step 1
            // strobes DQS (the DRAM samples CK on the DQS rising edge), sub-step 2
            // samples the DQ feedback the DRAM drives back. The trained delay is
            // the tap where the feedback transitions 0->1 (DQS now aligned to CK).
            // On a 0->1 edge latch the tap into this lane's wlTrained field and
            // advance to the next lane (re-resetting its delay). If no transition
            // is found across all taps, latch the last tap (a bounded fallback so
            // the phase always terminates and never hangs).
            CaseItem(Const(sWlScan, width: 4), [
              wait < wait + 1,
              // DIAGNOSTIC: latch if wlFb is EVER high anywhere in the whole scan
              // (any tick, sub-step, tap, lane). Distinguishes feedback-dead from
              // sample-mistimed.
              If(wlFb, then: [wlFbEver < 1]),
              Case(wlSub, [
                // Sub 0: settle (DQS held low), move to strobe. CLEAR the vote
                // accumulator so sub-step 1 counts only this tap's settled window.
                CaseItem(Const(0, width: 2), [
                  If(
                    wait.eq(Const(tWlo, width: 24)),
                    then: [wlSub < 1, wait < 0, wlFbVotes < 0],
                  ),
                ]),
                // Sub 1: emit the WL DQS strobe and WAIT [wlFbDelay] for the DRAM's
                // feedback to propagate all the way through the read-capture
                // pipeline to [wlFb] (DQ->IOBUF->IDELAY->ISERDES->ctrl83). NO voting
                // here: sampling before the feedback arrives is the fbmap=0 bug.
                CaseItem(Const(1, width: 2), [
                  wlStrobe < 1,
                  // DIAGNOSTIC WAVEFORM: OR-accumulate wlFb at ticks 1..8 after
                  // the strobe into [wlFbMapReg] (reused as an 8-tick feedback
                  // waveform, not per-tap). Reveals WHERE the DRAM's WL feedback
                  // pulse lands relative to the fixed [wlFbDelay] sample point,
                  // across all strobes/lanes. bit b = wlFb seen at tick (b+1).
                  // All-0 => feedback never appears in that window (capture/DRAM
                  // dead); non-zero => feedback present but the fixed sample is
                  // mis-timed (adjust wlFbDelay by the offset).
                  If(
                    wait.gte(Const(1, width: 24)) &
                        wait.lte(Const(8, width: 24)) &
                        wlFb,
                    then: [
                      wlFbMapReg <
                          wlFbMapReg |
                              (Const(1, width: 8) << (wait - 1).getRange(0, 3)),
                    ],
                  ),
                  If(
                    wait.eq(Const(wlFbDelay, width: 24)),
                    then: [wlSub < 2, wait < 0, wlFbVotes < 0],
                  ),
                ]),
                // Sub 2: the feedback has now settled on [wlFb]. Keep the strobe
                // asserted and ACCUMULATE the majority vote across a tWlo-tick
                // window. The count is decided in sub-step 3.
                CaseItem(Const(2, width: 2), [
                  wlStrobe < 1,
                  If(wlFb, then: [wlFbVotes < wlFbVotes + 1]),
                  If(
                    wait.eq(Const(tWlo, width: 24)),
                    then: [wlSub < 3, wait < 0],
                  ),
                ]),
                // Sub 3: decide the voted feedback bit. Detect the 0->1 transition.
                // [wlTap].neq(0) gate: at tap 0 [wlFbPrev] still holds its reset
                // value (0), NOT a real prior sample, so `wlFb & ~wlFbPrev` would
                // FALSE-trigger at tap 0 whenever the feedback already reads 1 at
                // the minimum write-DQS delay (DQS starting past the CK crossing,
                // or a high feedback level). That mis-trained the delay to tap 0
                // (observed on silicon: wlTrained=0, write DQS undelayed, writes
                // never latched). Tap 0 now only ESTABLISHES the baseline into
                // [wlFbPrev]. The first genuine 0->1 edge is detected from tap 1+,
                // which also correctly handles a feedback that starts high (sweep
                // through the falling edge to the next real rising edge).
                CaseItem(Const(3, width: 2), [
                  // MAJORITY vote ([wlFbMaj], combinational, declared above): the
                  // feedback counted high on >= half the settled-window ticks. This
                  // replaces the single marginal sample with a deterministic voted
                  // value. The edge logic + the tap-0 baseline guard are otherwise
                  // UNCHANGED (only wlFb -> wlFbMaj).
                  wlFbPrev2 < wlFbPrev,
                  wlFbPrev < wlFbMaj,
                  // (Per-tap witness moved: wlFbMapReg is now the ticks-1..8
                  // feedback WAVEFORM accumulated in sub-step 1, see above.)
                  If(
                    // Accept the 0->1 edge from tap 1 (neq 0), NOT tap 2 (gt 1).
                    // HW (fbmap=000000FE): with the WL feedback path fixed, the
                    // real CK-DQS crossing on this silicon is at tap 1 (feedback
                    // low ONLY at tap 0, high at 1..7). The old `wlTap.gt(1)` gate
                    // forced the earliest acceptable edge to tap 2, so a genuine
                    // tap-1 crossing was rejected and WL fell through to tap 0
                    // (uncentered write). The 2-tap-stably-low debounce
                    // (~wlFbPrev & ~wlFbPrev2) ALREADY rejects a feedback that
                    // starts high (wlFbPrev would be high at tap 1), so gating on
                    // neq(0) is sufficient: tap 0 establishes the baseline, the
                    // first true rising edge (from tap 1) trains the lane.
                    ~wlFound &
                        wlFbMaj &
                        ~wlFbPrev &
                        ~wlFbPrev2 &
                        wlTap.neq(Const(0, width: 4)),
                    then: [
                      // 0->1 transition: this tap aligns DQS to CK for this lane.
                      // Latch the tap into THIS lane's 4-bit wlTrained field. Lane
                      // is dynamic, so write the field whose index matches
                      // wlLaneReg (a small per-lane select, laneCount is 1 or 2).
                      wlFound < 1,
                      for (var l = 0; l < laneCount; l++)
                        If(
                          wlLaneReg.eq(Const(l, width: laneSelW)),
                          then: [wlTrainedLane[l] < wlTap],
                        ),
                    ],
                  ),
                  // Advance the tap (or finish the lane).
                  If(
                    wlTap.eq(Const(wlDelayTaps - 1, width: 4)) | wlFound,
                    then: [
                      // Lane done (found a transition or exhausted the sweep).
                      // Advance to the next lane, or exit WL after the last lane.
                      If(
                        wlLaneReg.eq(Const(laneCount - 1, width: laneSelW)),
                        then: [
                          state < sWlExit,
                          wait < 0,
                          // Issue MR1 with A7=0 to leave write-leveling mode.
                          csN < 0,
                          cmd < cmdConst(Ddr3Cmd.mrs),
                          ba < Const(1, width: baBits),
                          addr < mr1,
                        ],
                        orElse: [
                          wlLaneReg < wlLaneReg + 1,
                          wlTap < 0,
                          wlSub < 0,
                          wlFound < 0,
                          wlFbPrev < 0,
                          wlFbPrev2 < 0,
                          wait < 0,
                          wlDelayRst < 1, // reset the next lane's delay to min
                        ],
                      ),
                    ],
                    orElse: [
                      // Step the write DQS delay one tap and rescan.
                      wlTap < wlTap + 1,
                      wlDelayInc < 1,
                      wlSub < 0,
                      wait < 0,
                    ],
                  ),
                ]),
              ]),
            ]),
            // sWlExit: MR1 A7=0 issued at scan completion. Settle tMOD then go
            // to normal idle. Normal writes now use the trained per-lane delay.
            CaseItem(Const(sWlExit, width: 4), [
              wait < wait + 1,
              If(
                wait.eq(Const(tMod, width: 24)),
                then: [state < sIdle, wait < 0],
              ),
            ]),
          ], // end if (writeLevel)
          CaseItem(Const(sIdle, width: 4), [
            If(
              refDue,
              then: [
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.refresh),
                refDue < 0,
                state < sRefresh,
                wait < 0,
              ],
              orElse: [
                // Gate acceptance on the inter-transaction dwell so a new ACTIVATE
                // never follows the previous transaction's busDone too soon.
                If(
                  req & dwell.eq(Const(0, width: 6)),
                  then: [
                    isWrite < we,
                    // MPR read = mprDebug build AND this request is a read. The
                    // DRAM is in MPR mode (MR3.MPR=1), so ACTIVATE is illegal.
                    // Jump straight to the READ (sIssue) with no row open.
                    isMprRead < (mprDebug ? ~we : Const(0)),
                    wrData < reqData,
                    wrMask < reqSel,
                    // beatSel feeds the PHY wrBeat/rdBeat latch. On the mprDebug
                    // build reads use beat 0 (the MPR pattern is identical for
                    // every word, so any beatSel reads 0xFFFF0000, keep it
                    // deterministic), writes keep the real beat.
                    beatSel <
                        (mprDebug
                            ? mux(we, busBeatSel, Const(0, width: 2))
                            : busBeatSel),
                    // MPR read: no ACTIVATE, issue a NOP this cycle and go to
                    // sIssue, which will drive the READ command next cycle. Array
                    // access keeps the ACTIVATE->tRCD->READ sequence unchanged.
                    csN < (mprDebug ? we : Const(0)),
                    cmd <
                        (mprDebug
                            ? mux(
                                we,
                                cmdConst(Ddr3Cmd.activate),
                                cmdConst(Ddr3Cmd.nop),
                              )
                            : cmdConst(Ddr3Cmd.activate)),
                    ba < bank,
                    addr < row,
                    state <
                        (mprDebug
                            ? mux(
                                we,
                                Const(sRcd, width: 4),
                                Const(sIssue, width: 4),
                              )
                            : Const(sRcd, width: 4)),
                    wait < 0,
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(Const(sRcd, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(0, width: 24) + tRcd),
              then: [state < sIssue, wait < 0],
            ),
          ]),
          CaseItem(Const(sIssue, width: 4), [
            csN < 0,
            cmd < mux(isWrite, cmdConst(Ddr3Cmd.write), cmdConst(Ddr3Cmd.read)),
            ba < bank,
            // Column with A10 low (no auto-precharge), burst-aligned. The x16
            // column address counts half-words: word -> col<<1, and the burst
            // start is aligned to BL8 (low 3 column bits zero).
            //
            // READ BURST-REORDER (readColOff, 0..7): the DLL-off static read loses
            // the FIRST beat of the burst to the read preamble (beat0/word0
            // unrecoverable, measured: slk=2 reads word[i+1], word3-of-line
            // garbage). Since Harbor reads ONE word per access, start the READ
            // burst at a non-zero DDR3 column A[2:0] so the target word lands PAST
            // the preamble (a don't-care word takes beat0). DDR3 BL8 wraps within
            // the 8-beat group, so the addressed line's words are still all
            // present, just rotated. Writes keep A[2:0]=0 (they work). Swept on HW.
            // A[2:0] = 0 for writes / non-reorder. For reorder READS =
            // (realBeat-1)*2 so the target word starts at burst position 1.
            // {(realBeat-1)[1:0], 1'b0} = (realBeat-1 mod 4) * 2.
            addr <
                // MPR read column: A[1:0]=00 selects MPR page0 (the 0101
                // predefined pattern), A2=0 (sequential burst order), all higher
                // column bits + A10 (auto-precharge) = 0. Array reads use the
                // burst-aligned array column. isMprRead is always 0 off mprDebug.
                mux(
                  isMprRead,
                  Const(0, width: rowBits),
                  [colGroup, Const(0, width: 3)].swizzle().zeroExtend(rowBits),
                ),
            If(
              isWrite,
              then: [
                wrStart < 1,
                // Saturating WRITE-command counter (scope substitute): bump on the
                // single issue cycle of each WRITE command, clamp at 0xFF so a busy
                // loop never wraps. Reads back via the controller WRCTL register.
                If(
                  ~wrCmdCount.eq(Const(0xFF, width: 8)),
                  then: [wrCmdCount < wrCmdCount + 1],
                ),
              ],
              orElse: [rdStart < 1],
            ),
            state < sData,
            wait < 0,
          ]),
          CaseItem(Const(sData, width: 4), [
            wait < wait + 1,
            // Wait out CWL/CL + the burst + recovery before precharging, all in
            // SEQUENCER-TICK units ([clTicks]/[burstCk]/[tWr] are CK->tick
            // converted above). The extra 4 sequencer ticks cover the PHY's read
            // capture tail (IDDR presentation + beat pairing) and the write
            // postamble, left in ticks (over-conservative on the sclk path).
            If(
              wait.eq(Const(clTicks + burstCk + tWr + 4, width: 24)),
              then: [
                // MPR reads never opened a bank, so PRECHARGE is illegal, ack
                // directly (NOP, back to sIdle). Array accesses precharge as
                // usual. isMprRead is always 0 on the non-mprDebug path.
                csN < mux(isMprRead, Const(1), Const(0)),
                cmd <
                    mux(
                      isMprRead,
                      cmdConst(Ddr3Cmd.nop),
                      cmdConst(Ddr3Cmd.precharge),
                    ),
                ba < bank,
                addr < Const(0, width: rowBits),
                If(
                  isMprRead,
                  then: [
                    busDone < 1,
                    state < sIdle,
                    dwell < Const(dwellTicks, width: 6),
                  ],
                  orElse: [state < sPrecharge],
                ),
                wait < 0,
              ],
            ),
          ]),
          CaseItem(Const(sPrecharge, width: 4), [
            wait < wait + 1,
            // A write holds its ack off for an extra [wrTurn] ticks so the next
            // command cannot start until the write path has quiesced (the beat-
            // duplication turnaround fix). A read acks after tRp only.
            If(
              wait.eq(
                Const(0, width: 24) +
                    tRp +
                    mux(isWrite, Const(wrTurn, width: 24), Const(0, width: 24)),
              ),
              then: [
                busDone < 1,
                state < sIdle,
                wait < 0,
                dwell < Const(dwellTicks, width: 6),
              ],
            ),
          ]),
          CaseItem(Const(sRefresh, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(0, width: 24) + tRfc),
              then: [state < sIdle, wait < 0],
            ),
          ]),
        ]),
      ],
    );

    // Write-leveling level outputs, derived combinationally from the FSM state.
    // wlEn spans the three WL states (Enter/Scan/Exit). ODT is asserted across
    // the WL phase (JEDEC: RTT_Nom must drive the DQ feedback) and stays low
    // otherwise (DLL-off bring-up leaves ODT off in normal operation).
    final inWl = writeLevel
        ? (state.eq(Const(sWlEnter, width: 4)) |
              state.eq(Const(sWlScan, width: 4)) |
              state.eq(Const(sWlExit, width: 4)))
        : Const(0);
    wlEn <= inWl;
    // Assert ODT during ALL normal operation (state >= sIdle), not just WL, so the
    // DRAM's RTT_Nom/RTT_WR terminate the FPGA-driven write burst (the DLL-off
    // write-eye fix). DDR3 auto-disables RTT_Nom during its own read output, so the
    // clean read path is unaffected. ODT stays low through init (state < sIdle).
    odt <= inWl | state.gte(Const(sIdle, width: 4));
    wlLane <= (writeLevel ? wlLaneReg : Const(0, width: laneSelW));
    // Packed trained delays (lane 0 in the low nibble).
    wlTrained <=
        (writeLevel
            ? wlTrainedLane.rswizzle()
            : Const(0, width: 4 * laneCount));
    // WL is done once the FSM has left the WL states for normal operation. When
    // WL is disabled it is trivially done so the PHY applies no delay shift.
    wlDone <=
        (writeLevel ? (state.gte(Const(sIdle, width: 4)) & ~inWl) : Const(1));
    // wl_fb_map = {bit7 = wlFbEver (feedback ever high in the scan), bits[6:0] =
    // the ticks-1..7 feedback waveform}. See the wlFbEver / wlFbMapReg comments.
    wlFbMap <=
        (writeLevel
            ? [wlFbEver, wlFbMapReg.getRange(0, 7)].swizzle()
            : Const(0, width: 8));

    // Read-calibration level outputs. Active only during the sRdCal phase; lane/
    // window/tap held from the working registers; done from the latch (or 1 when
    // read-cal is disabled so the controller never gates the bus).
    // Active during BOTH the read-cal sweep and the self-test verify, so the PHY
    // read capture uses the cal-driven window/tap through the whole calibration.
    rdCalActive <=
        (readLevel
            ? (state.eq(Const(sRdCal, width: 4)) |
                  (selfTest ? state.eq(Const(sSelfTest, width: 4)) : Const(0)))
            : Const(0));
    rdCalLane <= (readLevel ? rdLane : Const(0, width: laneSelW));
    rdCalWindow <= (readLevel ? rdWindowOut : Const(0, width: 4));
    rdCalTap <= (readLevel ? rdTapOut : Const(0, width: 5));
    // The bus gate: on the self-test build the bus opens only after the cadence
    // verify passes (selfTestDone); otherwise on the read-cal sweep alone.
    rdCalDone <= (readLevel ? (selfTest ? selfTestDone : rdDoneReg) : Const(1));
    // Observability word: the held read-cal outcome (see [rdCalDbg]).
    output('rd_cal_dbg') <=
        (readLevel
            ? [
                rdDoneReg, // [15] done
                rdReached, // [14] entered sRdCal
                rdWatchFired, // [13] watchdog aborted
                rdWinFound, // [12] an eye was located
                rdTapOut, // [11:7] locked/current tap (what the PHY uses)
                rdWindowOut, // [6:3] locked/current window
                rdSub, // [2:0] sub-state (where it stopped/hung)
              ].swizzle()
            : Const(0, width: 16));
    // Self-test outcome (held; 1 only when a cadence-verified point was found).
    output('self_test_pass') <= (selfTest ? selfTestPass : Const(0));

    // WRITE-command diagnostic counter out (always present, the controller
    // only routes it into the WRCTL register on the trainable build).
    output('wr_cmd_count') <= wrCmdCount;

    // Init/calibration completion witness + raw state code. init_done asserts
    // once the FSM has left init (power/reset/CKE/MRS/ZQ/WL) for normal
    // operation (state >= sIdle). This is the DRAM-alive oracle: if it never
    // asserts at a new clock, init hung (read state_code for where).
    initDone <= state.gte(Const(sIdle, width: 4));
    stateCode <= state;

    // Note: CWL is not counted directly here (it is implicit in the PHY's
    // write-launch counter), it is asserted even above so a future DLL-on CWL
    // that does not divide the CK/tick ratio fails loudly.
  }
}
