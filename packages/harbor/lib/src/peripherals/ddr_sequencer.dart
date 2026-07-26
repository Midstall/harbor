import 'dart:io' show Platform;

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
    required this.config,
    required this.clkMhz,
    this.ckCyclesPerTick = 1,
    this.cl = 6,
    this.cwl = 6,
    this.mprDebug = false,
    this.writeLevel = false,
    this.wlDelayTaps = 8,
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

    // READ BURST-REORDER (READ_REORDER=1): the DLL-off static read loses the
    // burst's FIRST beat-pair to the read preamble (measured: only 3 of 4 BL8
    // words capturable, the preamble word unrecoverable). Harbor reads ONE word
    // per access, so per read place the TARGET word at burst position 1 (safe,
    // captured) via the DDR3 read column A[2:0], and capture that fixed position.
    //   read column A[2:0] = 2*((realBeat-1) mod 4)  [target -> burst pos 1]
    //   PHY read beat (rdBeat) = 0                    [capture pos 1 at slk=2]
    // Writes are unchanged (A[2:0]=0, beatSel=realBeat). Env-gated so the old
    // behavior is bit-identical when off.
    final reorder = Platform.environment['READ_REORDER'] == '1';
    // Latched real target beat (0..3) for the read-column computation, kept
    // even when reorder rewrites the PHY-facing beatSel to 0 for reads.
    final realBeat = Logic(name: 'real_beat', width: 2);
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
    // Post-write bus turnaround (env-gated, default OFF). A HW experiment holding
    // the write ack off extra ticks did NOT change the beat-duplication glitch
    // rate, so it is not a write->read turnaround gap. Kept as a sweep knob only.
    final wrTurn = ckToTicks(
      int.tryParse(Platform.environment['DDR_WRTURN'] ?? '') ?? 0,
    );
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
    const sRcd = 7; // 6 reserved (was a separate activate state)
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
    // On-chip WRITE-command diagnostic: a saturating count of WRITE commands
    // issued. Held across cycles (NOT reset each cycle in the FSM body), so it
    // accumulates over the whole sweep, reset to 0 at sequencer reset. Drives
    // the wr_cmd_count output for the controller's WRCTL register.
    final wrCmdCount = Logic(name: 'wrCmdCount', width: 8);
    // WL sub-step within sWlScan: 0 settle DQS-low, 1 strobe, 2 sample.
    final wlSub = Logic(name: 'wlSub', width: 2);

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
    // 48/144 MHz paths, 5 for DDR3-667). BENCH: env DDRCWL still overrides to
    // sweep the DRAM's programmed CWL (5/6/7/8) while the PHY launch stays fixed,
    // to find which CWL the DRAM needs to capture the (fixed-timing) write burst.
    final ddrCwl = int.parse(Platform.environment['DDRCWL'] ?? '$cwl');
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
                // After init: enter write-leveling (DDR3 requires it) when
                // [writeLevel] is set, otherwise go straight to normal idle so
                // the proven read-only path is byte-for-byte unchanged.
                if (writeLevel) ...[
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
                ] else
                  state < sIdle,
              ],
            ),
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
              Case(wlSub, [
                // Sub 0: settle (DQS held low), move to strobe. CLEAR the vote
                // accumulator so sub-step 1 counts only this tap's settled window.
                CaseItem(Const(0, width: 2), [
                  If(
                    wait.eq(Const(tWlo, width: 24)),
                    then: [wlSub < 1, wait < 0, wlFbVotes < 0],
                  ),
                ]),
                // Sub 1: emit one WL DQS strobe, wait tWLO for the feedback, and
                // ACCUMULATE the feedback every tick across the settled window (the
                // majority vote). One increment per high-feedback tick. The count
                // is decided in sub-step 2.
                CaseItem(Const(1, width: 2), [
                  wlStrobe < 1,
                  If(wlFb, then: [wlFbVotes < wlFbVotes + 1]),
                  If(
                    wait.eq(Const(tWlo, width: 24)),
                    then: [wlSub < 2, wait < 0],
                  ),
                ]),
                // Sub 2: sample the DQ feedback bit. Detect the 0->1 transition.
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
                CaseItem(Const(2, width: 2), [
                  // MAJORITY vote ([wlFbMaj], combinational, declared above): the
                  // feedback counted high on >= half the settled-window ticks. This
                  // replaces the single marginal sample with a deterministic voted
                  // value. The edge logic + the tap-0 baseline guard are otherwise
                  // UNCHANGED (only wlFb -> wlFbMaj).
                  wlFbPrev2 < wlFbPrev,
                  wlFbPrev < wlFbMaj,
                  // WITNESS: record the voted feedback for this tap into the
                  // bitmap (bit[wlTap] = wlFbMaj). Uses a masked-in set so the
                  // other taps' recorded bits persist. On the first lane's tap 0
                  // clear stale bits from a prior lane by ANDing off nothing here
                  // (the reset zeroes it, each lane overwrites the same map, so
                  // the FSBL sees the LAST lane's sweep. Re-run WL per lane to
                  // witness each). Dynamic bit-set via a 1<<wlTap mask.
                  wlFbMapReg <
                      ((wlFbMapReg &
                              ~(Const(1, width: 8) << wlTap.zeroExtend(8))) |
                          mux(
                            wlFbMaj,
                            Const(1, width: 8) << wlTap.zeroExtend(8),
                            Const(0, width: 8),
                          )),
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
                    realBeat < busBeatSel,
                    // reorder READS present rdBeat=0 to the PHY (capture the
                    // fixed burst position 1). Writes and non-reorder keep the
                    // real beat. beatSel feeds the PHY wrBeat/rdBeat latch. On the
                    // mprDebug build reads use beat 0 (the MPR pattern is identical
                    // for every word, so any beatSel reads 0xFFFF0000, keep it
                    // deterministic), writes keep the real beat.
                    beatSel <
                        (mprDebug
                            ? mux(we, busBeatSel, Const(0, width: 2))
                            : reorder
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
                  [
                    colGroup,
                    reorder
                        ? mux(
                            isWrite,
                            Const(0, width: 3),
                            // A[2:0] = (realBeat XOR 3)*2 so read realBeat
                            // captures line-word realBeat (HW-measured x16).
                            [
                              realBeat ^ Const(3, width: 2),
                              Const(0, width: 1),
                            ].swizzle(),
                          )
                        : Const(0, width: 3),
                  ].swizzle().zeroExtend(rowBits),
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
    wlFbMap <= (writeLevel ? wlFbMapReg : Const(0, width: 8));

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
