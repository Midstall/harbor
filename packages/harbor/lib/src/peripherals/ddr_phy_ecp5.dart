import 'dart:io' show Platform;

import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import 'ddr_phy.dart';

/// ECP5 DDR3 PHY. DDR CK is the `ddr` clock-domain rate (the raw 48 MHz osc for
/// the DLL-off bring-up, or a PLL'd 144 MHz for the DLL-on DQS-strobed read).
/// Commands are 1T SDR-registered, and the data path uses the x2 (MIDDRX/MODDRX)
/// DQS-strobed gearing. The CL/CWL taps (cl=6, cwl=6) are the same at both rates.
/// The sequencer flips the DRAM DLL via the MR registers, the PHY datapath is
/// rate-agnostic (eclk = CK, sclk = CK/2 derived from the domain clock).
///
/// Write timing: DQS launches on the 0-degree clock (edge-aligned to CK, so
/// tDQSS is nominally zero), while DQ/DM launch on a phase-shifted clock
/// from an internal EHXPLLL secondary output so the data eyes straddle the
/// strobe edges. Read capture runs each DQ through a static [readTaps]
/// DELAYG into an IDDRX1F. At DLL-off speeds the eye is wide enough for a
/// fixed tap (training refines it later).
///
/// The burst engine is BL8 on a x16 part: 8 beats, 4 words. Writes mask
/// every beat except the addressed word's two via DM, reads capture all 8
/// beats and select the word.
///
/// Several constants here are calibrated against measurements taken on the
/// OrangeCrab (in-system pad captures and DRAM readback structure) rather
/// than derived from primitive documentation: the ODDR pipeline depth, the
/// read window slack, and the ODDR slot assignment. Each is commented at
/// its definition.
class DdrPhyEcp5 extends DdrPhy {
  /// Exported half-rate fabric clock (sclk = eclk/2) that the controller uses
  /// to clock the [DdrSequencer] and the request-side bus-face registers
  /// (Milestone 1: the PHY owns the edge-clock tree and hands out sclk).
  Logic get sclkOut => output('sclk');

  /// Lane-0 DQSBUFM DATAVALID, sclk domain. The read-leveling oracle the
  /// controller's STATUS register exposes to firmware (X in sim, real on
  /// hardware). Only meaningful on the trainable build.
  Logic get rdDataValid => output('rd_datavalid');

  /// Lane-0 DQSBUFM BURSTDET, sclk domain. Latches when a burst was detected in
  /// the read window. Firmware polls it (via STATUS) to know the read eye
  /// landed during a READCLKSEL / read-pointer sweep.
  Logic get rdBurstDet => output('rd_burstdet');

  /// Sticky "BURSTDET ever asserted since reset", sclk domain. Catches a
  /// single-cycle BURSTDET pulse the live flag drops before firmware reads it.
  Logic get rdBurstDetSeen => output('rd_burstdet_seen');

  /// Sticky "DATAVALID ever asserted since reset", sclk domain. Same rationale
  /// as [rdBurstDetSeen].
  Logic get rdDataValidSeen => output('rd_datavalid_seen');

  /// DDRDLLA lock / ddrdel liveness, sclk-registered. A 0 here is the prime
  /// suspect for a dead DQS read (no valid ddrdel -> garbage DQSR90).
  Logic get dllAliveOut => output('dll_alive');

  /// DDRDEL-load init-handshake complete (sclk domain). High after the
  /// litedram ECP5DDRPHYInit timeline has run and latched the calibrated
  /// DDRDEL code into the DQSBUFMs. The controller gates the sequencer's exit
  /// from init on this so no read/write command issues before the read path's
  /// delay code is loaded.
  Logic get initDoneOut => output('init_done');

  /// Init-FSM handshake observability (sclk domain, defined in sim because the
  /// FSM control logic is sim-visible even though the DDRDLLA/DQSBUFM leaves are
  /// X). These mirror the signals the FSM drives to the clock tree / DQSBUFMs
  /// so the init-timeline sim test can assert the litedram waveform (UDDCNTLN
  /// idle-high with one low pulse inside PAUSE-high, FREEZE before the update,
  /// the STOP/reset bounce, and initDone after).
  Logic get initUddcntlnOut => output('init_uddcntln');
  Logic get initFreezeOut => output('init_freeze');
  Logic get initEclkStopOut => output('init_eclk_stop');
  Logic get initEclkResetOut => output('init_eclk_reset');
  Logic get initAlignwdOut => output('init_alignwd');
  Logic get initPauseOut => output('init_pause');

  /// RDPNTR-ALIGN read-block reset (DLL-on trainable path). Held asserted through
  /// the init bounce, released at the new phase-12 step (after DDRDEL calibration,
  /// inside PAUSE-high) so the DQSBUFM/IDDRX2DQA read gearbox frames RDPNTR on a
  /// deterministic beat-0 phase every cold boot. Observability for the FSM
  /// ordering sim test.
  Logic get initRdResetOut => output('init_rd_reset');

  /// Lane-selected DQ write-leveling feedback (sclk domain). During WL the DRAM
  /// samples CK on the DQS rising edge and drives the result back on DQ, this is
  /// the captured feedback bit the sequencer's WL FSM samples. Only present on
  /// the writeLevel build (X in sim, real on hardware).
  Logic get wlFeedbackOut => output('wl_feedback');

  /// Per-lane DQSBUFM write-pointer WRMOVE pulse (sclk domain), packed one bit
  /// per byte lane. Observability for the write-pointer stepper: these are the
  /// SAME pulses fed to the DQSBUFM WRMOVE inputs, so a sim test can count them
  /// (the control logic is sim-visible even though the DQSBUFM leaf is X). Only
  /// present on the writeLevel / wrDlyTrainable build.
  Logic get wrMoveDbg => output('wr_move_dbg');

  /// Per-lane DQSBUFM write-pointer WRLOADN pulse (sclk domain, active-low),
  /// packed one bit per byte lane. The reload-to-min that precedes the WRMOVE
  /// steps. Same observability rationale as [wrMoveDbg].
  Logic get wrLoadnDbg => output('wr_loadn_dbg');

  /// DQSBUFM READ-pointer control nets fed to every lane's DQSBUFM (sclk
  /// domain). [rdMoveDbg] is the reg5 RDMOVE step pulse (one cycle per firmware
  /// RDMOVE write), [rdLoadnDbg] the active-low RDLOADN, [rdDirectionDbg] the
  /// RDDIRECTION level. Observability that the reg5 RDPCTL read-strobe-centering
  /// knob actually REACHES the DQSBUFM (the leaf DQSR90/RDPNTR are X in sim).
  /// Present only on the trainable build.
  Logic get rdMoveDbg => output('rd_move_dbg');
  Logic get rdLoadnDbg => output('rd_loadn_dbg');
  Logic get rdDirectionDbg => output('rd_direction_dbg');

  /// The DQSBUFM READ0/READ1 read-gate pulse (sclk domain), mirrored for sim
  /// observability. Present only on the trainable build. This is the clean
  /// 2-sclk pulse (or the legacy 3-tap gate when reg11 is the sentinel) whose
  /// POSITION relative to the read command is set by reg11 RDPULSE, independent
  /// of the RDSLACK capture anchor. A test drives [rdStart] and a programmed
  /// pulse position and confirms the gate opens at the commanded tap (the DQSBUFM
  /// DQSR90/BURSTDET are X in sim, but the gate pulse feeding READ0/READ1 is
  /// plain fabric and sim-visible). This is the burst-framing lever.
  Logic get rdGateDbg => output('rd_gate_dbg');

  /// Per-DQ gated read-deskew MOVE mirror (one bit per DQ), present only on the
  /// [perBitDeskew] build. A driven MOVE reaches ONLY the selected DQ (or all in
  /// broadcast mode). Sim-visible proof of the per-bit deskew gating.
  Logic get dqMoveDbg => output('dq_move_dbg');

  /// Per-lane DQSBUFM DYNDELAY value (reg8), packed [8*laneCount-1:0]. The
  /// static per-DQS-group DQS-strobe delay that centers the read (and write)
  /// eye. Observability that the reg8 trim reaches each lane's DQSBUFM. Present
  /// only on the writeTrimTrainable build.
  Logic get rdDynDelayDbg => output('rd_dyndelay_dbg');

  /// On-chip write-control diagnostics (scope substitutes), all sclk-domain
  /// SATURATING 8-bit counters over write bursts. These are DEFINED fabric
  /// signals (the OE window, the DM mask, the ODDR data-launch window), NOT the
  /// X-prone DQ/DQS pads, so they are sim-visible and tell firmware, without a
  /// scope, exactly where the write control path stalls:
  ///   - [wrOeCount]:  times the DQ output-enable window ([oeWindow]) asserted
  ///                   (0 means the tristate never opened -> DRAM saw Hi-Z).
  ///   - [wrDmCount]:  times the data mask went LOW on any byte lane (a write
  ///                   was actually presented unmasked, 0 means everything was
  ///                   masked).
  ///   - [wrDatCount]: times the write-data launch window ([wrData2], the ODDR
  ///                   data window) asserted (0 means the data path never
  ///                   launched).
  Logic get wrOeCount => output('wr_oe_count');
  Logic get wrDmCount => output('wr_dm_count');
  Logic get wrDatCount => output('wr_dat_count');
  // On-chip write-eye capture: lane-0's 4 driven sub-beats latched during the OE
  // window. {beat3,beat2,beat1,beat0} each [7:0]. Read via train reg9.
  Logic get wrCap => output('wr_cap');

  DdrPhyEcp5(
    Logic clk,
    Logic reset, {
    // Sequencer command channel.
    required Logic cke,
    required Logic csN,
    required Logic cmd,
    required Logic ba,
    required Logic addr,
    required Logic odt,
    required Logic resetN,
    // Sequencer data channel.
    required Logic wrStart,
    required Logic wrData,
    required Logic wrMask,
    required Logic beatSel,
    required Logic rdStart,
    // Bidirectional DDR data pads. The PHY OWNS the DQ/DQS tristate buffers
    // (Ecp5Bb) so each write-OE TSH `Q` drives its pad's tristate `T` DIRECTLY,
    // with no fabric inverter and no module-boundary hop: the nextpnr ECP5
    // packer rejects a TSHX2DQA/DQSA `Q` that does not connect straight to a
    // top-level (TRELLIS_IO) tristate. The controller punches these inOut nets
    // up to the top-level pads. DM stays output-only (no TSH). DQS pad style is
    // build-time gated on dllOn: DLL-ON it is a single TRUE-DIFFERENTIAL pad on
    // the LDQS _p ball (the LDQSN complement is generated by nextpnr, [padDqsN]
    // unused). DLL-OFF it is an EXPLICIT pseudo-differential pair, so [padDqsN]
    // IS the dedicated _n net the PHY drives with a complement ODDR (like CK#).
    required Logic padDq,
    Logic? padDqs,
    Logic? padDqsN,
    required int rowBits,
    required int baBits,
    int dataBits = 16,
    int clkMhz = 48,
    int readTaps = 40,
    // Static read-capture window slack (cycles after CL before the burst is
    // latched). Board/build-specific read-training knob: the burst's first
    // beat lands at a build-dependent cycle, so a wrong slack mis-pairs the
    // first word (its rise half captures the fall data). Swept like readTaps.
    // Default 2: the faithful DQS-read cosim showed slack=1 opens the window
    // one SCLK too early (burst's first word reads stale), slack=2 lands it.
    int readSlack = 2,
    // When set, pair each captured FALL with the NEXT cycle's RISE (the fall
    // is registered one cycle and paired with the current rise). The read
    // preamble / write-to-read turnaround consumes the burst's first rise
    // sample, so same-cycle pairing leaves word0's rise stale. This cross-cycle
    // pairing steps past the lost first sample. Confirmed needed on the
    // OrangeCrab (mprDebug: word0 low read stale, words 1-3 clean).
    bool readCrossPair = false,
    // x1 (!dllOn) read deserialize-assembly select: the bench knob for how the
    // two 16-bit halves of each fabric word are sourced from the IDDRX1F samples.
    // q0 = the clk90 RISE-edge sample, q1 = the clk90 FALL-edge sample. On the
    // DLL-off write->read turnaround the q0 (rise) sample lands in a dead
    // transition zone (bench: constant garbage, read-tap-insensitive) while q1
    // (fall) is clean, so the assembly must avoid q0:
    //   0 = {q1Cap, q0Cap}   HEAD same-cycle (high16=fall q1, low16=rise q0)
    //   1 = {q0Cap, q1Prev}  cross: low16 from the registered clean q1 (recovers
    //                        beat0's low half, high16 still on the dead q0)
    //   2 = {q1Cap, q1Prev}  q1-ONLY: both halves from the clean fall edge,
    //                        current + registered-previous (q0 unused)
    // Modes 1/2 read the previous cycle's registered samples, so they capture one
    // cycle later (the sliding-pair point), mode 0 is same-cycle. ONLY affects the
    // x1 DLL-off read. The DLL-on x2 path is untouched.
    int readPairMode = 0,
    // Sample the read DQ on the 0-degree clock instead of the -90 clk90. This
    // is a HALF-BEAT (90-degree) shift of the capture point: the one knob that
    // moves sub-beat (readTaps is < half-beat, readSlack is a full cycle, and
    // CLKOS_CPHASE is inert on this silicon). Tries to land the first read beat
    // that the preamble/turnaround otherwise eats.
    bool readOnClk = false,
    // DQS-gate read-clock select for DQSBUFM.READCLKSEL[2:0]. A fixed constant
    // for now (3'b100 = the mid window per Lattice TN1265 / litex's default).
    // Read-gate training sweeps it in Milestone 3.
    int readClkSel = 0x4,
    // Opt-in CPU read training (see HarborDdrController.trainableRead). When
    // [trainable], each DQ runs through a DYNAMIC [Ecp5Delayf] driven by the
    // shared [delayLoadn]/[delayMove]/[delayDirection] (one tap controller fans
    // to the whole group) instead of the static DELAYG, and the read window
    // opens at a RUNTIME slack [rdSlackRuntime] (0..[maxRdSlack]). When false,
    // the proven static path (DELAYG + const slack) is built unchanged.
    bool trainable = false,
    Logic? delayLoadn,
    Logic? delayMove,
    Logic? delayDirection,
    Logic? rdSlackRuntime,
    // Runtime DQS-gate read-clock select (DQSBUFM.READCLKSEL[2:0]). When
    // [trainable] this drives READCLKSEL so the read-gate-to-DATAVALID latency
    // is swept at runtime exactly as litedram's ECP5DDRPHY walks `rdly` during
    // read leveling (ecp5ddrphy.py rdly -> i_READCLKSELn). When null/non-
    // trainable, the build-time [readClkSel] constant is used unchanged.
    Logic? readClkSelRuntime,
    // TRAINABLE READ-PULSE POSITION (reg11 RDPULSE). The DQSBUFM READ0/READ1 read
    // pulse (which opens the DQS read-gate window) must land ~2 sclk cycles BEFORE
    // the burst returns (Lattice TN-02035 6.2.4 / litedram `dqs_re =
    // rddata_en.taps[rdtap] | rddata_en.taps[rdtap+1]`). On the OrangeCrab 25F the
    // board round-trip puts the burst at an offset the CL-derived tap does not
    // predict, and the shared RDSLACK knob moves the read GATE and the fabric
    // CAPTURE in lockstep, so no RDSLACK value could frame the burst: the read
    // captured the PREAMBLE/idle (data-invariant readback). This is the missing
    // lever: an INDEPENDENT read-pulse position that shifts ONLY the READ0/READ1
    // gate tap over a WIDE range (0..[maxRdPulse]) off the read command, keeping
    // the pulse a clean 2-sclk pulse, while BURSTDET frames it. The FSBL sweeps
    // this until BURSTDET asserts AND the pattern reads back (burst now in window).
    // When null/non-trainable, falls back to the CL/RDSLACK-derived gate (byte-
    // identical). A value of [pulseDisabled] (all-ones) means "use the legacy
    // RDSLACK-derived gate" so a boot that never writes reg11 is unchanged.
    Logic? rdPulsePos,
    // Runtime DQSBUFM read-pointer DLL controls (RDLOADN/RDMOVE/RDDIRECTION).
    // Mirror the per-DQ DELAYF [delayLoadn]/etc pattern but step the DQSBUFM's
    // OWN read delay instead of the DQ deskew. Active-low LOADN. Only consumed
    // when [trainable], tied to the litedram defaults (rdloadn=1, no move)
    // otherwise.
    Logic? rdLoadn,
    Logic? rdMove,
    Logic? rdDirection,
    // Firmware-writable CLEAR for the sticky BURSTDET-seen / DATAVALID-seen
    // latches (one-sclk pulse). The sticky latches were set-only (held until
    // reset), so firmware could not use BURSTDET as a per-STEP read-level oracle
    // (an RDMOVE-vs-BURSTDET walk to PIN the DQSBUFM read-FIFO pointer to a
    // deterministic phase each boot). This pulse clears them so each step reads a
    // fresh "did BURSTDET assert since the last clear". Only consumed when
    // [trainable], never asserted otherwise (byte-identical non-trainable build).
    Logic? bdetClear,
    // Widened 4 -> 7 so the runtime RDSLACK sweep (now also the fabric CAPTURE
    // anchor cycle, rdPipe[clSys + rdSlackRt]) spans enough sclk cycles to reach
    // the real read cycle on silicon. slackW = (7+1).bitLength = 4 (was 3), so the
    // rd_slack input and the RDSLACK CSR field are 4 bits. Firmware writes 0..7.
    int maxRdSlack = 7,
    // Maximum trainable read-pulse position (reg11 RDPULSE, 0..[maxRdPulse]). The
    // burst can arrive up to ~15 sclk cycles after the read command on a board
    // round-trip (litedram sizes rddata_en to cl_sys_latency + 10), so the pulse
    // sweep must reach well past the CL-derived clSys tap. maxRdPulse=15 => a
    // 5-bit field (0..15 real positions + the all-ones 31 = legacy-gate sentinel).
    // rdPipe grows to hold this many read-command taps.
    int maxRdPulse = 15,
    // When [writeLevel] is set, the sequencer's WL FSM drives these controls to
    // train each byte lane's write DQS output delay. The PHY: (a) during WL
    // ([wlEn]) drives the trained lane's DQS as an output (strobed by [wlStrobe])
    // while DQ stays an INPUT so the DRAM's WL feedback comes back on DQ, exposed
    // as [wlFeedbackOut], (b) steps the DQSBUFM write pointer (WRLOADN/WRMOVE/
    // WRDIRECTION) on [wlDelayRst]/[wlDelayInc], (c) after WL ([wlDone]) applies
    // the trained per-lane tap to the normal write path. Off (default) leaves the
    // write pointer at litedram's tie-off and the read path untouched.
    bool writeLevel = false,
    Logic? wlEn,
    Logic? wlDelayRst,
    Logic? wlDelayInc,
    Logic? wlStrobe,
    Logic? wlLane,
    Logic? wlTrained,
    Logic? wlDone,
    // The auto write-leveling feedback (above) trains the write pointer from the
    // DRAM's DQ feedback. On the bring-up silicon that feedback never transitions
    // (it trains tap 0), so this path lets FIRMWARE set the write-pointer tap
    // DIRECTLY and find the write alignment by reading back a written pattern (a
    // ground-truth oracle), exactly like the read-tap sweep. When [wrDlyTrainable]
    // is set, [wrDly] carries a 4-bit-per-lane firmware tap and [wrDlyApply] is a
    // level-toggle: each edge reloads the per-lane write pointer to min and steps
    // it [wrDly] WRMOVE pulses. The firmware-set tap takes PRECEDENCE over the
    // auto-WL trained tap (when both builds are active), so a written WRDLY always
    // wins. Reuses the SAME per-lane write-pointer stepper the WL apply uses.
    bool wrDlyTrainable = false,
    Logic? wrDly,
    Logic? wrDlyApply,
    // Firmware DQS-DELAY TRIM: PER-LANE DQSBUFM DYNDELAY, packed [8*laneCount-1:0]
    // (lane l = [wrTrim][8*l +: 8]). An 8-bit-per-byte-lane dynamic DQS delay,
    // NOT per-DQ-bit: see [Ecp5Dqsbufm.dyndelay]. When [writeTrimTrainable],
    // [wrTrim] drives each lane's whole DQS strobe delay, which CENTERS THE READ
    // eye per DQS group (the DQS_LI static-delay path: DYNDELAY shifts the strobe
    // the read capture DQSR90 derives from) as well as trimming the below-strobe-
    // pad write skew that floats the first-cycle bits.
    bool writeTrimTrainable = false,
    Logic? wrTrim,
    // When set, the per-DQ DELAYF MOVE/LOADN from the shared tap controller is
    // gated by a one-hot decode of [dqDeskewSelect] (0..dataBits-1), so each DQ
    // bit's read-delay line is walked INDEPENDENTLY. This lets the FSBL deskew
    // each DQ into the DQS capture eye and close the residual 2nd-beat per-bit
    // read scramble a single group-wide read tap cannot fix. Off = the whole DQ
    // group shares one tap (the prior behavior, byte-identical netlist).
    bool perBitDeskew = false,
    Logic? dqDeskewSelect,
    super.name = 'ddr_phy',
  }) {
    // CAS / CAS-write latency in DDR CK cycles. These gate the read-window
    // (clSys) and write-launch (cwlSys) taps below. They MUST match the
    // sequencer's cl/cwl (DdrSequencer programs the matching MR0/MR2 fields), or
    // the launch/capture windows mis-align. CL=6 / CWL=6 is used for BOTH the
    // DLL-off 48 MHz path and the DLL-on 144 MHz path (CL=6 is JEDEC-legal at
    // tCK ~6.94 ns), so the same taps serve both rates. Only the DRAM MR DLL bits
    // change in the sequencer, not the PHY datapath timing.
    const cl = 6;
    const cwl = 6;

    // Build-time DLL engagement. At CK > ~60 MHz the DRAM DLL and the ECP5
    // DDRDLLA lock, so the x2 DQSBUFM-strobed datapath is valid (DQSR90/DQSW/
    // DQSW270 calibrated). At/below that (e.g. the 48 MHz osc rate) the DLL never
    // locks: the strobes are garbage AND nextpnr cannot pack a bidirectional x2
    // DQ pad without the DQS-bonded IOLOGIC, so DLL-off the PHY builds the proven
    // HARDWARE-VERIFIED x1 datapath instead: IDDRX1F/ODDRX1F clocked on a
    // dedicated PHY-PLL clk90, single CK-rate fabric (the pre-Milestone-4 PHY).
    // This is a COMPILE-TIME const, so each gated branch elaborates exactly one
    // path and the DLL-on (e.g. 144 MHz) netlist is byte-identical to before.
    final dllOn = clkMhz > 60;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    cke = addInput('cke', cke);
    csN = addInput('cs_n', csN);
    cmd = addInput('cmd', cmd, width: 3);
    ba = addInput('ba', ba, width: baBits);
    addr = addInput('addr', addr, width: rowBits);
    odt = addInput('odt', odt);
    resetN = addInput('reset_n', resetN);
    wrStart = addInput('wr_start', wrStart);
    wrData = addInput('wr_data', wrData, width: 32);
    wrMask = addInput('wr_mask', wrMask, width: 4);
    beatSel = addInput('beat_sel', beatSel, width: 2);
    rdStart = addInput('rd_start', rdStart);
    final laneCount = dataBits ~/ 8;

    // Bidirectional pads owned by the PHY. DQ is dataBits wide. DQS is one
    // DIFFERENTIAL strobe pad per byte lane (DDR only: SDR leaves it null). The
    // Ecp5Bb cells built below drive these (I=write data, T=TSH.Q tristate) and
    // read them (O -> the IDDRX2DQA / DQSBUFM read path).
    final dqPadNet = addInOut('pad_dq', padDq, width: dataBits);
    final dqsPadNet = padDqs != null
        ? addInOut('pad_dqs', padDqs, width: laneCount)
        : null;
    // DQS complement (_n) pad. The DQS pad STYLE is build-time gated on [dllOn]:
    //   - DLL-ON (the x2 DQSBUFM read path): DQS is a SINGLE TRUE-DIFFERENTIAL pad
    //     on the LDQS _p ball (SSTL135D_I). nextpnr derives the LDQSN (_n) rail
    //     from the same buffer, so the PHY owns NO separate _n pad. The clean
    //     differential DQSI is what lets the DQSBUFM BURSTDET fire. [padDqsN] is
    //     accepted for source compatibility but unused here.
    //   - DLL-OFF (the x1 strobe path, hardware-PROVEN at 48 MHz): DQS is an
    //     EXPLICIT pseudo-differential pair: dqs_p driven by the strobe ODDRX1F
    //     AND dqs_n driven by a SEPARATE complement ODDRX1F on a dedicated _n net
    //     (exactly like the CK/CK# pair), two single-ended SSTL135_I outputs. The
    //     single-diff pad's write strobe was never proven and garbages every
    //     write (DDR E0 at all read taps). The explicit complement is the fix.
    final dqsNPadNet = (!dllOn && padDqsN != null && padDqs != null)
        ? addInOut('pad_dqs_n', padDqsN, width: laneCount)
        : null;

    // Opt-in training controls (only consumed when [trainable]).
    final slackW = (maxRdSlack + 1).bitLength;
    final dLoadn = trainable
        ? addInput('delay_loadn', delayLoadn ?? Const(1))
        : null;
    final dMove = trainable
        ? addInput('delay_move', delayMove ?? Const(0))
        : null;
    final dDir = trainable
        ? addInput('delay_direction', delayDirection ?? Const(0))
        : null;
    // PER-BIT DQ DESKEW select (reg10). When [perBitDeskew], the shared DELAYF
    // MOVE/LOADN from the tap controller is GATED per DQ bit so firmware can walk
    // EACH DQ bit's read-delay line independently (align every bit into the DQS
    // eye, closing the per-bit 2nd-beat scramble). The input is {broadcastBit,
    // dqIndex}: broadcastBit is the MSB. When broadcastBit=1 (the RESET / default
    // value) the MOVE/LOADN fan to ALL bits in lockstep = the prior group-walk
    // behavior (so existing firmware that only writes reg0 RDTAP is UNCHANGED).
    // When broadcastBit=0, MOVE/LOADN gate to the one DQ bit whose index equals
    // dqIndex. Off (perBitDeskew=false) leaves the plain group-shared move (byte-
    // identical netlist).
    final dqIdxW = dataBits.bitLength; // >= log2(dataBits): 5 bits for 16 DQ
    final dqSelW = dqIdxW + 1; // + broadcast bit (MSB)
    final dqDeskewSelIn = (trainable && perBitDeskew)
        ? addInput(
            'dq_deskew_sel',
            // Reset default = broadcast (MSB set), index 0.
            (dqDeskewSelect ?? Const(1 << dqIdxW, width: dqSelW)).zeroExtend(
              dqSelW,
            ),
            width: dqSelW,
          )
        : null;
    final rdSlackRt = trainable
        ? addInput(
            'rd_slack',
            (rdSlackRuntime ?? Const(1, width: slackW)).zeroExtend(slackW),
            width: slackW,
          )
        : null;
    final readClkSelRt = trainable
        ? addInput(
            'read_clksel',
            (readClkSelRuntime ?? Const(readClkSel, width: 3)).zeroExtend(3),
            width: 3,
          )
        : null;
    // Trainable READ-PULSE POSITION (reg11 RDPULSE). Shifts ONLY the READ0/READ1
    // gate tap over 0..[maxRdPulse] sclk cycles from the read command, INDEPENDENT
    // of the RDSLACK capture anchor. The all-ones sentinel ([pulseW]-wide) means
    // "use the legacy CL/RDSLACK-derived gate", so a boot that never writes reg11
    // (reset value = sentinel) keeps the original gate. The FSBL programs a real
    // 0..[maxRdPulse] value and sweeps it against BURSTDET + the readback oracle.
    // pulseW = ceil(log2(maxRdPulse+1)) = 5 for maxRdPulse=15 (positions 0..15
    // need 5 bits, since 15.bitLength=4 but 16.bitLength=5 leaves room for the
    // all-ones sentinel WITHOUT colliding with a real position). So positions
    // 0..15 are REAL taps and the sentinel is the 5-bit all-ones value = 31.
    final pulseW =
        (maxRdPulse + 1).bitLength; // 5 bits: 0..15 real, 31 = sentinel
    final rdPulsePosRt = trainable
        ? addInput(
            'rd_pulse_pos',
            // Reset default = the all-ones sentinel = "legacy gate" (unchanged
            // behavior until firmware programs a real position).
            (rdPulsePos ?? Const((1 << pulseW) - 1, width: pulseW)).zeroExtend(
              pulseW,
            ),
            width: pulseW,
          )
        : null;
    // Runtime read-pointer DLL controls (RDLOADN/RDMOVE/RDDIRECTION). These
    // step the DQSBUFM's read-FIFO pointer to CENTER the read strobe against
    // the deposited burst: the dynamic knob litedram exposes as the ECP5
    // read-leveling MOVE (ecp5ddrphy.py rdly / liblitedram sdram_read_leveling).
    // The earlier revision left these as dead inputs and drove the DQSBUFM from
    // fixed Const values ("centre with DQS_LI_DEL_VAL not RDMOVE"), so no
    // firmware read knob could move the strobe and the DLL-on 144 MHz read was
    // metastable (a fixed C0DE write read back 4 different ways across cold
    // boots). Wire them through so the FSBL can sweep RDMOVE per DQS group.
    // Active-low LOADN (0 loads the DDRDEL 90-deg code, as before). When the
    // controller does not supply them, keep litedram's tie-off (LOADN=0, no
    // move, DIRECTION=1) so the non-trainable build is byte-identical.
    final rdLoadnIn = trainable
        ? addInput('rd_loadn', rdLoadn ?? Const(0))
        : null;
    final rdMoveIn = trainable ? addInput('rd_move', rdMove ?? Const(0)) : null;
    final rdDirIn = trainable
        ? addInput('rd_direction', rdDirection ?? Const(1))
        : null;
    final bdetClearIn = trainable
        ? addInput('bdet_clear', bdetClear ?? Const(0))
        : null;

    // Write-leveling control inputs from the sequencer's WL FSM. Registered only
    // when [writeLevel], tied off internally otherwise.
    final laneSelW = laneCount <= 1 ? 1 : (laneCount - 1).bitLength;
    final wlEnIn = writeLevel ? addInput('wl_en', wlEn ?? Const(0)) : null;
    final wlRstIn = writeLevel
        ? addInput('wl_delay_rst', wlDelayRst ?? Const(0))
        : null;
    final wlIncIn = writeLevel
        ? addInput('wl_delay_inc', wlDelayInc ?? Const(0))
        : null;
    final wlStrobeIn = writeLevel
        ? addInput('wl_strobe', wlStrobe ?? Const(0))
        : null;
    final wlLaneIn = writeLevel
        ? addInput(
            'wl_lane',
            (wlLane ?? Const(0, width: laneSelW)).zeroExtend(laneSelW),
            width: laneSelW,
          )
        : null;
    final wlTrainedIn = writeLevel
        ? addInput(
            'wl_trained',
            (wlTrained ?? Const(0, width: 4 * laneCount)).zeroExtend(
              4 * laneCount,
            ),
            width: 4 * laneCount,
          )
        : null;
    final wlDoneIn = writeLevel
        ? addInput('wl_done', wlDone ?? Const(1))
        : null;

    // Firmware write-DQS-delay (reg7 WRDLY): a 4-bit-per-lane tap and a single
    // apply toggle. Registered only when [wrDlyTrainable], tied off otherwise.
    // reg7 WRDLY field: [4*laneCount-1 : 0] = per-lane 4-bit write-pointer tap,
    // [4*laneCount] = WRDIRECTION (the sense, which value retards vs advances
    // the DQSW270 launch, is UNCONFIRMED on silicon, so it is firmware-swept).
    // Width is 4*laneCount + 1 to carry the extra direction bit.
    final wrDlyW = 4 * laneCount + 1;
    final wrDlyIn = wrDlyTrainable
        ? addInput(
            'wr_dly',
            (wrDly ?? Const(0, width: wrDlyW)).zeroExtend(wrDlyW),
            width: wrDlyW,
          )
        : null;
    final wrDlyApplyIn = wrDlyTrainable
        ? addInput('wr_dly_apply', wrDlyApply ?? Const(0))
        : null;
    // Firmware DQS-DELAY TRIM: a PER-LANE 8-bit DQSBUFM DYNDELAY value, packed
    // [8*laneCount-1:0] (lane l = bits [8*l +: 8]). DYNDELAY is the ECP5's
    // static DQS_LI-style strobe delay: it shifts the WHOLE byte lane's DQS,
    // which is the strobe BOTH the read capture (DQSR90 -> IDDRX2DQA) and the
    // write launch derive from. So sweeping it CENTERS THE READ EYE per DQS
    // group (litedram's DQS_LI_DEL_VAL read-centering knob) as well as trimming
    // the write skew: the fine analog complement to the coarse RDMOVE
    // read-pointer step. Registered only when [writeTrimTrainable], null
    // otherwise so every DQSBUFM keeps its Const(0) DYNDELAY tie-off
    // (byte-identical to every non-trim build). Previously lane-0-only (8 bits).
    final wrTrimW = 8 * laneCount;
    final wrTrimIn = writeTrimTrainable
        ? addInput(
            'wr_trim',
            (wrTrim ?? Const(0, width: wrTrimW)).zeroExtend(wrTrimW),
            width: wrTrimW,
          )
        : null;

    if (writeLevel) {
      // Lane-0 DQ feedback the DRAM drives back during WL (it samples CK on the
      // DQS rising edge). This is an SV-leaf-fed value on hardware (the DQ pad
      // read), X in sim. The FSM control logic that consumes it is sim-visible.
      addOutput('wl_feedback');
    }

    addOutput('rd_data', width: 32);
    addOutput('rd_valid');
    // ON-CHIP WRITE-EYE CAPTURE (tier-2 LA): lane-0's 4 captured DQ sub-beats
    // latched while the write OE window is open = what the write DRIVES (the
    // IDDRX2DQA samples the pad the ODDR drives). Firmware reads it via reg9 to
    // compare drive-vs-store. Driven where beat0..beat3 are in scope (below).
    addOutput('wr_cap', width: 32);
    // DQS read status from lane 0's DQSBUFM, in the sclk domain. DATAVALID
    // marks the IDDRX2DQA Q beats valid for the gated burst. BURSTDET latches
    // when a burst was detected within the read window. Lane 0 is exposed (not
    // an OR-reduce) because the controller polls a single training lane. On a
    // x16 part both byte lanes share the same gate timing, so lane 0 is
    // representative. These are SystemVerilog-leaf outputs (X in sim, real on
    // hardware): they are the read-leveling oracle the firmware sweeps against.
    addOutput('rd_datavalid');
    addOutput('rd_burstdet');
    // Observability for on-silicon DQS-read diagnosis (no sim model, X in sim,
    // real on hardware). Sticky latches catch a single-cycle BURSTDET/DATAVALID
    // pulse that firmware would otherwise miss when polling over the bus clock.
    addOutput('rd_burstdet_seen');
    addOutput('rd_datavalid_seen');
    addOutput('pin_ck');
    addOutput('pin_ck_n');
    addOutput('pin_cke');
    addOutput('pin_cs_n');
    addOutput('pin_ras_n');
    addOutput('pin_cas_n');
    addOutput('pin_we_n');
    addOutput('pin_ba', width: baBits);
    addOutput('pin_addr', width: rowBits);
    addOutput('pin_dm', width: dataBits ~/ 8);
    addOutput('pin_odt');
    addOutput('pin_reset_n');

    // Milestone 4: the internal clk90 write-launch PLL is GONE. The x2 write
    // datapath (ODDRX2DQA/ODDRX2DQSB below) launches DQ/DM/DQS on the DQSBUFM
    // write strobes (DQSW270 / DQSW), which the DDRDLLA already centers in the
    // DQS eye, so the separate phase-shifted clk90 the old x1 ODDRX1F path
    // needed is no longer required. (clkMhz stays a ctor knob for the real-time
    // JEDEC-delay scaling the controller does. It no longer sizes a PLL here.)

    // The incoming [clk] is the CK-rate SOURCE (creek option A: the async
    // `ddr_clk` = the raw 48 MHz osc, or the single sysclk otherwise). It is
    // already at 2x sclk (the CK rate), so it feeds ECLKSYNCB directly as the
    // edge clock. (The phy_pll's CLKOP stays the FEEDBACK-only, CPHASE-0 clock
    // it is today so the hardware-verified CLKOS = clk90 write-launch phase is
    // untouched. Routing CLKOP out as a clock would have forced a CPHASE change
    // that shifts clk90, a calibrated regression.)
    //   - eclk = ECLKSYNCB(clk) at the CK rate, drives CK ODDR + read IOLOGIC.
    //   - sclk = CLKDIVF(eclk, "2.0") = CK/2, the PHY fabric + sequencer clock.
    //   - ddrdel/lock from DDRDLLA(eclk), reserved for the Milestone 2 DQSBUFM
    //     read path (kept live by a tie-off consumer, not used for capture yet).
    // sclk is EXPORTED so the controller clocks the sequencer + the request-side
    // bus-face registers (and the CDC master) on it. CK still toggles at the CK
    // rate, so the DDR CK frequency is unchanged. The command / write / read
    // FABRIC moves to sclk (half rate). The controller halves the sequencer's
    // clkMhz so every real-time (us/ns) JEDEC delay stays equivalent.
    // CAVEAT: CL/CWL/burst are constants in command-clock units. On sclk they
    // span 2x the real time relative to CK now. That pin-level relationship is
    // exactly what Milestone 2's DQS-strobed read replaces and cannot be
    // verified here without hardware (see /tmp/m1_report.md).
    // Forward-declared init-FSM handshake signals (driven by the FSM further
    // down, once sclk/sclkReset exist). They feed the clock tree's DDRDEL-load
    // ports: UDDCNTLN (active-low, idles HIGH), FREEZE, ECLKSYNCB STOP, and the
    // ECLK-domain reset. initPause fans to every DQSBUFM PAUSE.
    final initUddcntln = Logic(name: 'ddr_init_uddcntln');
    final initFreeze = Logic(name: 'ddr_init_freeze');
    final initEclkStop = Logic(name: 'ddr_init_eclk_stop');
    final initEclkReset = Logic(name: 'ddr_init_eclk_reset');
    // CLKDIVF.ALIGNWD word-align pulse. Driven by the init FSM INSIDE the ECLK
    // stop/reset window (mirrors litedram ECP5DDRPHYInit's word-align step,
    // ecp5ddrphy.py L93-96): asserted with eclkReset (phase 3) and dropped with
    // it (phase 4), so the divide-by-2 word boundary is re-aligned
    // DETERMINISTICALLY each config instead of powering up on an arbitrary CK
    // phase. The arbitrary power-up phase was the silicon-only 2-beat-repeat
    // (Q0==Q2, Q1==Q3, w0==w1) root cause: cosim CLKDIVF always resets to phase
    // 0 so sim never exposed it.
    final initAlignwd = Logic(name: 'ddr_init_alignwd');
    final initPause = Logic(name: 'ddr_init_pause');
    // RDPNTR-ALIGN read-block reset (DLL-on only). Held ASSERTED from power-up
    // through the entire init bounce (stop / reset / ALIGNWD / freeze-release /
    // DDRDEL-update), and RELEASED once inside the PAUSE-high window AFTER the
    // DDRDEL/DQSR90 calibration has latched, with PAUSE released LAST. This gives
    // the DQSBUFM read gearbox + its IDDRX2DQA read cells a single clean
    // out-of-reset edge on the freshly-ALIGNWD-aligned, DDRDEL-calibrated
    // gearbox, so the read-FIFO pointer (RDPNTR) frames on a DETERMINISTIC
    // beat-0 phase every cold boot instead of the power-up lottery. Root cause of
    // the multi-session boot-to-boot read-framing wander: the DQSBUFM/IDDRX2DQA
    // RST was `sclkReset`, released ~2 sclk after reset-deassert = LONG before the
    // FSM stops/aligns eclk, so the read block initialized against an unsettled,
    // pre-align gearbox and re-referenced its pointer on an arbitrary DQS-vs-sclk
    // phase. DDRDEL is produced by the SEPARATE DDRDLLA primitive (UDDCNTLN/FREEZE
    // are DDRDLLA inputs, not DQSBUFM inputs), so holding DQSBUFM.RST across the
    // UDDCNTLN update does NOT block the DDRDEL load. It only defers the
    // DQSBUFM's CONSUMPTION of the (now-calibrated) DDRDEL until the clean
    // release. Complements litedram's static-RST + runtime-BitSlip determinism
    // (ecp5ddrphy.py L268/L376-400): here the runtime slp-rotate + popcount-frame
    // + per-bit-deskew training now converges on a repeatable pointer phase.
    final initRdReset = Logic(name: 'ddr_init_rd_reset');
    final initDone = Logic(name: 'ddr_init_done');

    final clkTree = Ecp5DdrClockTree(
      clk,
      reset,
      uddcntln: initUddcntln,
      freeze: initFreeze,
      eclkStop: initEclkStop,
      eclkReset: initEclkReset,
      alignwd: initAlignwd,
      // DLL-OFF omits the DDRDLLA so ddr_eclk is a single-bank net (routable).
      // The DQS read strobes are unused DLL-off (static DELAYG-tap read), so the
      // DDREL calibration the DDRDLLA provides is not needed. DLL-on keeps it.
      buildDll: dllOn,
      name: 'ddr_clk_tree',
    );
    final eclk = clkTree.eclk.named('ddr_eclk');
    final sclk = clkTree.sclk.named('ddr_sclk');
    addOutput('sclk') <= sclk;
    addOutput('eclk') <= eclk;

    // clk90: the 90-degree write/read launch phase for the DLL-OFF x1 datapath.
    // DLL-OFF a DEDICATED PHY EHXPLLL provides the REAL phase-shifted clock: CLKOP
    // feeds back phase-locked to [clk], CLKOS = clk90 (CLKOS_CPHASE = 3/4 of the
    // VCO divide = a -90deg launch phase). This is the pre-Milestone-4, hardware-
    // proven 48 MHz write-eye centering. The DQ pad's read IDDR and write ODDR
    // SHARE this clk90 (a bidir pad's IOLOGIC requires one shared clock: nextpnr
    // "conflicting clocks" otherwise), so CLKOS_CPHASE shifts write + read
    // TOGETHER (inert for read-vs-write). The per-pad DELAYG read tap is the
    // eye-landing lever. DLL-ON the x2 DQSBUFM path centers DQ via the DDRDLLA
    // strobe instead, so no PHY PLL is built, clk90 falls back to a const (UNUSED
    // on the dllOn path). [dllOn] is a build-time const so exactly one branch
    // elaborates: the dllOn netlist gains no PLL.
    final Logic clk90;
    // clk90b: the WRITE DQS strobe clock (CLKOS2), a SECOND 50%-duty PLL output.
    // The DQS pad is OUTPUT-ONLY (strobe ODDR + OE, no read IDDR), so it has no
    // shared-clock IOLOGIC constraint: the DQS group can run on its own clock and
    // still pack. ROOT CAUSE (HW write sweep of CLKOS_CPHASE 0..11): the two
    // write-beat good-zones do NOT overlap, so the DQS edges are NOT tCK/2 apart -
    // because the DQS was launched on `clk`/sclk, which is not a clean 50%-duty
    // edge pair relative to the DQ (on the 50%-duty CLKOS). Launching DQS on a
    // dedicated 50%-duty CLKOS2 makes the DQS edge spacing structurally tCK/2 like
    // the DQ, and CLKOS2_CPHASE tunes the DQS-vs-DQ centering directly. Null on
    // DLL-on (no PHY PLL). [dllOn] is a build-time const.
    Logic? clk90b;
    if (!dllOn) {
      final pllFb = Logic(name: 'ddr_phy_pll_fb');
      // VCO must land in the ECP5 400-800 MHz band: VCO = clkMhz * vcoDiv.
      final vcoDiv = (600 / clkMhz).floor().clamp(2, 128);
      // CLKOS (clk90 = write DQ + read launch/capture phase): HEAD's -90deg
      // (3*vcoDiv/4), env CLKOS_CPHASE-overridable for the bench sweep.
      final clkosCphase = int.parse(
        Platform.environment['CLKOS_CPHASE'] ?? '${(3 * vcoDiv) ~/ 4}',
      );
      // CLKOS2 (clk90b = write DQS strobe phase): a 50%-duty output, default 0deg
      // (~90deg from the -90deg DQ so the DQS edges sit centered in the DQ eyes),
      // env CLKOS2_CPHASE-overridable for the DQS-vs-DQ centering sweep.
      final clkos2Cphase = int.parse(
        Platform.environment['CLKOS2_CPHASE'] ?? '0',
      );
      final phyPll = Ecp5Ehxplll(
        clkiDiv: 1,
        clkfbDiv: 1,
        clkopDiv: vcoDiv,
        clkosDiv: vcoDiv,
        // Second 50%-duty VCO output for the write DQS strobe (DQS-group pads).
        clkos2Div: vcoDiv,
        clkos2Cphase: clkos2Cphase,
        // CLKOP is the FEEDBACK clock only (FEEDBK_PATH=CLKOP), not a routed
        // clock, so its coarse phase MUST be 0. The blackbox default (clkopDiv/2)
        // is for a USED CLKOP. A non-zero feedback CPHASE rotates the VCO/CLKOS
        // (clk90) phase ~180deg at /2 and mis-aligns the DDR by a BEAT: the
        // project #126 regression (one DDR beat garbage, the other clean). Pin to
        // 0 so clk90 = CLKOS keeps the silicon-proven -90deg launch phase.
        // FEEDBACK-ONLY CLKOP: do NOT emit CLKOP_CPHASE/ENABLE/FPHASE. HEAD's
        // hardware-proven PHY PLL emitted none and let the tool default the
        // feedback waveform. Forcing them (#126 work) changed the locked CLKOS
        // (clk90) waveform so no single CLKOS_CPHASE could land both DDR capture
        // edges in their eyes (HW-swept 0..9: each value reads only one beat).
        emitClkopParams: false,
        // CLKOS_CPHASE (write DQ + read), env-overridden above for the bench sweep.
        clkosCphase: clkosCphase,
        clk: clk,
        clkfb: pllFb,
        name: 'phy_pll',
      );
      pllFb <= phyPll.output('CLKOP');
      clk90 = phyPll.output('CLKOS').named('ddr_clk90');
      clk90b = phyPll.output('CLKOS2').named('ddr_clk90b');
    } else {
      // DLL-ON: the x2 DQSBUFM datapath centers DQ via the DDRDLLA strobe, so
      // there is no clk90 consumer. Tie it to a never-read constant (no PHY PLL is
      // built, so the dllOn netlist gains nothing). This local is unused dllOn.
      clk90 = Const(0);
    }

    // sclk-domain reset synchronizer.
    // Async-assert (raw reset holds the domain immediately), sync-deassert
    // (release is retimed through two sclk flops to avoid recovery/removal
    // hazards). Matches the HarborClockGenerator._domainReset idiom.
    final rstSync = Logic(name: 'sclk_rst_sync', width: 2);
    Sequential(sclk, reset: reset, [
      rstSync < [rstSync[0], Const(1)].swizzle(),
    ]);
    final sclkReset = (reset | ~rstSync[1]).named('sclk_reset');

    // clk-domain (raw CK-rate, UNGATED) reset synchronizer. The init-handshake
    // FSM runs on [clk] (the source BEFORE ECLKSYNCB/CLKDIVF), so it does NOT
    // stop when the FSM asserts eclkStop (which stops eclk -> CLKDIVF -> sclk).
    // litedram does the same: it runs ECP5DDRPHYInit in an independent "init"
    // clock domain, while STOP/RESET gate the eclk domain (a DIFFERENT clock).
    // If the FSM were on sclk it would freeze itself at step 2 (stop=1 kills its
    // own clock) and never reach the step that releases stop / sets initDone.
    // Same async-assert / sync-deassert idiom as the sclk reset above, on clk.
    final clkRstSync = Logic(name: 'clk_rst_sync', width: 2);
    Sequential(clk, reset: reset, [
      clkRstSync < [clkRstSync[0], Const(1)].swizzle(),
    ]);
    final clkReset = (reset | ~clkRstSync[1]).named('clk_reset');

    // ROOT-CAUSE FIX for the on-silicon "DLL locks but no read burst is ever
    // detected" failure: the calibrated DDRDEL 90-degree code was never LOADED
    // into the DQSBUFMs, so DQSR90 stayed uncalibrated and BURSTDET never fired.
    // litedram (litedram/phy/ecp5ddrphy.py, ECP5DDRPHYInit, lines 54-111) runs a
    // fixed timeline on the rising edge of DDRDLLA LOCK that freezes the DLL,
    // bounces the ECLK domain, then pulses UDDCNTLN low once inside a DQSBUFM
    // PAUSE window to latch DDRDEL. We replicate that timeline here in the INIT
    // clock domain.
    //
    // CRITICAL clock-domain choice (respin-class fix): the FSM runs on the raw
    // [clk] (the CK-rate SOURCE fed into the PHY, BEFORE ECLKSYNCB/CLKDIVF), NOT
    // on sclk. On hardware sclk = CLKDIVF(eclk) and eclk = ECLKSYNCB(clk,
    // STOP=eclkStop), so a sclk-clocked FSM that asserts eclkStop at step 2 would
    // STOP ITS OWN CLOCK (eclkStop -> eclk stops -> CLKDIVF stops -> sclk stops),
    // freeze mid-timeline, and never reach the step that releases stop or sets
    // initDone: the controller would then hang forever on ~initDone. litedram
    // avoids exactly this by running ECP5DDRPHYInit in an INDEPENDENT "init"
    // clock domain while STOP/RESET gate the (different) eclk domain. [clk] is
    // that independent ungated domain here: it does not stop when eclkStop fires.
    //
    // litedram runs the timeline in its "init" clock domain at t = 8 cycles per
    // step (sys2x for the DLL). We run it in the [clk] = CK-rate domain at
    // [initStepCycles] >= 8 CK cycles per step. JUDGMENT CALL: litedram's t is a
    // settle margin (each control change must propagate through the DLL /
    // ECLKSYNCB / DQSBUFM before the next), not a tight protocol number, so a
    // step count of 8 CK cycles is fine settle margin. We keep 8.
    //
    // The steps mirror litedram L88-102, with the CLKDIVF word-align (ALIGNWD)
    // pulse inserted as a NEW post-ECLK-resume step (5->6/7). litedram's stop/
    // reset bounce establishes the divider state. We then slip the word boundary
    // while ECLK runs, which litedram does not need (its sim/board always powers
    // up at a deterministic phase, but real ECP5 silicon does not):
    //   1: freeze=1   (freeze DDRDLLA)
    //   2: stop=1      (stop ECLK domain via ECLKSYNCB.STOP)
    //   3: reset=1     (reset ECLK domain / CLKDIVF, known divider state)
    //   4: reset=0     (release ECLK reset)
    //   5: stop=0      (release ECLK stop: ECLK RESUMES)
    //   6: alignwd=1   (word-align slip, WITH eclk running so CLKDIVF samples it)
    //   7: alignwd=0   (end the align pulse)
    //   8: freeze=0    (release DDRDLLA freeze)
    //   9: pause=1     (pause DQSBUFM)
    //  10: update=1    (UDDCNTLN -> 0, latch DDRDEL into DDRDLLA/DQSBUFM)
    //  11: update=0    (UDDCNTLN -> 1, end the load pulse)
    //  12: rd_reset=0  (RELEASE the DQSBUFM+IDDRX2DQA read-block reset: the
    //                   RDPNTR-ALIGN step. Gearbox is ALIGNWD-aligned + DDRDEL-
    //                   calibrated and PAUSE is STILL HIGH, so the read pointer
    //                   frames on a DETERMINISTIC beat-0 phase. dllOn-only.)
    //  13: pause=0     (release DQSBUFM pause LAST)
    // CRITICAL polarity: UDDCNTLN idles HIGH and is pulsed LOW for exactly one
    // step (10->11), entirely inside the PAUSE-high window (steps 9..13). FREEZE
    // is asserted+released (steps 1,8) strictly before the update pulse. The
    // ALIGNWD pulse (steps 6,7) is AFTER ECLK resumes (step 5) and never overlaps
    // STOP: a stop-window pulse would see zero ECLK edges and be a no-op. The
    // rd_reset release (step 12) sits AFTER the DDRDEL update and BEFORE the
    // pause-release (step 13), so the read block leaves reset inside PAUSE-high.
    const initStepCycles = 8;
    final initStepW = (initStepCycles).bitLength;
    // 14 phases: idle(0) + 13 timeline steps. Phase advances every
    // initStepCycles sclk cycles once newLock has fired. initPhase is 4-bit
    // (holds 0..13).
    final initPhase = Logic(name: 'ddr_init_phase', width: 4);
    final initCtr = Logic(name: 'ddr_init_ctr', width: initStepW);
    final initRun = Logic(name: 'ddr_init_run');
    final initUpdate = Logic(name: 'ddr_init_update'); // = ~uddcntln
    final initDoneReg = Logic(name: 'ddr_init_done_reg');
    // Lock-wait TIMEOUT. The init timeline starts on the DDRDLLA LOCK rising
    // edge, but on hardware a DDRDLLA that never asserts LOCK (uncalibrated
    // ddrdel / wrong eclk leaf) would leave the sequencer gated on initDone
    // FOREVER, wedging the whole bus (the observed 144 MHz hang: core prints
    // 12345678 then the first DDR access never acks). This free-running counter
    // increments while the FSM is idle waiting for LOCK. If it saturates before
    // LOCK arrives, the timeline force-starts anyway so the bus comes up (reads
    // are uncalibrated until read-leveling lands, but the firmware can now reach
    // the STATUS register and observe DLL_LOCK instead of hanging). ~14 ms at
    // 144 MHz CK (2^21 clk ticks): vastly longer than a real DLL lock (~us).
    final initTimeoutW = 21;
    final initTimeout = Logic(name: 'ddr_init_timeout', width: initTimeoutW);
    final initTimeoutHit = initTimeout.eq(
      Const((1 << initTimeoutW) - 1, width: initTimeoutW),
    );

    // 2-flop synchronize the DDRDLLA LOCK (from the eclk-domain DLL leaf) into
    // the INIT-domain [clk], then edge-detect the rising edge = litedram's
    // new_lock (L82-85). The synchronizer runs on the ungated [clk] (NOT sclk),
    // because the FSM it feeds runs on [clk]: sclk stops when the FSM asserts
    // eclkStop, so a sclk-clocked lock sync + FSM would freeze itself. In sim the
    // clock-tree behavioral model drives a clean 0->1 LOCK. On hardware this is
    // the real leaf (X in sim is fine, the FSM control logic is still sim-visible
    // when LOCK is forced/modelled high).
    final lockSync = Logic(name: 'ddr_lock_sync', width: 2);
    final lockPrev = Logic(name: 'ddr_lock_prev');
    Sequential(clk, reset: clkReset, [
      lockSync < [lockSync[0], clkTree.lock].swizzle(),
      lockPrev < lockSync[1],
    ]);
    final lockS = lockSync[1];
    final newLock = (lockS & ~lockPrev).named('ddr_new_lock');

    Sequential(
      clk,
      reset: clkReset,
      resetValues: {
        initPhase: Const(0, width: 4),
        initCtr: Const(0, width: initStepW),
        initRun: Const(0),
        initFreeze: Const(0),
        initEclkStop: Const(0),
        initEclkReset: Const(0),
        initAlignwd: Const(0),
        initUpdate: Const(0),
        initPause: Const(0),
        // Read-block reset idles ASSERTED (1) and is released once, cleanly, at
        // the new phase-12 step after DDRDEL calibration. Reset-value 1 means the
        // DQSBUFM/IDDRX2DQA read cells are held in reset from power-up until the
        // aligned+calibrated gearbox is ready.
        initRdReset: Const(1),
        initDoneReg: Const(0),
        initTimeout: Const(0, width: initTimeoutW),
      },
      [
        // Count up while idle waiting for LOCK (stops once the timeline runs or
        // is done). Saturates so the timeout fires exactly once and holds.
        If(
          ~initRun & ~initDoneReg & ~initTimeoutHit,
          then: [initTimeout < initTimeout + 1],
        ),
        // Start the DDREL-load timeline on the rising edge of LOCK (the normal
        // path when the DDRDLLA locks).
        If(
          newLock & ~initRun & ~initDoneReg,
          then: [initRun < 1, initPhase < Const(1, width: 4), initCtr < 0],
        ),
        // LOCK-WAIT TIMEOUT fallback: if the DDRDLLA never asserts LOCK on
        // silicon, do NOT run the eclk-stop timeline (which itself needs a valid
        // DLL and would just break sclk). Instead set initDone DIRECTLY so the
        // bus comes up on the free-running eclk. Reads are uncalibrated, but the
        // sequencer un-gates so firmware can reach the STATUS register, observe
        // DLL_LOCK, and run read-leveling instead of hanging the whole bus.
        If(initTimeoutHit & ~initRun & ~initDoneReg, then: [initDoneReg < 1]),
        If(
          initRun,
          then: [
            initCtr < initCtr + 1,
            If(
              initCtr.eq(Const(initStepCycles - 1, width: initStepW)),
              then: [
                initCtr < 0,
                // Apply the control change for the phase we are LEAVING, then step.
                Case(initPhase, [
                  CaseItem(Const(1, width: 4), [initFreeze < 1]),
                  CaseItem(Const(2, width: 4), [initEclkStop < 1]),
                  // CLKDIVF RST asserted/released INSIDE the ECLK-stop window to
                  // establish a known divider state. NO alignwd here: the ECLKSYNCB
                  // freezes ECLK while STOP=1 (ECLKO = STOP ? 0 : ECLKI) and the
                  // CLKDIVF only samples ALIGNWD on an ECLK posedge, so an alignwd
                  // pulse during stop sees ZERO clock edges and is a NO-OP (the
                  // divide-by-2 word phase would stay at its random power-up value).
                  CaseItem(Const(3, width: 4), [initEclkReset < 1]),
                  CaseItem(Const(4, width: 4), [initEclkReset < 0]),
                  // ECLK RESUMES here (STOP drops). After this the CLKDIVF input
                  // clock is running again.
                  CaseItem(Const(5, width: 4), [initEclkStop < 0]),
                  // POST-RESUME word-align pulse: assert ALIGNWD for a full phase
                  // (initStepCycles ECLK cycles) WITH eclk running, so the CLKDIVF
                  // samples it on a real ECLK posedge and slips the divide-by-2 word
                  // boundary DETERMINISTICALLY off the just-established (reset) state.
                  // This is the load-bearing fix: ALIGNWD must be high across at
                  // least one ECLK posedge while STOP==0. The RST->release (phases
                  // 3-4) precedes this pulse on purpose (known state first, then the
                  // trained slip).
                  CaseItem(Const(6, width: 4), [initAlignwd < 1]),
                  CaseItem(Const(7, width: 4), [initAlignwd < 0]),
                  // Original post-stop steps, shifted down by two to follow the
                  // ALIGNWD pulse: freeze-release, pause, update, update-release,
                  // pause-release.
                  CaseItem(Const(8, width: 4), [initFreeze < 0]),
                  CaseItem(Const(9, width: 4), [initPause < 1]),
                  CaseItem(Const(10, width: 4), [initUpdate < 1]),
                  CaseItem(Const(11, width: 4), [initUpdate < 0]),
                  // RDPNTR-ALIGN: release the DQSBUFM + IDDRX2DQA read-block reset
                  // HERE: after ALIGNWD aligned the gearbox and the DDRDEL/DQSR90
                  // calibration latched (phases 10-11), while PAUSE is STILL HIGH.
                  // This is the single clean out-of-reset edge that pins RDPNTR to a
                  // deterministic beat-0 phase. It must be BEFORE pause-release (next
                  // phase) so the read block leaves reset inside the PAUSE bracket.
                  CaseItem(Const(12, width: 4), [initRdReset < 0]),
                  // PAUSE released LAST (phase 13), after the read block is already
                  // out of reset on the aligned/calibrated gearbox.
                  CaseItem(Const(13, width: 4), [initPause < 0]),
                ]),
                If(
                  initPhase.lt(Const(13, width: 4)),
                  then: [initPhase < initPhase + 1],
                  orElse: [
                    // Timeline complete: latch initDone, stop running.
                    initRun < 0,
                    initDoneReg < 1,
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    // UDDCNTLN is ACTIVE-LOW: it idles HIGH and goes LOW only while update=1.
    initUddcntln <= ~initUpdate;

    // initDone crosses from the [clk] init domain back into the sclk fabric
    // domain: initDoneReg is a clk-domain flop now, but the DdrSequencer gate in
    // ddr.dart (seqReset = ... | ~initDone) runs on sclk. Resynchronize it with a
    // 2-flop sclk synchronizer so the controller samples a sclk-clean level. It
    // is a quasi-static, set-once level (latches high at the end of the timeline
    // and stays), so a plain level synchronizer is sufficient (no pulse to lose).
    final initDoneSync = Logic(name: 'ddr_init_done_sync', width: 2);
    Sequential(sclk, reset: sclkReset, [
      initDoneSync < [initDoneSync[0], initDoneReg].swizzle(),
    ]);
    initDone <= initDoneSync[1];
    addOutput('init_done') <= initDoneSync[1];
    // Observability for the init-timeline sim test (these are the FSM control
    // signals, defined in sim).
    addOutput('init_uddcntln') <= initUddcntln;
    addOutput('init_freeze') <= initFreeze;
    addOutput('init_eclk_stop') <= initEclkStop;
    addOutput('init_eclk_reset') <= initEclkReset;
    addOutput('init_alignwd') <= initAlignwd;
    addOutput('init_pause') <= initPause;
    addOutput('init_rd_reset') <= initRdReset;

    // DDRDLLA lock status, registered into the sclk domain for the STATUS
    // observability bit. Derived ONLY from the DDRDLLA LOCK output (a normal
    // routable signal). It must NOT tap clkTree.ddrdel (the multi-bit delay
    // CODE): DDRDEL is a DEDICATED ECP5 net that can only drive the DQSBUFM
    // DDRDEL inputs, so a fabric tap of it (.or()) forces DDRDEL onto general
    // routing and nextpnr fails ("Failed to find a route for net DDRDEL"). The
    // delay code stays a pure DQSBUFM dedicated route (wired at the DQSBUFM
    // below). LOCK alone tells firmware whether the DLL came up.
    final dllAlive = Logic(name: 'ddr_dll_alive');
    Sequential(sclk, reset: sclkReset, [dllAlive < clkTree.lock]);
    addOutput('dll_alive') <= dllAlive;

    // CK/CK#: free-running mirror of CK via DDR outputs at the CK rate.
    // Explicit pseudo-differential pair: nextpnr does not build the
    // complement side of "D"-suffixed SSTL output types, which would leave
    // CK# floating and the part's differential clock receiver dead.
    //
    // Clocked on the PRIMARY CK-rate clock ([clk] = the raw CK-rate source fed
    // into the PHY, the Milestone 4 write path deleted the internal clk90 PLL),
    // NOT the edge clock [eclk]. An ODDRX1F only needs a plain CK-rate clock to
    // gear D0/D1 at the pin. Using eclk would add two more sinks to the dedicated
    // ECLK spine, which on the OrangeCrab bottom DDR banks is exactly what
    // could not fit one ECLK net. Keeping ECLK to ONLY the DQS-gated IOLOGIC
    // (DQSBUFM / IDDRX2DQA / ODDRX2DQA / TSH / CLKDIVF) shrinks its fanout to
    // what truly needs it. CK rides the ordinary CK-rate clock network instead
    // (it is the same source the ECLKSYNCB buffers, so CK stays edge-aligned).
    final ckDdr = Ecp5Oddrx1f(
      sclk: clk,
      rst: reset,
      d0: Const(1),
      d1: Const(0),
      name: 'ck_oddr',
    );
    ckOut <= ckDdr.q;
    final ckNDdr = Ecp5Oddrx1f(
      sclk: clk,
      rst: reset,
      d0: Const(0),
      d1: Const(1),
      name: 'ck_n_oddr',
    );
    ckNOut <= ckNDdr.q;

    // Command/address: 1T SDR registers. DLL-ON they clock on the SCLK fabric
    // (= CK/2, the x2 sequencer domain). DLL-OFF the sequencer runs at CK rate
    // (the x1 single-clock contract, ddr.dart's useSclkFabric is gated on dllOn),
    // so the command registers clock on [clk] = CK to match. [dllOn] is a
    // build-time const.
    final cmdClk = dllOn ? sclk : clk;
    final cmdReset = dllOn ? sclkReset : clkReset;
    Sequential(
      cmdClk,
      reset: cmdReset,
      resetValues: {csNOut: Const(1), resetNOut: Const(0)},
      [
        ckeOut < cke,
        csNOut < csN,
        rasNOut < cmd[2],
        casNOut < cmd[1],
        weNOut < cmd[0],
        baOut < ba,
        addrOut < addr,
        odtOut < odt,
        resetNOut < resetN,
      ],
    );

    // One Ecp5Bb per byte lane on the DQS _p ball (LDQS site), declared
    // SSTL135D_I in the LPF so nextpnr-ecp5 makes it a TRUE DIFFERENTIAL pad: the
    // tool drives/receives the LDQSN (_n) partner ball as the complement of this
    // same buffer, so there is NO separate _n pad, buffer or net. Built BEFORE
    // the DQSBUFM so the DIFFERENTIAL received-strobe value (Bb.O = the slicer
    // output of dqs_p vs dqs_n) feeds DQSBUFM.DQSI: the clean differential read
    // strobe that lets BURSTDET fire (the prior single-ended dqs_p-only read,
    // VREF-sliced, never detected the burst). The drive value (I) and tristate
    // (T = the DQS-OE TSH `Q`) are forward-declared here and driven once the
    // write-side ODDRX2DQSB strobe + TSHX2DQSA exist below. The TSH `Q` reaches
    // the Bb `T` with NO intervening fabric logic (the nextpnr packing
    // constraint). On a differential pad the single buffer drives BOTH rails on
    // write, so the old explicit pseudo-differential _n drive path is gone.
    final dqsDrive = List.generate(
      laneCount,
      (l) => Logic(name: 'dqs_drive_$l'),
    );
    final dqsTriN = List.generate(laneCount, (l) => Logic(name: 'dqs_tri_$l'));
    final dqsBbs = dqsPadNet == null
        ? const <Ecp5Bb>[]
        : [
            for (var l = 0; l < laneCount; l++)
              Ecp5Bb(
                i: dqsDrive[l],
                t: dqsTriN[l],
                b: dqsPadNet[l],
                name: 'dqs_bb_$l',
              ),
          ];
    // Received DQS strobe per lane: the DIFFERENTIAL pad's read value (Bb.O), or
    // a tie-off when there is no DQS pad (SDR / no DQS configured).
    Logic dqsRecv(int l) => dqsPadNet != null ? dqsBbs[l].o : Const(0);

    // Per byte lane: one DQSBUFM (built here, ahead of BOTH the write and the
    // read datapaths, because Milestone 4 needs its WRITE strobes DQSW/DQSW270
    // to clock the x2 write ODDRs/TSHs, not just its read DQSR90). The read
    // gate (READ0/READ1) is fed by [rdGate], computed by the read FSM further
    // down. It is forward-declared here and driven there. RD/WR
    // LOADN/MOVE/DIRECTION/PAUSE stay tied to inactive defaults (training is
    // M3). READCLKSEL is the fixed [readClkSel] constant.
    final rdGate = Logic(name: 'rd_gate');
    // READCLKSEL: the build-time [readClkSel] constant on the non-trainable
    // path, or the runtime-swept [readClkSelRt] when training (litedram drives
    // this from its `rdly` read-leveling register). The read-pointer DLL
    // controls (RDLOADN/RDMOVE/RDDIRECTION) follow the same pattern: litedram's
    // defaults (LOADN=1, no move) when static, the runtime controls when
    // training.
    final readClkSelSig = trainable
        ? readClkSelRt!
        : Const(readClkSel, width: 3);
    // Read-pointer DLL. STATIC (non-trainable) uses litedram's FIXED ECP5 DDR3
    // values: RDLOADN asserted (0) so the read-delay DLL LOADS the DDRDEL
    // 90-degree code into the DQSI path, RDDIRECTION=1, no RDMOVE. (The earlier
    // RDLOADN=1/RDDIRECTION=0 left the read delay unloaded, so DQSR90 stayed
    // uncalibrated and BURSTDET never fired even with a locked DLL: the
    // on-silicon DLL=1/BDET=0 signature.) TRAINABLE: the controller drives these
    // from reg5 RDPCTL (rd_loadn active-low, rd_direction, rd_move = one MOVE
    // pulse per firmware write). rd_loadn asserted (0) still loads the DDRDEL
    // code at init. Each rd_move pulse then steps the read-FIFO pointer to
    // center the strobe on the burst. This is the read-side twin of the
    // firmware WRDLY write-pointer sweep, and is the knob the FSBL sweeps to
    // land the metastable DLL-on read eye.
    final rdLoadnSig = trainable ? rdLoadnIn! : Const(0);
    final rdMoveSig = trainable ? rdMoveIn! : Const(0);
    final rdDirSig = trainable ? rdDirIn! : Const(1);

    // The ECP5 mechanism for the write DQS delay is the DQSBUFM WRITE POINTER:
    // WRLOADN (active-low) loads the reference position, WRMOVE pulses step it,
    // WRDIRECTION picks up/down. This mirrors litex's ECP5 PHY, which steps the
    // write delay via the DQSBUFM write pointer (the WRLOADN/WRMOVE/WRDIRECTION
    // ports tied off in /tmp/ecp5ddrphy.py L279-281 because litedram does the
    // step in SOFTWARE through these same CSRs: see liblitedram/sdram.c
    // sdram_write_leveling_scan). REVIEWER/BENCH FLAG: the exact ECP5 write-
    // delay quantum per WRMOVE (DQSW phase step) is not documented as a fixed
    // ps value. The trained tap count is what the WL feedback loop selects, so
    // the absolute step size is calibrated by the loop on silicon, not assumed
    // here. WRDIRECTION=1 is taken as "increment" to match the read-pointer
    // convention. Confirm the up/down sense on the bench.
    //
    // Per lane a small stepper drives WRLOADN/WRMOVE so the pointer reaches the
    // target tap. There are TWO sources of a target tap, in PRECEDENCE order:
    //   1. Firmware WRDLY (reg7, [wrDlyTrainable]): on each [wrDlyApplyIn] edge
    //      the pointer reloads to min and steps to this lane's [wrDlyIn] nibble.
    //      This is the bring-up oracle path (firmware sweeps the write delay and
    //      reads back a written pattern). It WINS: once any WRDLY apply has fired,
    //      the auto-WL trained replay is suppressed so firmware fully owns the tap.
    //   2. Auto write-leveling ([writeLevel]): during WL ([wlEnIn]) the pointer
    //      follows the FSM rst/inc for the SELECTED lane, and after WL ([wlDoneIn])
    //      each lane replays its trained tap once.
    // Built when EITHER source is present. Otherwise the pointer stays at
    // litedram's tie-off (WRLOADN=1, no move) and the proven read path is intact.
    final wrLoadnSig = List<Logic>.generate(laneCount, (_) => Const(1));
    final wrMoveSig = List<Logic>.generate(laneCount, (_) => Const(0));
    final wrDirSig = List<Logic>.generate(laneCount, (_) => Const(0));
    if (writeLevel || wrDlyTrainable) {
      for (var l = 0; l < laneCount; l++) {
        // WL source signals (only meaningful on the writeLevel build).
        final selected = writeLevel
            ? wlLaneIn!.eq(Const(l, width: laneSelW))
            : Const(0);
        final trainedTap = writeLevel
            ? wlTrainedIn!.getRange(l * 4, l * 4 + 4)
            : Const(0, width: 4);
        // Firmware WRDLY source signals (only on the wrDlyTrainable build).
        final fwTap = wrDlyTrainable
            ? wrDlyIn!.getRange(l * 4, l * 4 + 4)
            : Const(0, width: 4);
        // Tracked pointer position and the per-lane WRLOADN/WRMOVE pulse regs
        // (shared by both sources). Only the source-specific state Logics are
        // created per source, so an off source emits NO extra RTL (keeps the
        // read-only baseline's discriminator clean).
        final pos = Logic(name: 'wr_pos_$l', width: 4);
        final loadnReg = Logic(name: 'wr_loadn_$l');
        final moveReg = Logic(name: 'wr_move_$l');
        // WL-only replay state (created only on the writeLevel build).
        final applyActive = writeLevel
            ? Logic(name: 'wr_apply_active_$l')
            : null;
        final applyDone = writeLevel ? Logic(name: 'wr_apply_done_$l') : null;
        final wlDonePrev = writeLevel ? Logic(name: 'wr_wldone_prev_$l') : null;
        // Firmware-WRDLY apply edge detect + stepper state (only on wrDlyTrainable).
        final fwApplyPrev = wrDlyTrainable
            ? Logic(name: 'wr_fw_apply_prev_$l')
            : null;
        final fwActive = wrDlyTrainable ? Logic(name: 'wr_fw_active_$l') : null;
        // Sticky: a firmware WRDLY apply has fired -> suppress the WL replay so
        // the firmware tap permanently wins. Only meaningful when both sources
        // coexist. Created on the wrDlyTrainable build.
        final fwOwned = wrDlyTrainable ? Logic(name: 'wr_fw_owned_$l') : null;
        Sequential(
          sclk,
          reset: sclkReset,
          resetValues: {
            pos: Const(0, width: 4),
            loadnReg: Const(1),
            moveReg: Const(0),
            // Re-arm the apply-once trained-tap replay on every reset. Without
            // these, a soft sclkReset after the first write-leveling run leaves
            // applyDone=1 / wlDonePrev stale, so a re-init silently SKIPS replaying
            // the trained DQS write delay and writes use an untrained tap.
            if (writeLevel) applyActive!: Const(0),
            if (writeLevel) applyDone!: Const(0),
            if (writeLevel) wlDonePrev!: Const(0),
            if (wrDlyTrainable) fwApplyPrev!: Const(0),
            if (wrDlyTrainable) fwActive!: Const(0),
            if (wrDlyTrainable) fwOwned!: Const(0),
          },
          [
            // Default: deassert the pulses each cycle.
            loadnReg < 1,
            moveReg < 0,
            if (writeLevel) wlDonePrev! < wlDoneIn!,
            if (wrDlyTrainable) fwApplyPrev! < wrDlyApplyIn!,
            // On the apply toggle edge, reload to MIN (pos<0, loadnReg<0) then step
            // [fwTap] WRMOVE pulses, so reg7 sets the write pointer to tap N from
            // min. Latch fwOwned so the WL replay below stays suppressed.
            if (wrDlyTrainable) ...[
              If(
                wrDlyApplyIn! ^ fwApplyPrev!,
                then: [fwActive! < 1, fwOwned! < 1, loadnReg < 0, pos < 0],
              ),
              If(
                fwActive,
                then: [
                  If(
                    pos.lt(fwTap),
                    then: [moveReg < 1, pos < pos + 1],
                    orElse: [fwActive < 0],
                  ),
                ],
              ),
            ],
            // Suppressed entirely once firmware owns the tap (fwOwned), AND on the
            // exact cycle a firmware apply edge fires (fwOwned latches next cycle,
            // so also gate on the live edge so the firmware reload/step is never
            // clobbered by a coincident WL action in that one cycle).
            if (writeLevel)
              If(
                wrDlyTrainable
                    ? (~fwOwned! & ~(wrDlyApplyIn! ^ fwApplyPrev!))
                    : Const(1),
                then: [
                  If(
                    wlEnIn!,
                    then: [
                      // During WL: this lane's pointer follows the FSM rst/inc for the
                      // SELECTED lane only (the others hold). WRLOADN loads min on rst.
                      If(selected & wlRstIn!, then: [loadnReg < 0, pos < 0]),
                      If(
                        selected & wlIncIn!,
                        then: [moveReg < 1, pos < pos + 1],
                      ),
                    ],
                    orElse: [
                      // After WL completes: replay the trained tap once. On the rising
                      // edge of wlDone, load min then step `trainedTap` WRMOVE pulses.
                      If(
                        wlDoneIn! & ~wlDonePrev! & ~applyDone!,
                        then: [applyActive! < 1, loadnReg < 0, pos < 0],
                      ),
                      If(
                        applyActive,
                        then: [
                          If(
                            pos.lt(trainedTap),
                            then: [moveReg < 1, pos < pos + 1],
                            orElse: [applyActive < 0, applyDone < 1],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
          ],
        );
        wrLoadnSig[l] = loadnReg;
        wrMoveSig[l] = moveReg;
        // WRDIRECTION: the proven hardcoded INCREMENT sense (1). Both the WL
        // replay and the reg7 WRMOVE walk the pointer UP from load-min, so the
        // direction is always increment (the ddrshift word0-dominant state).
        wrDirSig[l] = Const(1);
      }
      // Observability: the per-lane WRMOVE / WRLOADN pulses, packed one bit per
      // byte lane. Sim-visible fabric (the same nets feeding the DQSBUFM), so a
      // test can count the WRMOVE pulses for a reg7 write even though the DQSBUFM
      // leaf is X.
      addOutput('wr_move_dbg', width: laneCount) <= wrMoveSig.rswizzle();
      addOutput('wr_loadn_dbg', width: laneCount) <= wrLoadnSig.rswizzle();
    }

    // Per-lane DQSBUFM edge clock. DLL-ON the eclk also drives the x2 DQ IOLOGIC
    // (IDDRX2DQA/ODDRX2DQA) in BOTH byte-lane banks, so nextpnr promotes the
    // single clock-tree ddr_eclk to both bank ECLK0 spines and one ECLKSYNCB
    // serves every lane. Share it untouched. DLL-OFF the DQ runs on clk90 (x1
    // IDDRX1F/ODDRX1F), so the ONLY eclk sinks are these DQSBUFMs. With no
    // gearing IOLOGIC nextpnr does NOT promote, it BEL-locks the clock tree's
    // ECLKSYNCB to ONE bank, and the OTHER byte lane's DQS pad sits in the other
    // bank (OrangeCrab: DQS0 bank 6, DQS1 bank 7), so its DQSBUFM.ECLK is
    // unreachable ("Failed to find a route for arc 1 of net ddr_eclk"). Give
    // EACH lane its OWN ECLKSYNCB off the same source clock so nextpnr pins each
    // to its DQSBUFM's bank and routes locally. The DQS read strobes are unused
    // DLL-off (static-tap read), so these are clock-distribution-only buffers.
    final dqsEclk = <Logic>[
      for (var l = 0; l < laneCount; l++)
        dllOn
            ? eclk
            : Ecp5Eclksyncb(
                eclki: clk,
                stop: initEclkStop,
                name: 'dqs_eclksync_$l',
              ).eclko.named('ddr_dqs_eclk_$l'),
    ];

    // RDPNTR-ALIGN read-block reset. DLL-ON: the init-FSM [initRdReset] (held
    // asserted through the stop/reset/ALIGNWD/DDRDEL bounce, released once at the
    // new phase-12 step inside PAUSE-high after DDRDEL calibration): this is the
    // deterministic beat-0 pin for the DQSBUFM read-FIFO pointer. It is ORed with
    // the plain [sclkReset] so a system reset still forces the read block into
    // reset (initRdReset alone reflects only the init timeline). DLL-OFF: plain
    // [sclkReset] EXACTLY as before (no DQSR90/DDRDEL/RDPNTR gearbox on the x1
    // static-tap path), so the DLL-off netlist stays BYTE-IDENTICAL. [dllOn] is a
    // build-time const, so exactly one branch elaborates. BOTH the DQSBUFM AND its
    // read IDDRX2DQA cells use THIS signal so they leave reset on the SAME edge -
    // a split release would re-desync the 1:4 gather from the pointer.
    // DLL-OFF returns the RAW [sclkReset] with NO rename, so the emitted netlist
    // is BYTE-IDENTICAL (no extra ddr_rd_reset net). Only the DLL-on branch
    // introduces the new gated reset net.
    //
    // CDC HARDENING (rtl-reviewer follow-up): [initRdReset] is a [clk]-domain
    // (CK-rate) flop, but it feeds the sclk/eclk-clocked DQSBUFM/IDDRX2DQA RST.
    // Its RELEASE edge (1->0 at phase 12) is thus a clk->sclk crossing on a reset
    // DEASSERT = a removal/recovery window. Retime it through a 2-flop sclk
    // synchronizer whose reset-value is 1 (stay-asserted), matching the
    // [sclkReset] sync-deassert idiom: the read block stays in reset until the
    // deassert has propagated cleanly through two sclk edges, so the release edge
    // the pointer/gather see is sclk-clean (no metastable removal). The FSM holds
    // [initRdReset] high for many sclk cycles before phase 12 and PAUSE stays high
    // through phase 13, so the 2-flop latency is comfortably absorbed and the
    // block is still out of reset well before initDone gates the first read.
    // dllOn-only, so dllOff stays byte-identical.
    final Logic dqsReadReset;
    if (dllOn) {
      final rdResetSync = Logic(name: 'ddr_rd_reset_sync', width: 2);
      Sequential(
        sclk,
        reset: sclkReset,
        resetValues: {
          rdResetSync: Const(3, width: 2), // both stages start ASSERTED (=1)
        },
        [
          rdResetSync < [rdResetSync[0], initRdReset].swizzle(),
        ],
      );
      // sclk-synchronized read-block reset: system reset OR the sync-deasserted
      // init read reset. Named so the netlist check + waveforms can find it.
      dqsReadReset = (sclkReset | rdResetSync[1]).named('ddr_rd_reset');
    } else {
      dqsReadReset = sclkReset;
    }

    final dqsBufs = <Ecp5Dqsbufm>[
      for (var l = 0; l < laneCount; l++)
        Ecp5Dqsbufm(
          dqsi: dqsRecv(l),
          read0: rdGate,
          read1: rdGate,
          readclksel: readClkSelSig,
          ddrdel: clkTree.ddrdel,
          eclk: dqsEclk[l],
          sclk: sclk,
          rst: dqsReadReset,
          rdloadn: rdLoadnSig, // active-low: no read-delay load (default)
          rdmove: rdMoveSig,
          rddirection: rdDirSig,
          wrloadn: wrLoadnSig[l],
          wrmove: wrMoveSig[l],
          wrdirection: wrDirSig[l],
          // DQSBUFM PAUSE is driven by the init FSM: held high across the
          // DDRDEL-load update pulse (litedram L98-101 / ecp5ddrphy L272,
          // i_PAUSE = self.init.pause | dly_sel). The per-lane dly_sel read
          // training overlay is M3. Here the init pause alone gates PAUSE.
          pause: initPause,
          // Firmware DQS-DELAY TRIM: drive THIS lane's 8-bit DYNDELAY (the
          // per-byte-lane DQS-delay) from [wrTrimIn][8*l +: 8], each lane is
          // independently swept so every DQS group centers its own read/write
          // strobe. DYNDELAY is per-LANE (shifts the whole DQS strobe), so this
          // moves both the read capture (DQSR90) and the write launch for lane l.
          // Quasi-static, so the Lattice PAUSE-4T requirement around a DYNDELAY
          // change is met (the trim is set and settled well before any strobe).
          dyndelay: writeTrimTrainable
              ? wrTrimIn!.getRange(8 * l, 8 * l + 8)
              : null,
          name: 'dqsbuf_$l',
        ),
    ];
    // Observability for the read-strobe-centering knobs. The DQSBUFM leaf is X
    // in sim (its DQSR90 / RDPNTR are unmodelled), so the READ eye landing is
    // only provable on hardware. But the CONTROL nets feeding the DQSBUFM
    // read-pointer (RDMOVE/RDLOADN/RDDIRECTION) and the per-lane DYNDELAY are
    // plain fabric and sim-visible: mirror them out so a test can witness that
    // a reg5 RDMOVE pulse and a reg8 per-lane DYNDELAY value actually REACH the
    // DQSBUFM (the wiring the earlier revision left dangling). Only on the
    // trainable build (the read-pointer sweep exists only there).
    if (trainable) {
      addOutput('rd_move_dbg') <= rdMoveSig;
      addOutput('rd_loadn_dbg') <= rdLoadnSig;
      addOutput('rd_direction_dbg') <= rdDirSig;
      if (writeTrimTrainable) {
        addOutput('rd_dyndelay_dbg', width: wrTrimW) <= wrTrimIn!;
      }
    }
    // Expose lane 0's read status (sclk domain) for the controller's STATUS
    // register. Tie off when there is no DQS lane (SDR / no DQS configured).
    //
    // SIM-DEFINEDNESS GATE: DATAVALID/BURSTDET are DQSBUFM SystemVerilog-leaf
    // outputs (X in simulation, real on hardware). They are only ELECTRICALLY
    // MEANINGFUL while the DQS read gate ([rdGate]) is open (the part drives
    // DATAVALID/BURSTDET off the gated read strobe), so gating the fabric copy
    // with [rdGate] is a functional identity on hardware (the bits already read
    // 0 outside a read window). In simulation [rdGate] is a DEFINED fabric
    // signal (0 whenever no read is in flight, as during the firmware STATUS
    // tap-walk poll), and `0 & x == 0` in ROHD, so the X-prone leaf bit
    // collapses to a defined 0. This keeps the STATUS word the CPU loads fully
    // defined in sim (the [12:8] observability slot reads 0) so the load does
    // not amplify a leaf X across the whole register, while the hardware
    // behavior is unchanged (during a real read [rdGate] is 1 and the true
    // DATAVALID/BURSTDET passes through). [rdGate] is forward-declared above and
    // driven by the read FSM further down.
    // DLL-OFF (the x1 IDDRX1F/ODDRX1F datapath): the DDRDLLA never locks, so the
    // DQSBUFM DATAVALID/BURSTDET outputs are DEAD (no calibrated read strobe). The
    // x1 read capture is timed off the fabric pipe + the static DELAYG tap, NOT
    // DATAVALID, so force these status bits to a defined 0 and drop the dead leaf
    // dependency. DLL-on keeps the rdGate-gated DQSBUFM status byte-identically.
    final liveDataValid = (dllOn && dqsBufs.isNotEmpty)
        ? (dqsBufs[0].datavalid & rdGate)
        : Const(0);
    final liveBurstDet = (dllOn && dqsBufs.isNotEmpty)
        ? (dqsBufs[0].burstdet & rdGate)
        : Const(0);
    output('rd_datavalid') <= liveDataValid;
    output('rd_burstdet') <= liveBurstDet;

    // NOTE: the DQSBUFM RDPNTR/WRPNTR outputs are NOT exposed to fabric. On the
    // ECP5 those pointer ports can only drive the IDDRX2DQA read cell. Nextpnr
    // refuses to pack them onto a general TRELLIS_FF ("RDPNTR0 cannot drive
    // DI"). So read-FIFO pointer observability is not available via the status
    // register. DLL_LOCK + the sticky BURSTDET/DATAVALID flags below carry the
    // DQS-read diagnosis.

    // Sticky "ever seen" latches in the sclk domain. Set on the first cycle the
    // live flag is high, hold until reset. On hardware this captures a transient
    // BURSTDET/DATAVALID pulse the firmware bus-clock poll would otherwise miss.
    // They capture the [rdGate]-gated [liveBurstDet]/[liveDataValid] above, which
    // are defined 0 in simulation (the gate collapses the X-prone leaf bit), so
    // these latches stay a defined 0 in sim and read real on hardware.
    final burstDetSeen = Logic(name: 'ddr_burstdet_seen');
    final dataValidSeen = Logic(name: 'ddr_datavalid_seen');
    // Firmware CLEAR (one-sclk pulse, quasi-static-toggle-edged in ddr.dart) wins
    // over a coincident set so a clear reliably arms the next read-level step. A
    // real BURSTDET on the SAME cycle as a clear re-sets next cycle (the live flag
    // is still high), so a genuine assertion is never lost. Non-trainable build:
    // bdetClearIn is null -> the clear term is absent -> byte-identical set-only.
    final bdetClr = trainable ? bdetClearIn! : Const(0);
    Sequential(sclk, reset: sclkReset, [
      If(
        bdetClr,
        then: [burstDetSeen < liveBurstDet, dataValidSeen < liveDataValid],
        orElse: [
          If(liveBurstDet, then: [burstDetSeen < 1]),
          If(liveDataValid, then: [dataValidSeen < 1]),
        ],
      ),
    ]);
    output('rd_burstdet_seen') <= burstDetSeen;
    output('rd_datavalid_seen') <= dataValidSeen;
    // NOTE: a fabric DQS-toggle detector is NOT possible on the ECP5: nextpnr
    // requires "DQSBUFM DQSI connected only to a top level input", so the
    // received DQS (dqsRecv) cannot fan out to an observation flop. Whether DQS
    // is actually toggling at the pad can only be checked with a scope.

    // Everything below (write engine, DQ/DM/DQS x2 IOLOGIC, diagnostics, x2 read
    // engine) is the DLL-ON path, BYTE-IDENTICAL to before. DLL-OFF takes the x1
    // branch in the matching `else` at the end of the constructor (the proven
    // pre-Milestone-4 IDDRX1F/ODDRX1F-on-clk90 datapath, which is what nextpnr can
    // pack on a bidirectional pad). [dllOn] is a build-time const, so only one
    // branch elaborates.
    if (dllOn) {
      // Write engine.
      // wrStart pulses at the WRITE command. Data must be on the pins CWL
      // cycles later for the BL8 burst (2 sclk "chunks" in halfrate). Mirrors
      // litedram's single-tap-base model (litex ecp5ddrphy.py "Write Control
      // Path", L437-460): ONE write-enable delay line off wrStart, and the
      // data-chunk select, the DQ/DQS output-enable, and the DQS preamble /
      // postamble all derive from one base tap `wrtap = cwl_sys_latency`.
      //
      // CWL is a DDR CK number, but the launch pipe is clocked on sclk = CK/2
      // (halfrate). So CWL must be converted from CK cycles to sclk taps the
      // SAME way litedram derives cwl_sys_latency = get_sys_latency(nphases=2,
      // cwl) (ecp5ddrphy.py L143, used as `wrtap` at L438). For CWL=6 that is 3
      // sclk cycles. This is the write-side twin of the read-side clSys =
      // (cl + 1) ~/ 2 conversion below. The write side never got it, which is
      // why the launch was misderived. There is NO separate oddrLatency offset:
      // litedram keys EVERYTHING off `wrtap`, so we do too.
      final cwlSys =
          (cwl + 1) ~/ 2; // = 3 = get_sys_latency(2, 6); twin of clSys
      // The +1 OPTION-A launch slide cancels a DLL-ON (high-CK, e.g. 144MHz) +2-word
      // write rotation that is a DLL-on launch artifact and does NOT occur DLL-off
      // (~48MHz osc rate). Gate it on the CK rate: shift only when the DRAM DLL is
      // engaged. DLL-off (clkMhz ~ 48) -> wrShift 0 = the proven pre-OPTION-A timing
      // (data cwlSys..cwlSys+1, preamble cwlSys-1, postamble cwlSys+2). DLL-on
      // (clkMhz >= ~144) -> wrShift 1 = OPTION A. Unconditional shift mis-aligns the
      // 48MHz write (word0 lands a tap late -> ddrtest E0). [dllOn] is defined once
      // up near the clock tree (it also selects the static x2 DDR datapath).
      // Write-launch tap offset (OPTION A = 1). BENCH: env WRSHIFT sweeps it to
      // find the slide that lands the write on this silicon (the write twin of the
      // read-gate offset). DLL-off keeps 0.
      final wrShift = dllOn
          ? int.parse(Platform.environment['WRSHIFT'] ?? '1')
          : 0;
      // litedram ntaps = wrtap + 4 (ecp5ddrphy.py L447). One delay line. Taps
      // wrtap..wrtap+1 are the two data cycles, wrtap-1 / wrtap+2 frame the
      // preamble / postamble. OPTION A slides the window +1 tap (data at cwlSys+1..
      // cwlSys+2, postamble at cwlSys+3), so the pipe is grown to cwlSys+5 (highest
      // tap cwlSys+4) to keep the shifted postamble (cwlSys+3) in range with the
      // same one-tap headroom the original had.
      final wrEn = Logic(name: 'wr_en', width: cwlSys + 5);
      final wrWord = Logic(name: 'wr_word', width: 32);
      final wrSel = Logic(name: 'wr_sel', width: 4);
      final wrBeat = Logic(name: 'wr_beat', width: 2);
      Sequential(sclk, reset: sclkReset, [
        wrEn < [wrEn.getRange(0, cwlSys + 4), wrStart].swizzle(),
        If(wrStart, then: [wrWord < wrData, wrSel < wrMask, wrBeat < beatSel]),
      ]);

      // An ECP5 DQ pad's input and output IOLOGIC must share gearing. The M2 read
      // uses IDDRX2DQA (MIDDRX/x2), so the write MUST go x2 too (MODDRX), or
      // nextpnr pack fails with "conflicting modes IDDRX1_ODDRX1 / MIDDRX_MODDRX".
      // The x1 ODDRX1F write path (DQ/DM/DQS) is replaced by ODDRX2DQA /
      // ODDRX2DQSB clocked by the DQSBUFM write strobes (DQSW270 for data, DQSW
      // for the strobe) and TSHX2DQA / TSHX2DQSA for the pad tristate, exactly as
      // litex's ECP5DDRPHY wires them.
      //
      // Write gearing (the INVERSE of the M2 read gather): one ODDRX2DQA presents
      // 4 sub-beats (D0..D3) per sclk, so a BL8 (8-beat) burst is two sclk
      // "chunks": chunk 0 = beats 0..3 (beat-pairs 0,1), chunk 1 = beats 4..7
      // (beat-pairs 2,3). The sequencer contract is UNCHANGED: it issues one
      // 32-bit word [wrData] = {fall(high16), rise(low16)}, the byte mask
      // [wrSel](4), and [wrBeat] = which of the 4 beat-pairs (0..3) holds it. The
      // other three pairs are DM-masked. We map that latched word into the right
      // D-slot of the right chunk:
      //   beat-pair p -> chunk p[1], slots {D0,D1} if p[0]==0 else {D2,D3}
      //     rise(low16) -> the even slot, fall(high16) -> the odd slot.
      // [wrChunk] walks 0,1 across the two-cycle data window, derived DIRECTLY
      // from the wrEn taps so it is cycle-aligned to the OE by construction (the
      // prime fix). litedram drives data-chunk select and OE from the SAME taps:
      // bl8_chunk = taps[wrtap] (ecp5ddrphy.py L452), dq_oe = taps[wrtap] |
      // taps[wrtap+1] (L451). Tap[cwlSys] is the first data cycle (chunk 0, beats
      // 0..3). Tap[cwlSys+1] is the second (chunk 1, beats 4..7).
      //   wrData2 = "a data chunk is being presented this cycle" (2 sclk wide,
      //             exactly the OE window).
      //   wrChunk = 1 on the second data cycle (beats 4..7).
      // WRITE-LAUNCH TAP SHIFT (+2-rotation fix, write-cal OPTION A): on this
      // silicon the DRAM captures the SECOND OE/data cycle first (a CWL/launch
      // offset of one sclk word: the write twin of the read-gate offset), so the
      // FPGA's chunk0 (words 0,1) lands 4 beats early and the readback is a +2-word
      // rotation. FIX: slide the WHOLE data + OE + DQS-preamble/postamble window ONE
      // tap LATER so chunk0 rides the DRAM's burst-start beats. The beatVec assembly,
      // the DM loEn/hiEn, and pairInChunk are UNCHANGED (proven internally
      // consistent): only the launch-timing taps move. wrData2/wrChunk reference
      // taps [cwlSys+1]/[cwlSys+2] (was [cwlSys]/[cwlSys+1]), oeWindow=wrData2 and
      // oeDqs=oeWindow so the DQ OE + DQS OE slide WITH the data automatically.
      final wrData2 = (wrEn[cwlSys + wrShift] | wrEn[cwlSys + 1 + wrShift])
          .named('wr_data2');
      final wrChunk = wrEn[cwlSys + 1 + wrShift].named('wr_chunk');
      // Per-lane DQS write strobes from the DQSBUFM (one per byte lane). These are
      // referenced ONLY on the DLL-ON path: the DQSBUFM-bonded write primitives
      // (ODDRX2DQA / ODDRX2DQSB / TSHX2DQA / TSHX2DQSA) require a DQSW/DQSW270 port
      // driven by a DQSBUFM (nextpnr enforces this at pack). The DLL-OFF path uses
      // ONLY generic IOLOGIC (ODDRX2F + plain registered pad tristate) with NO
      // DQSBUFM port anywhere, so it never calls these helpers.
      Logic dqsw(int lane) => dqsBufs[lane].dqsw;
      Logic dqsw270(int lane) => dqsBufs[lane].dqsw270;

      // Does the selected beat-pair fall in the CURRENT chunk?
      // beat-pair = {wrBeat}, its chunk = wrBeat[1], its slot-pair = wrBeat[0].
      // UNCHANGED (proven internally consistent): the DM uses the SAME [wrChunk] as
      // the DATA chunkBeat mux below. The OPTION A fix only slides the launch taps
      // that derive wrChunk/wrData2, not the chunk identity logic.
      final pairInChunk = (wrBeat[1].eq(wrChunk)) & wrData2;
      // rise/fall half-words of the latched write word.
      final dqRise = wrWord.getRange(0, dataBits);
      final dqFall = wrWord.getRange(dataBits, 32);

      // Harbor does single-WORD masked writes: the latched [wrWord] is ONE of the
      // four 32-bit fabric words of the 16-byte BL8 line, [wrBeat] = which word
      // (0..3), and only that word's two beats are unmasked (the rest DM-masked).
      // The OLD ODDR feed was a SHORTCUT: it drove rise/fall REPLICATED into both
      // slot-pairs (D0=D2=rise, D1=D3=fall) and let DM alone pick the beat. That
      // floats the per-bit RISE beat on the un-written beats (DQ1/DQ5/DQ9 read
      // stuck-HIGH when written 0: the bit goes HiZ and the DRAM samples its
      // ODT-parked-high level). litedram instead drives 4 DISTINCT beats per chunk
      // with a SLIDING registration. Mirror it for the masked single-word case:
      //
      //   1. Assemble the BL8 8-beat array per DQ bit, where the WRITTEN word's two
      //      beats carry {rise, fall} and the other six beats are 0. Word w (=
      //      [wrBeat]) occupies beats [2w, 2w+1] (word0->0,1 .. word3->6,7). Within
      //      a pair the EVEN beat is rise(low16), the ODD beat is fall(high16). Held
      //      as eight [dataBits]-wide beat vectors (beatVec[n], bit i = beat n of DQ
      //      bit i) so the per-bit ODDR feed below just indexes [i].
      //   2. Register it one sclk (beatVecD <= beatVec): litedram dq_o_data_d.
      //   3. Per-chunk sliding mux: chunk 0 takes beats 0..3 from the CURRENT
      //      assembly, chunk 1 takes beats 4..7 from the REGISTERED (previous-cycle)
      //      assembly. This sliding registration is the litedram dq_o_data_muxed
      //      step (chunk0: dq_o_data[0:4], chunk1: dq_o_data_d[4:8]) and is what the
      //      old replicated shortcut lacked.
      // DM still masks the non-written beats (the DM ODDR keeps its own sliding mux
      // below). The OE/TSH/DQS path is unchanged. Only the DQ DATA ODDR feed and
      // this 8-beat assembly + registration are new.
      Logic beatVec(int n) {
        final p = n ~/ 2; // beat-pair (= which word) this beat belongs to
        final isRise =
            n.isEven; // even beat = rise(low16), odd beat = fall(high16)
        return mux(
          wrBeat.eq(Const(p, width: 2)),
          isRise ? dqRise : dqFall,
          Const(0, width: dataBits),
        ).named('wr_beatvec_$n');
      }

      final dqBeats = [for (var n = 0; n < 8; n++) beatVec(n)];
      // Chunk mux -> the four ODDR D-slots. chunk0 (wrChunk=0) -> beats 0..3,
      // chunk1 (wrChunk=1) -> beats 4..7. BOTH from the CURRENT (held) transaction.
      //
      // HW-MEASURED BUG FIX (2026-06-30, OrangeCrab creek): the litedram sliding
      // registration used a PREVIOUS-sclk copy (dqBeatsD) as the chunk-1 source,
      // because litedram streams a CONTINUOUS 4-word burst whose data differs every
      // cycle, so chunk-1's beats 4..7 legitimately arrive one sclk after chunk-0's
      // 0..3. But Harbor issues ONE masked word per write transaction and HOLDS
      // [wrWord] stable across the whole burst (latched at wrStart, unchanged until
      // the next wrStart). So the previous-sclk register held a DIFFERENT
      // transaction's data, which bled into words 2/3 (chunk 1). A counting-pattern
      // readback on silicon showed exactly this: the readback rotated per write
      // burst with a ONE-PASS stale lag (column-0 == the prior pass's value). Using
      // the CURRENT beats for both chunks is identical during a valid held burst
      // (the word is stable, so current == registered mid-burst) and removes the
      // cross-transaction stale leak. dqBeatsD deleted.
      Logic chunkBeat(int slot) => mux(
        wrChunk,
        dqBeats[4 + slot],
        dqBeats[slot],
      ).named('wr_chunkbeat_$slot');
      // WRITE-BEAT SLIP (env WRBEATSLIP 0..3): delay the whole write burst by
      // `slip` DDR beats (= slip*0.5 CK) to center the CWL 6/7 half-CK straddle
      // (the write lands 1 beat off, HW-measured). The wrapped head beats come from
      // the previous sclk word (registered). Applied IDENTICALLY to DATA, DQS, DM
      // so they stay phase-locked (DRV/eye unchanged). slip=0 = exact identity.
      // PER-LANE write-beat slip: each byte lane slips independently (env
      // WRBEATSLIP<l>, falling back to the global WRBEATSLIP, then 0). The global
      // slip3 landed only ONE 16-bit lane (the two byte lanes want slightly
      // different DQS-vs-CK alignment). Per-lane lets each lane's half-CK offset
      // be corrected separately. DQS + DM are already per-lane structures. The
      // DATA vector is split into byte lanes here. All-lanes-equal == the old
      // global slip (so WRBEATSLIP=3 reproduces the prior behavior exactly).
      final wrBeatSlipLane = [
        for (var l = 0; l < laneCount; l++)
          int.parse(
            Platform.environment['WRBEATSLIP$l'] ??
                Platform.environment['WRBEATSLIP'] ??
                '0',
          ),
      ];
      // Slip 4 beats by `slip` DDR beats, wrapping the head from the previous sclk
      // word (registered). slip=0 = exact identity.
      List<Logic> beatSlipBy(List<Logic> beats, int slip, String nm) {
        if (slip == 0) return beats;
        final prev = [
          for (var k = 0; k < 4; k++)
            Logic(name: '${nm}_slipprev$k', width: beats[k].width),
        ];
        Sequential(sclk, reset: sclkReset, [
          for (var k = 0; k < 4; k++) prev[k] < beats[k],
        ]);
        // new beat p = old beat (p-slip), wrapping to the previous word's tail.
        return [
          for (var p = 0; p < 4; p++)
            (p >= slip ? beats[p - slip] : prev[4 - slip + p]),
        ];
      }

      // DATA: split each beat into 8-bit byte lanes, slip each lane by its own
      // amount, recombine. When all lanes share one value this is bit-identical to
      // slipping the whole vector (the old global path).
      final dqBeatsRaw = [
        chunkBeat(0),
        chunkBeat(1),
        chunkBeat(2),
        chunkBeat(3),
      ];
      final List<Logic> dqDslip;
      if (wrBeatSlipLane.every((s) => s == 0)) {
        dqDslip = dqBeatsRaw;
      } else {
        final perLane = List.generate(
          laneCount,
          (l) => beatSlipBy(
            [for (var p = 0; p < 4; p++) dqBeatsRaw[p].slice(8 * l + 7, 8 * l)],
            wrBeatSlipLane[l],
            'wr_dq_l$l',
          ),
        );
        // beat p = {laneN-1 ... lane0} of the per-lane-slipped beats.
        dqDslip = [
          for (var p = 0; p < 4; p++)
            [for (var l = laneCount - 1; l >= 0; l--) perLane[l][p]].swizzle(),
        ];
      }
      final dqD0 = dqDslip[0];
      final dqD1 = dqDslip[1];
      final dqD2 = dqDslip[2];
      final dqD3 = dqDslip[3];

      // T0/T1 are active-LOW at the TSH inputs (T=0 -> drive, T=1 -> HiZ). The
      // TSH `Q` is the REGISTERED pad tristate, active-HIGH HiZ: exactly the
      // polarity an Ecp5Bb `T` pin wants, so Q wires straight to Bb.T with NO
      // fabric inverter (the nextpnr packing rule).
      //
      // litedram: dq_oe = wrdata_en.taps[wrtap] | wrdata_en.taps[wrtap + 1]
      // (ecp5ddrphy.py L451): exactly 2 sclk wide and CYCLE-ALIGNED to the
      // data-chunk select (bl8_chunk = taps[wrtap], L452). The old wrActiveD2..D4
      // window was 3 cycles wide AND started 2 cycles after the data window, so
      // the FIRST BL8 chunk launched while DQ was still Hi-Z (the DRAM sampled
      // nothing: the prime root cause, delay-independent). Now OE == wrData2:
      // the same two taps that select the data, so DQ/DQS drive exactly when the
      // data is presented.
      final oeWindow = wrData2.named(
        'wr_oe_win',
      ); // = wrEn[cwlSys+1] | wrEn[cwlSys+2] (shifted)
      // DQS write preamble / postamble (litedram L459-460): a driven-low DQS
      // cycle before the first write (JEDEC DDR3 needs ~1 CK preamble so the DRAM
      // arms its strobe capture) and one after the last. They straddle the OE
      // window by one tap on each side. SHIFTED +1 with the OPTION A launch slide so
      // they keep bracketing the now-later data window (preamble one tap before the
      // new window-open at cwlSys+1, postamble one tap after the new close at
      // cwlSys+2).
      //   preamble  = taps[wrtap] & ~taps[wrtap+1]     (was wrtap-1 & ~wrtap)
      //   postamble = taps[wrtap+3] & ~taps[wrtap+2]   (was wrtap+2 & ~wrtap+1)
      final dqsPreamble = (wrEn[cwlSys - 1 + wrShift] & ~wrEn[cwlSys + wrShift])
          .named('wr_dqs_preamble');
      final dqsPostamble =
          (wrEn[cwlSys + 2 + wrShift] & ~wrEn[cwlSys + 1 + wrShift]).named(
            'wr_dqs_postamble',
          );
      // DQ tristate (active-low at the TSH). Forced to HiZ (T=1) across the whole
      // WL phase so DQ stays an INPUT and the DRAM's WL feedback can drive it back.
      //
      final wlEnPhy = writeLevel ? wlEnIn! : Const(0);
      final dqTN = (writeLevel ? (~oeWindow | wlEnPhy) : ~oeWindow).named(
        'dq_tristate_n',
      );
      // DQS base output-enable: litedram dqs_oe = dq_oe (ecp5ddrphy.py L453), so
      // the DQS OE window IS the same 2-tap oeWindow as DQ.
      final oeDqs = oeWindow;
      // DQS pad tristate: the two TSHX2DQSA phases are SPLIT to add the
      // preamble / postamble (litedram L322-323):
      //   T0 = ~(dqs_oe | dqs_postamble)
      //   T1 = ~(dqs_oe | dqs_preamble)
      // The preamble extends the DRIVEN window one sclk cycle EARLY (the DRAM
      // arms on a clean low DQS), the postamble one cycle LATE. DQ has no
      // preamble, so the DQ TSH stays on the plain oeWindow (dqTN) below.
      final dqsTN0 = (~(oeDqs | dqsPostamble)).named('dqs_tristate_n0');
      final dqsTN1 = (~(oeDqs | dqsPreamble)).named('dqs_tristate_n1');
      // Per-lane DQS output-enable during WL (FIX 2: drive DQS LOW through the
      // preamble, do not float). JEDEC tWLDQSEN requires DQS DRIVEN LOW before the
      // first rising strobe so the DRAM's WL detector sees a clean preamble. So for
      // the SELECTED lane the OE is OPEN for the WHOLE WL scan ([wlEn]), not gated
      // on the strobe: DQS = driven-0 in the preamble (the ODDR pattern is held 0
      // outside the strobe window, see the DQS drive section), then the single
      // rising strobe edge. Other lanes stay HiZ. Outside WL fall back to the
      // split T0/T1 (which carry the preamble/postamble). Returns the (T0, T1)
      // pair so each phase keeps its distinct preamble/postamble tap.
      ({Logic t0, Logic t1}) dqsTriNForLane(int l) {
        if (!writeLevel) return (t0: dqsTN0, t1: dqsTN1);
        final selected = wlLaneIn!.eq(Const(l, width: laneSelW));
        // Active-low TSH tristate: 0 = drive. Selected lane drives for the whole
        // WL scan. The PATTERN (not the OE) is gated so the preamble is driven 0.
        final wlDqsOe = selected.named('wl_dqs_oe_$l');
        final t0 = mux(wlEnPhy, ~wlDqsOe, dqsTN0).named('dqs_tristate_n0_$l');
        final t1 = mux(wlEnPhy, ~wlDqsOe, dqsTN1).named('dqs_tristate_n1_$l');
        return (t0: t0, t1: t1);
      }

      // DQ: per bit, an ODDRX2DQA clocked by the lane's DQSW270 produces the drive
      // value, a per-bit TSHX2DQA produces the pad tristate, and a per-bit Ecp5Bb
      // ties them to the bidirectional pad. Per-bit TSH (not one shared) because
      // nextpnr requires each TSH `Q` to drive EXACTLY ONE pad tristate `T`
      // (net_only_drives is exclusive), matching litex's per-DQ-bit TSHX2DQA.
      //
      // The ODDR D0..D3 carry the 4 DISTINCT chunk beats ([dqD0..dqD3], the
      // litedram sliding-chunk assembly above), NOT the old rise/fall-replicated
      // shortcut. Each D-slot holds the SPECIFIC beat's data (0 where this chunk's
      // beat is not the written word), and the chunk-1 source is the REGISTERED
      // previous cycle. DM still masks the non-written beats. This removes the
      // per-bit rise-beat FLOAT that left DQ1/DQ5/DQ9 HiZ (stuck-high) on a
      // write-0.
      // DLL-OFF generic DQ pad tristate. TSHX2DQA is DQSBUFM-bonded (its DQSW270
      // port MUST be driven by a DQSBUFM, which nextpnr enforces at pack), so it
      // cannot be used on the strobe-free DLL-off path. Instead the DQ pad is a
      // plain bidirectional output: a single sclk-REGISTERED active-high HiZ enable
      // (= the same [dqTN] window the TSH would have carried) drives every DQ
      // Ecp5Bb `.t` directly. sclk resolution is sufficient DLL-off (the OE just
      // brackets the whole write-data window). NO DQSBUFM port anywhere. Built only
      // when !dllOn ([dllOn] is a build-time const).
      final dqReadBits = <Logic>[];
      for (var i = 0; i < dataBits; i++) {
        final lane = i ~/ 8;
        final dqDrive = Ecp5Oddrx2dqa(
          d0: dqD0[i],
          d1: dqD1[i],
          d2: dqD2[i],
          d3: dqD3[i],
          dqsw270: dqsw270(lane),
          sclk: sclk,
          eclk: eclk,
          // IOLOGIC one-LSR rule: a DQ PIO packs its write ODDRX2DQA, its write-OE
          // TSHX2DQA, AND its read IDDRX2DQA into ONE IOLOGIC that has a SINGLE LSR
          // input. The read IDDRX2DQA uses [dqsReadReset] (the RDPNTR-align phase-12
          // release), so the write registers on the SAME pad MUST use it too or pack
          // fails ("conflicting LSR signals sclk_reset and ddr_rd_reset"). This is
          // exactly litedram's single-shared-reset PHY. DLL-off: [dqsReadReset] ==
          // [sclkReset], so the DLL-off netlist stays byte-identical. Holding the
          // write path in reset through init is safe: no writes occur before
          // init_done and the tristate defaults HiZ.
          rst: dqsReadReset,
          name: 'dq_oddr2_$i',
        ).q;
        // Per-bit write-OE tristate shift. Q -> this bit's pad tristate directly.
        final dqTsh = Ecp5Tshx2dqa(
          t0: dqTN,
          t1: dqTN,
          dqsw270: dqsw270(lane),
          sclk: sclk,
          eclk: eclk,
          rst:
              dqsReadReset, // same DQ PIO IOLOGIC LSR as the read IDDRX2DQA above
          name: 'dq_tsh_$i',
        );
        final dqBb = Ecp5Bb(
          i: dqDrive,
          t: dqTsh.q,
          b: dqPadNet[i],
          name: 'dq_bb_$i',
        );
        dqReadBits.add(dqBb.o);
      }

      // Write-leveling DQ feedback capture is built FURTHER DOWN, after the per-DQ
      // IDDRX2DQA read-capture registers exist. It must NOT tap the raw `dqReadBits`
      // (= the pad `dqBb.o` above): on the ECP5 the per-DQ DELAYF sits on the
      // dedicated IO-delay path and must be the pad input's SOLE direct consumer
      // (nextpnr's `net_only_drives` rule: `DELAYF '...' must be connected directly
      // to top level input`). A second load on the pad breaks DELAYF packing. It
      // must ALSO NOT tap the DELAYF output, because that net is the IDDRX2DQA `D`'s
      // sole-driver IOLOGIC net. So the WL feedback is OR-reduced from the IDDRX2DQA
      // Q OUTPUTS (ordinary fabric registers, legal to fan out) further below: the
      // same captured-rddata path litedram reads the WL result through.

      // DM: one ODDRX2DQA per byte lane (DM=1 means "ignore this beat"). Only the
      // selected beat-pair's two beats in the current chunk are unmasked (DM=0).
      // Every other sub-beat is masked (DM=1). For lane l the byte is enabled
      // when wrSel says so: rise uses wrSel[l], fall uses wrSel[2+l] (same layout
      // as the old x1 path's q0/q1 split).
      // The per-lane DM ODDR D-inputs are DEFINED fabric (pairInChunk/wrBeat/wrSel,
      // no DQSBUFM leaf). Collect the "this sub-beat is UNMASKED" booleans (DM low)
      // so the DM diagnostic counter below can observe a presented write WITHOUT
      // tapping the X-prone ODDR `.q` output. dmUnmaskedBits is high whenever any
      // DM ODDR D-input would drive DM=0 (a byte is actually written this cycle).
      final dmUnmaskedBits = <Logic>[];
      final dmBits = <Logic>[
        for (var l = 0; l < dataBits ~/ 8; l++)
          () {
            final loEn = pairInChunk & ~wrBeat[0];
            final hiEn = pairInChunk & wrBeat[0];
            // DM low (unmasked) on any of this lane's four sub-beats.
            dmUnmaskedBits.addAll([
              loEn & wrSel[l],
              loEn & wrSel[2 + l],
              hiEn & wrSel[l],
              hiEn & wrSel[2 + l],
            ]);
            // Slip the DM beats in lockstep with data+DQS (same WRBEATSLIP). The
            // wrapped head beats come from the previous word's DM (all-masked for
            // an isolated write), so no spurious write leaks in.
            final dmS = beatSlipBy(
              [
                ~(loEn & wrSel[l]),
                ~(loEn & wrSel[2 + l]),
                ~(hiEn & wrSel[l]),
                ~(hiEn & wrSel[2 + l]),
              ],
              wrBeatSlipLane[l],
              'wr_dm$l',
            );
            return Ecp5Oddrx2dqa(
              d0: dmS[0],
              d1: dmS[1],
              d2: dmS[2],
              d3: dmS[3],
              dqsw270: dqsw270(l),
              sclk: sclk,
              eclk: eclk,
              rst: sclkReset,
              name: 'dm_oddr2_$l',
            ).q;
          }(),
      ];
      dmOut <= dmBits.rswizzle();

      // Saturating 8-bit counters / sticky observation of the write control path,
      // in the sclk fabric domain. All three derive from DEFINED fabric signals
      // (oeWindow, dmBits, wrData2), not the X-prone DQ/DQS pads, so they are
      // sim-visible and a sim test can prove they increment on a write burst.
      //   wrOeFired  <- oeWindow         (DQ output-enable window open this cycle)
      //   wrDmLow    <- any DM-low D-input (a byte lane is unmasked = a real write)
      //   wrDatFired <- wrData2          (the ODDR write-data launch window)
      // DM is active-HIGH "mask this beat", so DM LOW means a write is presented.
      // [dmAnyLow] is taken from the DM ODDR D-INPUT mask expressions (defined
      // fabric), NOT the X-prone ODDR `.q` output, so it is sim-visible. These let
      // firmware tell apart (no scope): CMD issued but OE never opened (Hi-Z), all
      // writes masked (DM never low), or the data path never launching (DAT=0).
      final wrOeCount = Logic(name: 'ddr_wr_oe_count', width: 8);
      final wrDmCount = Logic(name: 'ddr_wr_dm_count', width: 8);
      final wrDatCount = Logic(name: 'ddr_wr_dat_count', width: 8);
      // Any byte lane unmasked (DM driven low) this cycle = a real write presented.
      final dmAnyLow = dmUnmaskedBits.swizzle().or().named('ddr_wr_dm_any_low');
      Logic satInc(Logic ctr, Logic ev) =>
          mux(ev & ~ctr.eq(Const(0xFF, width: 8)), ctr + 1, ctr);
      Sequential(
        sclk,
        reset: sclkReset,
        resetValues: {
          wrOeCount: Const(0, width: 8),
          wrDmCount: Const(0, width: 8),
          wrDatCount: Const(0, width: 8),
        },
        [
          wrOeCount < satInc(wrOeCount, oeWindow),
          wrDmCount < satInc(wrDmCount, dmAnyLow),
          wrDatCount < satInc(wrDatCount, wrData2),
        ],
      );
      addOutput('wr_oe_count', width: 8) <= wrOeCount;
      addOutput('wr_dm_count', width: 8) <= wrDmCount;
      addOutput('wr_dat_count', width: 8) <= wrDatCount;

      // DM: drive the dataBits/8 DM pads (output-only, no TSH: DM is never read,
      // so it has no DQ-group tristate constraint and stays a plain ODDRX2DQA
      // output to a regular pad). DM ODDRs are built in the dmBits block above.

      // DQS strobe: per lane, an ODDRX2DQSB clocked by the lane's DQSW emits the
      // toggling strobe (D = 0b1010 -> D0=0,D1=1,D2=0,D3=1) across the write
      // window, plus a per-lane TSHX2DQSA whose Q drives that lane's DQS pad
      // tristate DIRECTLY (forward-declared dqsTriN[l] -> the dqs_bb T). The DQS is
      // a TRUE DIFFERENTIAL pad (SSTL135D_I on the LDQS _p ball), so this single
      // buffer drives BOTH rails on write and the LDQSN complement is generated by
      // nextpnr: there is no explicit pseudo-differential _n drive.
      //
      // FIX 2/3: WL DQS shaping. The sequencer holds wl_strobe high over a
      // multi-CK window, but JEDEC WL wants ONE clean rising DQS edge per step
      // (litedram drives a single DQS pulse per WL step), preceded by DQS DRIVEN
      // LOW (the preamble, OE already open via dqsTriNForLane). So during WL we
      // gate the ODDR PATTERN, not the OE:
      //   - preamble / settle / sample (wl_strobe low):  D = 0000  (driven 0)
      //   - the one sclk cycle at the wl_strobe RISING edge: D = 0b0010
      //     (D0=0,D1=0,D2=1,D3=0) -> a single 0 -> rising edge -> 0 within the
      //     half-rate word, aligned to a pattern rising edge.
      // wlPulse is that single-cycle strobe: the rising edge of wl_strobe in the
      // sclk domain (assert for exactly one sclk cycle even though wl_strobe stays
      // high for the rest of the sub-step). Outside WL the normal 0b1010 pattern is
      // emitted unchanged so the proven write/read path is untouched.
      final Logic wlPulse;
      if (writeLevel) {
        final wlStrobeSig = wlStrobeIn!;
        final wlStrobePrev = Logic(name: 'wl_strobe_prev');
        Sequential(sclk, reset: sclkReset, [wlStrobePrev < wlStrobeSig]);
        wlPulse = (wlStrobeSig & ~wlStrobePrev).named('wl_dqs_pulse');
      } else {
        wlPulse = Const(0);
      }
      // Per-DQS-edge ODDR data, computed once: normal 0b1010, or the WL-shaped
      // value during WL. WL pulse pattern 0b0010 -> D0=0,D1=0,D2=1,D3=0 (single
      // rising edge), only during the one wlPulse cycle, 0 otherwise (driven-low
      // preamble). On the differential pad the single buffer's complement (LDQSN)
      // is driven by nextpnr, so only the _p ODDR/TSH exist: no explicit _n
      // pattern.
      final dqsD = <Logic>[];
      for (var beat = 0; beat < 4; beat++) {
        // PREAMBLE FIX: the OE (laneDqsTriN T0/T1) already drives the DQS pad one
        // sclk cycle BEFORE and AFTER the data window, but the 0b1010 toggle was
        // emitted there too, so the preamble/postamble TOGGLED instead of being a
        // DDR3-required driven-LOW level (tWPRE/tWPST). The DRAM never saw a clean
        // single rising strobe edge => writes deposited a wrong/weak level. GATE
        // the toggle by [oeWindow] (the 2 DATA cycles): the strobe only toggles
        // during the data. The OE-extended preamble + postamble cycles drive 0.
        final normal = ((0x0A >> beat) & 0x1) == 1
            ? oeWindow
            : Const(0); // 0b1010 gated
        if (!writeLevel) {
          dqsD.add(normal.named('dqs_d$beat'));
        } else {
          final wlBit = beat == 2 ? wlPulse : Const(0);
          dqsD.add(mux(wlEnPhy, wlBit, normal).named('dqs_d${beat}_wl'));
        }
      }
      // Slip each lane's DQS beats in lockstep with that lane's data (per-lane
      // WRBEATSLIP). The strobe waveform is shared. Only the launch beat-phase
      // slides per lane, matching the per-lane data slip above.
      final dqsDsLane = [
        for (var l = 0; l < laneCount; l++)
          beatSlipBy(dqsD, wrBeatSlipLane[l], 'wr_dqs_l$l'),
      ];
      for (var l = 0; l < laneCount; l++) {
        dqsDrive[l] <=
            Ecp5Oddrx2dqsb(
              d0: dqsDsLane[l][0],
              d1: dqsDsLane[l][1],
              d2: dqsDsLane[l][2],
              d3: dqsDsLane[l][3],
              dqsw: dqsw(l),
              sclk: sclk,
              eclk: eclk,
              rst: sclkReset,
              name: 'dqs_oddr2_$l',
            ).q;
        // Per-pad DQS OE: a TSHX2DQSA whose Q is the differential pad tristate. The
        // litex preamble/postamble split folds into the same oeWindow here. During
        // write-leveling the OE is the per-lane WL strobe gate (dqsTriNForLane), so
        // only the trained lane drives DQS for the WL pulse.
        // T0/T1 are SPLIT (litedram L322-323): T0 carries the postamble, T1 the
        // preamble, so the driven DQS window extends one sclk cycle each side of
        // the data window. The complement rail tracks via the differential buffer.
        final laneDqsTriN = dqsTriNForLane(l);
        dqsTriN[l] <=
            Ecp5Tshx2dqsa(
              t0: laneDqsTriN.t0,
              t1: laneDqsTriN.t1,
              dqsw: dqsw(l),
              sclk: sclk,
              eclk: eclk,
              rst: sclkReset,
              name: 'dqs_tsh_$l',
            ).q;
      }

      // Replaces the temporary IDDRX1F-on-clk90 capture. Per BYTE LANE one
      // DQSBUFM delays the incoming DQS by the DDRDLLA-calibrated 90 degrees to
      // make DQSR90 (the read capture clock) and tracks the read window via its
      // read pointer (RDPNTR). Per DQ BIT one IDDRX2DQA captures the DELAY-lined
      // DQ in that DQSR90 domain at 1:4 gearing (Q0..Q3 = four sub-beats),
      // presenting the result in the SCLK fabric domain. For a BL8 burst on a x16
      // part the 8 beats arrive as two SCLK words of four sub-beats each.
      //
      // SIM CAVEAT (rohd-rtl-gotchas, no-sim-model leaf): DQSBUFM and IDDRX2DQA
      // are SystemVerilog leaves with NO ROHD sim model, and DQ/DQS are inout
      // pads ROHD cannot co-simulate. Their outputs (read data, DATAVALID,
      // BURSTDET, RDPNTR) are X in simulation, so the DQS read DATA is verified
      // ON HARDWARE, never in sim.
      //
      // Two read paths now exist:
      //   - NON-TRAINABLE: the read FSM advances on its own [rdPipe] sclk counter
      //     and asserts rd_valid sequencer-timed (the static DELAYG capture). This
      //     is the same CAPTURE FSM as before, but note the surrounding datapath
      //     (x2 MODDRX write/read gearing, DQS-strobed IDDRX2DQA, sclk fabric) is
      //     the Milestone 4 rewrite, not the old x1 ODDRX1F path, so it still needs
      //     hardware re-characterization (the OrangeCrab calibration constants were
      //     measured against the x1 path).
      //   - TRAINABLE (the real ECP5 DQS read): the DQSBUFM read gate (READ0/
      //     READ1) is still opened by the [windowOpen] command-delayed pulse for
      //     two sclk cycles, exactly as litedram's ECP5DDRPHY drives
      //     `dqs_re = rddata_en.taps[rdtap] | rddata_en.taps[rdtap+1]` with
      //     `rdtap = cl_sys_latency` (ecp5ddrphy.py L417/L435). But the CAPTURE
      //     is gated on the DQSBUFM DATAVALID (lane 0): rd_data latches and
      //     rd_valid asserts on the sclk cycle DATAVALID marks the IDDRX2DQA Q
      //     beats valid. This is the real read-leveled gate, not a sequencer
      //     count. It cannot pass in sim (DATAVALID is X). It is a hardware gate.
      //
      // REVIEWER NOTE on the litedram gate timing: litedram itself does NOT gate
      // rddata_valid on DATAVALID. It drives rddata_valid from the TIMED tail of
      // its read-latency TappedDelayLine (rddata_en.output, L434) and exposes
      // DATAVALID/BURSTDET only as software-visible read-leveling status
      // (_burstdet_seen, L298-302) that firmware sweeps READCLKSEL/DELAYF
      // against. The prompt asks for DATAVALID-gated capture, which is stricter
      // (the hardware will only present valid when the eye is actually landed).
      // Both the DATAVALID gate AND the BURSTDET/DATAVALID STATUS poll are
      // wired, so firmware retains the litedram-style oracle either way. A
      // reviewer should confirm on-bench whether DATAVALID rises within the
      // 2-cycle window for this DDRDLLA configuration, or whether the timed
      // litedram path (rd_valid = end of window) is the safer default.
      //
      // The per-bit DELAYG/DELAYF read deskew is KEPT (it still makes sense:
      // deskew the DQ into the DQS capture, exactly as litex's ECP5DDRPHY runs
      // DELAYF on DQ before IDDRX2DQA). It does not conflict with the DQS path.

      // Read window strobe. Same fabric timing as Milestone 1's windowOpen: the
      // burst's first beat lands [cl]+slack sclk cycles after the READ command.
      // This pulse opens the DQSBUFM read gate (READ0/READ1) and times the fabric
      // capture. On hardware READ0/READ1 are the per-eclk-edge gate. Here the one
      // fabric strobe drives both (M3 splits/aligns them with READCLKSEL).
      final rdSlack = readSlack;
      // SHOULD-FIX 3 (read-gate latency units). [cl] is quoted in DDR CK cycles,
      // but rdPipe is a shift register clocked on sclk = CK/2, so the burst's
      // first beat arrives at the CK-latency CL measured in HALF as many sclk
      // taps. Convert CL from CK cycles to sclk taps the same way litedram derives
      // cl_sys_latency: clSys = ceil(cl / 2) = (cl + 1) ~/ 2. Using raw [cl] as
      // the sclk tap base opened the window ~CL/2 sclk cycles too late (2x the
      // real time), so the gate missed the burst. The runtime slack sweep is kept
      // around clSys exactly as before.
      final clSys = (cl + 1) ~/ 2;
      // TIMED-TAIL read-capture anchor (litedram ecp5ddrphy.py L434: rddata_valid
      // is driven from the TIMED tail of the read-latency TappedDelayLine, NOT from
      // DATAVALID). On this silicon DATAVALID is held HIGH as a LEVEL across the
      // whole sweep (never a clean 2-beat toggle), so a DATAVALID-rising-edge anchor
      // can latch the sliding-pair on a gearbox HOLD/repeat cycle where the four
      // prev beats are NOT distinct: the bench saw word0 == word1. A FIXED count
      // (the old const readTail) latched DISTINCT beats but mostly landed on hold
      // cycles: the right capture cycle was config-dependent and rebuilding per
      // value was too slow.
      //
      // RUNTIME-SWEEPABLE anchor: tie the timed-tail offset to the SAME runtime
      // RDSLACK knob [rdSlackRt] the ddrlevel firmware already sweeps (alongside
      // READCLKSEL and the read TAP). The {prev,cur} capture anchors at
      // rdPipe[clSys + rdSlackRt], so each RDSLACK step moves the fabric capture
      // cycle and the existing TAP x RCS x RDSLACK sweep finds the read cycle in
      // ONE build. The [windowOpen] DQSBUFM gate ALSO tracks rdSlackRt (it always
      // did), so the gate and the capture move together: the gate still produces
      // the gearbox data and only the fabric CAPTURE cycle is now runtime-tuned.
      // The anchor tap is rdPipe[clSys + rdSlackRt]. The assemble/ack lands one sclk
      // later off the [rdAssemble] one-shot (NOT an rdPipe tap), so the pipe only
      // has to reach clSys + maxRdSlack (the widest anchor tap).
      // +1 tap: the DQSBUFM read gate is a 2-sclk-cycle pulse (taps[rdtap] |
      // taps[rdtap+1]) per litedram / Lattice TN-02035 6.2.4, so the read-command
      // pipeline needs one tap BEYOND the window-open tap to form the pulse. The
      // trainable pipe must reach the widest runtime anchor tap (clSys + maxRdSlack)
      // and the gate's +1 next tap (also clSys + maxRdSlack), so clSys + maxRdSlack
      // is the highest index either uses.
      // The read-command shift register must reach the WIDEST tap any consumer uses:
      // the RDSLACK capture anchor (clSys + maxRdSlack) OR the new independent
      // read-pulse position (maxRdPulse) plus its +1 next tap (the 2-cycle pulse
      // needs rdPipe[pos+1]). rdPipe grows so a full 0..maxRdPulse pulse sweep (the
      // lever that frames the burst on this board's round-trip) is reachable.
      final pulseTapMax = maxRdPulse + 1; // pos + 1 for the 2-cycle pulse
      final trainPipeMax = (clSys + maxRdSlack) > pulseTapMax
          ? (clSys + maxRdSlack)
          : pulseTapMax;
      final pipeLen = (trainable ? trainPipeMax : clSys + rdSlack) + 1;
      final rdPipe = Logic(name: 'rd_pipe', width: pipeLen);
      final rdBeats = Logic(name: 'rd_beats', width: 3);
      final rdActive = Logic(name: 'rd_active');
      final rdBeat = Logic(name: 'rd_beat', width: 2);

      // The DQS read gate: high across the burst window so DQSBUFM gates the
      // strobe and the IDDRX2DQA captures. Driven by rdActive plus its open edge.
      final Logic windowOpen;
      if (trainable) {
        // Runtime read-window slack: the window opens at sclk [cl-1+slack], where
        // slack is the runtime [rdSlackRt] in 0..maxRdSlack. The candidate open
        // pulses are a CONTIGUOUS slice of the pipeline shift register, so select
        // by a single DYNAMIC bit-index instead of a comparator-mux chain
        // (maxRdSlack muxes + maxRdSlack `eq` comparators). Same runtime knob,
        // one indexed barrel-mux instead of N comparators. The slack stays fully
        // runtime. The candidate vector is padded out to the full 2^slackW index
        // range with the s==0 fallback bit (rdPipe[cl-1]) so an out-of-range
        // [rdSlackRt] (firmware writes 0..maxRdSlack) degrades to the CL-aligned
        // window rather than indexing past the vector.
        // 144MHz DLL-on: the DQSBUFM read pointer / IDDRX2DQA gearbox aligns one
        // SCLK word later than the CL-derived clSys tap predicts, so the gate
        // opened one word too late and the read anchored on the SECOND SCLK word
        // (a word-0 request returned word 2). Open the gate one sclk earlier
        // (clSys-2 base) so the pointer aligns to the first word. The RDSLACK
        // runtime knob still walks later from this earlier base.
        // Board-offset lockstep shift: the whole valid window sat one sclk word LATE
        // (the read captured the BL8's 2nd half, words 2/3, bit-perfect). clSys
        // already equals litedram cl_sys_latency=get_sys_latency(2,6)=3, so the
        // formula is right. The board round-trip just puts the burst START one sclk
        // earlier than the CL tap. Shift the gate (prev/open/next) AND the anchor
        // DOWN by one in lockstep (spacing preserved so the preamble bracket keeps
        // BURSTDET armed): windowOpen base clSys-2 (was clSys-1).
        final fallback = rdPipe[clSys - 2]; // s == 0 (one sclk earlier than CL)
        final cands = <Logic>[
          for (var s = 0; s <= maxRdSlack; s++) rdPipe[clSys - 2 + s],
          for (var s = maxRdSlack + 1; s < (1 << rdSlackRt!.width); s++)
            fallback,
        ];
        windowOpen = cands
            .rswizzle()
            .named('rd_slack_window')[rdSlackRt]
            .named('window_open');
      } else {
        windowOpen = rdPipe[clSys + rdSlack - 1];
      }
      // The SECOND gate tap, one sclk later, forms the 2-cycle read pulse with
      // [windowOpen] (litedram: dqs_re = taps[rdtap] | taps[rdtap+1]). Mirror the
      // [windowOpen] slack mux, indices shifted up by one.
      final Logic windowOpenNext;
      if (trainable) {
        final fallbackN = rdPipe[clSys - 1]; // s == 0 next tap (lockstep -1)
        final candsN = <Logic>[
          for (var s = 0; s <= maxRdSlack; s++) rdPipe[clSys - 1 + s],
          for (var s = maxRdSlack + 1; s < (1 << rdSlackRt!.width); s++)
            fallbackN,
        ];
        windowOpenNext = candsN
            .rswizzle()
            .named('rd_slack_window_next')[rdSlackRt]
            .named('window_open_next');
      } else {
        windowOpenNext = rdPipe[clSys + rdSlack];
      }
      // PREAMBLE-bracket gate tap, ONE sclk EARLIER than [windowOpen]. The DQSBUFM
      // only asserts BURSTDET when the read gate brackets the read PREAMBLE (the
      // ~1 CK DQS-low + the first rising edge that precedes beat0), not just the
      // data beats. With a gate that opens at/after the first data edge, the
      // preamble->first-edge transition falls JUST BEFORE gate-open, so the data
      // captures (DATAVALID=1) but BURSTDET never arms (bench: DV=1, BD=0 across
      // the whole sweep). Opening the gate one sclk earlier brackets that
      // transition so the DQSBUFM arms BURSTDET. This widens ONLY the gate. The
      // data-capture anchor (rdData latched on rdPipe[clSys + rdSlackRt]) is
      // UNCHANGED. Built exactly like [windowOpen] but one tap lower: base
      // clSys-2+s (vs clSys-1+s), padded/indexed by the same runtime [rdSlackRt],
      // fallback rdPipe[clSys-2]. clSys=3 so clSys-2=1 >= 0 (in bounds). The tap is
      // LOWER than the existing max so pipeLen does not grow.
      final Logic windowOpenPrev;
      if (trainable) {
        final fallbackP =
            rdPipe[clSys - 3]; // s == 0 (lockstep -1: preamble bracket)
        final candsP = <Logic>[
          for (var s = 0; s <= maxRdSlack; s++) rdPipe[clSys - 3 + s],
          for (var s = maxRdSlack + 1; s < (1 << rdSlackRt!.width); s++)
            fallbackP,
        ];
        windowOpenPrev = candsP
            .rswizzle()
            .named('rd_slack_window_prev')[rdSlackRt]
            .named('window_open_prev');
      } else {
        windowOpenPrev = Const(0);
      }
      // Drive the forward-declared read gate (the DQSBUFM is built up in the
      // write section so its DQSW/DQSW270 clock the x2 write datapath).
      //
      // litedram / Lattice TN-02035 6.2.4 (READ Pulse Positioning): READ0/READ1
      // must be a CLEAN 2-sclk-cycle pulse positioned at the read-command CAS
      // latency (rdtap = cl_sys_latency), NOT held high across the whole burst.
      // The old `windowOpen | rdActive` kept the gate open for the full FSM-active
      // window (burst + timeout, up to 8 sclk cycles). That over-wide gate is
      // self-defeating on silicon: the DQSBUFM never cleanly bounds the read
      // burst, so BURSTDET / DATAVALID never assert, the capture FSM always falls
      // through to its timeout fallback, and the IDDRX2DQA read-FIFO pointer
      // (RDPNTR) never stabilizes: the read returns non-deterministic drifting
      // data. The precise 2-cycle pulse lets the DQSBUFM establish its read
      // pointer and fire BURSTDET/DATAVALID. The capture FSM still runs off its
      // own [rdActive]/[dataValid]. Only the gate to the DQSBUFM changes here.
      // During JEDEC write-leveling the DRAM drives a STATIC feedback level on DQ,
      // sampled through the SAME DQS-strobed read capture (IDDRX2DQA on DQSR90).
      // The DQSBUFM only produces DQSR90 while READ0/READ1 (this [rdGate]) are
      // asserted, but WL issues NO read command, so [windowOpen] stays low, the
      // gate never opens, DQSR90 never pulses, the IDDRX2DQA never captures the
      // looped-back write-DQS, and the WL feedback (wlFb, OR-reduced from the
      // IDDRX2DQA Q) is STUCK. That made write-leveling unable to converge (the
      // feedback never toggled when the WL delay swept, so it never found the
      // DQS-vs-CK 0->1 crossing) and writes never landed on silicon. Open the read
      // gate across the WL window ([wlEnIn], high for the whole scan) so each WL
      // DQS strobe clocks the feedback capture. [wlEnIn] is null off the writeLevel
      // build, so normal builds are unchanged. In normal operation wlEn is low so
      // this only ORs in during write-leveling (no effect on normal reads).
      final wlReadEn = wlEnIn ?? Const(0);
      // INDEPENDENT READ-PULSE POSITION (the burst-framing fix, litedram
      // ecp5ddrphy.py L435: dqs_re = taps[rdtap] | taps[rdtap+1]). The legacy gate
      // above (windowOpenPrev|windowOpen|windowOpenNext) is a 3-tap-wide,
      // preamble-bracketed pulse whose position is LOCKED to the RDSLACK capture
      // anchor (both index rdPipe by the same rdSlackRt). On the OrangeCrab 25F that
      // over-wide, capture-coupled gate never let the DQSBUFM RDPNTR/BURSTDET
      // stabilize on the data burst: the read captured the PREAMBLE/idle
      // (data-invariant readback across every RDSLACK). The cure: a CLEAN 2-sclk
      // pulse whose position [rdPulsePosRt] is swept INDEPENDENTLY of the capture
      // anchor over a WIDE range (0..maxRdPulse), so the FSBL can walk it until
      // BURSTDET frames the burst. rdPulse0 = rdPipe[pos], rdPulse1 = rdPipe[pos+1]
      // via a bounds-safe indexed barrel-mux (same pattern as windowOpen). When
      // [rdPulsePosRt] is the all-ones SENTINEL (reset default), fall back to the
      // legacy gate so a boot that never programs reg11 is byte-behavior-identical.
      if (trainable) {
        final pos = rdPulsePosRt!;
        final sentinel = Const((1 << pos.width) - 1, width: pos.width);
        // rdPulse0 candidate vector: rdPipe[i] for i in 0..maxRdPulse, padded to the
        // full 2^pulseW index range with tap 0 so an out-of-range index is safe.
        final pulseCands0 = <Logic>[
          for (var i = 0; i <= maxRdPulse; i++) rdPipe[i],
          for (var i = maxRdPulse + 1; i < (1 << pos.width); i++) rdPipe[0],
        ];
        // rdPulse1 = the next tap up (forms the clean 2-cycle pulse). Index i+1.
        final pulseCands1 = <Logic>[
          for (var i = 0; i <= maxRdPulse; i++) rdPipe[i + 1],
          for (var i = maxRdPulse + 1; i < (1 << pos.width); i++) rdPipe[1],
        ];
        final rdPulse0 = pulseCands0
            .rswizzle()
            .named('rd_pulse_cands0')[pos]
            .named('rd_pulse0');
        final rdPulse1 = pulseCands1
            .rswizzle()
            .named('rd_pulse_cands1')[pos]
            .named('rd_pulse1');
        // Clean 2-cycle pulse (litedram taps[rdtap]|taps[rdtap+1]).
        final trainedPulse = (rdPulse0 | rdPulse1).named('rd_trained_pulse');
        // Legacy 3-tap gate, used only when reg11 is the sentinel.
        final legacyGate = (windowOpenPrev | windowOpen | windowOpenNext).named(
          'rd_legacy_gate',
        );
        final useLegacy = pos.eq(sentinel).named('rd_pulse_legacy');
        rdGate <=
            (mux(useLegacy, legacyGate, trainedPulse) | wlReadEn).named(
              'rd_gate_sel',
            );
      } else {
        // Non-trainable build: unchanged 2-sclk gate (windowOpenPrev = Const(0)).
        rdGate <= (windowOpenPrev | windowOpen | windowOpenNext | wlReadEn);
      }
      // Sim-observable mirror of the read-gate pulse (trainable build only). The
      // DQSBUFM leaf is X in sim, but this gate net feeding READ0/READ1 is plain
      // fabric, so a test can prove the reg11 read-pulse position moves the gate.
      if (trainable) {
        addOutput('rd_gate_dbg') <= rdGate;
      }

      // Per DQ bit: one IDDRX2DQA in its lane's DQSR90 domain. The four sub-beats
      // Q0..Q3 are the four consecutive burst beats captured in one SCLK word.
      final qBeats = List.generate(4, (_) => <Logic>[]); // qBeats[b][bit]
      // PER-BIT DQ DESKEW gating: when [perBitDeskew], the shared MOVE/LOADN from
      // the tap controller is applied to ONLY the DQ bit whose index equals
      // [dqDeskewSelIn] (one-hot). So firmware walks one DQ's DELAYF at a time (SET
      // steps the selected bit's tap, LOADN resets ONLY the selected bit + the
      // controller's tracked tap, so each bit trains from 0 independently). Off the
      // per-bit path, every bit shares dMove/dLoadn exactly as before (byte-
      // identical). The per-bit MOVE is a plain fabric AND on the DELAYF MOVE input
      // (fabric, not the pad/`.z` IOLOGIC nets), so nextpnr net_only_drives is
      // unaffected. LOADN is active-LOW: gating means "assert LOADN (drive 0) only
      // on the selected bit, hold 1 (no reload) on the others".
      // "This bit is selected" = broadcast mode (MSB set) OR the index matches.
      Logic dqSelFor(int i) {
        final sel = dqDeskewSelIn!;
        final bcast = sel[dqIdxW]; // MSB = broadcast
        final idxMatch = sel.getRange(0, dqIdxW).eq(Const(i, width: dqIdxW));
        return (bcast | idxMatch).named('dq_sel_$i');
      }

      // Per-bit gated MOVE, captured for a sim-visible debug mirror (dq_move_dbg)
      // so a test can prove the gating routes MOVE to only the selected DQ.
      final dqMoveDbgBits = <Logic>[];
      Logic dqMoveFor(int i) {
        if (!(trainable && perBitDeskew)) {
          dqMoveDbgBits.add(dMove!);
          return dMove;
        }
        final g = (dMove! & dqSelFor(i)).named('dq_move_$i');
        dqMoveDbgBits.add(g);
        return g;
      }

      Logic dqLoadnFor(int i) {
        if (!(trainable && perBitDeskew)) return dLoadn!;
        // dLoadn active-low: a LOAD asserts 0. Reload only the selected bit(s). The
        // others see 1 (no reload) so their trained taps are preserved.
        return (dLoadn! | ~dqSelFor(i)).named('dq_loadn_$i');
      }

      // Per-DQ read deskew: each pad (dqReadBits[i]) feeds ONLY its DELAYF/DELAYG
      // (the pad's sole direct consumer), and that delay element's `.z` feeds ONLY
      // its IDDRX2DQA `D` (no other load). Both are the ECP5 IOLOGIC packing rule
      // (nextpnr net_only_drives). The WL feedback therefore taps NEITHER the pad
      // NOR the DELAYF output, but the IDDRX2DQA Q outputs (qBeats) further below.
      // WL FEEDBACK CAPTURE FIX (2026-07-09, HW-confirmed root cause): the WL DQ
      // feedback is a STATIC DC level the DRAM drives on DQ during write-leveling,
      // and the DRAM does NOT drive DQS during WL: only DQ. The old capture read
      // DQ0 through the IDDRX2DQA, whose clock DQSR90 is a DDRDLLA-delayed copy of
      // the INCOMING DQS. With no DRAM-driven DQS during WL, DQSR90 never pulses,
      // so the IDDRX2DQA Q output is FROZEN and the feedback can never flip as the
      // write-DQS delay (WRPNTR) sweeps -> WL trains tap 0 always (HW: fbmap=00).
      // FIX: on a writeLevel build, DQ0 of each lane bypasses the DELAYF+IDDRX2DQA
      // read chain and is captured by a PLAIN sclk fabric register straight off the
      // pad (dqBb.o). sclk is a real, always-running clock, so the static WL level
      // IS sampled and flips as WRPNTR sweeps. This keeps the pad a SINGLE-consumer
      // net (the sclk flop replaces the DELAYF as DQ0's sole load), so nextpnr's
      // net_only_drives IOLOGIC packing rule still passes. DQ0's normal-read data on
      // the writeLevel build then also comes from the sclk register (replicated
      // across the 4 sub-beats): slightly coarser than a DQS-strobed capture for
      // that one bit on this bring-up config, but the WL correctness win is decisive
      // and every OTHER DQ bit keeps the full DQS-strobed read path.
      // DQ0/DQ8 READ-TRADEOFF FIX (2026-07-10). The earlier WL fix routed DQ0 of
      // each lane through a PLAIN sclk flop off the pad (bypassing DELAYF+IDDRX2DQA)
      // so the static WL feedback could be captured without a DQSR90 strobe. That
      // DEGRADED DQ0/DQ8 READ quality (their read data came from the coarse sclk
      // flop, not the DQS-strobed x2 capture): the bitslip/gather ANCHOR bits, so
      // it hurt the whole read. bringup-debugger localized the real WL rung: during
      // WL the FPGA drives its OWN DQS (wlPulse), which reaches DQSBUFM.DQSI via the
      // DQS bidir pad, and the read gate is already forced open across the WL window
      // (rdGate |= wlReadEn), so DQSR90 DOES pulse from the self-driven strobe and
      // the normal IDDRX2DQA Q captures the static WL level. So on the per-bit
      // deskew build [restoreFullDq0Read] we route ALL 16 DQ (incl DQ0/DQ8) through
      // the full DELAYF+IDDRX2DQA path (restoring their read) and source the WL
      // feedback from the captured qBeats (below). The legacy build keeps the
      // HW-verified sclk-bypass (fbmap=06 proven) as a fallback. HW must re-confirm
      // fbmap flips on the qBeats path before trusting it (first bench measurement).
      final restoreFullDq0Read = perBitDeskew;
      final wlFb0 =
          <Logic>[]; // per-lane DQ0 sclk-captured static level (legacy WL)
      for (var i = 0; i < dataBits; i++) {
        final lane = i ~/ 8;
        final isPrimeDq = writeLevel && !restoreFullDq0Read && (i % 8 == 0);
        if (isPrimeDq) {
          // DQ0 of the lane on a legacy writeLevel build: capture the pad level
          // directly in the sclk domain (no DELAYF, no DQSR90). The pad net
          // dqReadBits[i] is this flop's SOLE consumer (net_only_drives OK). Drive
          // all 4 sub-beats from it so the read-data path stays consistent.
          final dq0Reg = Logic(name: 'wl_dq0_reg_$lane');
          Sequential(sclk, reset: sclkReset, [dq0Reg < dqReadBits[i]]);
          wlFb0.add(dq0Reg);
          qBeats[0].add(dq0Reg);
          qBeats[1].add(dq0Reg);
          qBeats[2].add(dq0Reg);
          qBeats[3].add(dq0Reg);
          continue;
        }
        // Per-bit read deskew (kept): static DELAYG, or dynamic DELAYF when
        // trainable. Feeds the IDDRX2DQA D input. DEL_MODE = "DQS_ALIGNED_X2" so
        // the delay tracks the DQS-aligned x2 read window (Lattice TN-02035 /
        // litedram DQ read DELAYF) and centers the captured beat in the DQS eye -
        // the correct mode for a DQS-gearbox read, vs the raw "USER_DEFINED" tap
        // used for static/non-DQS delays.
        final Logic delayed;
        if (trainable) {
          delayed = Ecp5Delayf(
            a: dqReadBits[i],
            loadn: dqLoadnFor(i),
            move: dqMoveFor(i),
            direction: dDir!,
            delValue: readTaps,
            delMode: 'DQS_ALIGNED_X2',
            name: 'dq_dlyf_$i',
          ).z;
        } else {
          delayed = Ecp5Delayg(
            a: dqReadBits[i],
            delValue: readTaps,
            delMode: 'DQS_ALIGNED_X2',
            name: 'dq_dly_$i',
          ).z;
        }
        final iddr = Ecp5Iddrx2dqa(
          d: delayed,
          dqsr90: dqsBufs[lane].dqsr90,
          rdpntr: dqsBufs[lane].rdpntr,
          wrpntr: dqsBufs[lane].wrpntr,
          eclk: eclk,
          sclk: sclk,
          // RDPNTR-ALIGN: the read IDDRX2DQA gather MUST leave reset on the SAME
          // edge as its DQSBUFM (the [dqsReadReset] init-FSM release at phase 12),
          // or the 1:4 Q0..Q3 gather re-desyncs from the just-pinned RDPNTR and the
          // boot-to-boot framing wander returns. DLL-off: byte-identical sclkReset.
          rst: dqsReadReset,
          name: 'dq_iddr2_$i',
        );
        qBeats[0].add(iddr.q0);
        qBeats[1].add(iddr.q1);
        qBeats[2].add(iddr.q2);
        qBeats[3].add(iddr.q3);
      }
      // Sim-visible mirror of the per-bit gated MOVE (one bit per DQ). On the per-
      // bit-deskew build a driven MOVE reaches ONLY the selected DQ (or all in
      // broadcast). Off that build it mirrors the shared MOVE on every bit. Lets a
      // test prove the deskew gating without the X-prone DELAYF/IDDRX2DQA leaves.
      if (trainable && perBitDeskew) {
        addOutput('dq_move_dbg', width: dataBits) <= dqMoveDbgBits.rswizzle();
      }

      // Write-leveling DQ feedback capture (FIX 1: through the CAPTURED read beats,
      // not a fresh tap on the pad or the DELAYF). During WL the DRAM samples CK on
      // the DQS rising edge and drives the (static) result back on DQ (all 8 bits
      // of the lane carry it). litedram reads this WL result through the NORMAL read
      // datapath (DELAYF -> IDDRX2DQA -> rddata) and lets firmware inspect rddata.
      // It does NOT add a separate combinational tap.
      //
      // The ECP5 IOLOGIC packing rule (nextpnr net_only_drives) forbids fanning out
      // either the pad input OR the DELAYF output: the per-DQ pad must be the
      // DELAYF's sole consumer, and the DELAYF output (`.z`) must be the IDDRX2DQA
      // `D`'s sole driver-with-no-other-load. So the WL feedback CANNOT tap
      // dqReadBits (breaks DELAYF packing) and CANNOT tap dqDelayed (breaks
      // IDDRX2DQA packing). It is derived from the IDDRX2DQA Q OUTPUTS (qBeats),
      // which are ordinary SCLK-domain fabric registers and legal to fan out. We
      // OR-reduce the selected lane's 8 captured DQ bits across all four sub-beats
      // (the static WL level lands on every beat), then register it into the sclk
      // domain for the sequencer's WL FSM. SIM CAVEAT (rohd-rtl-gotchas, inout pad
      // + no-sim-model leaf): the IDDRX2DQA Q is X in sim, so on hardware this is
      // the real feedback bit. In sim the FSM control logic is exercised by FORCING
      // the sequencer's wl_feedback input (see the WL FSM sim test).
      if (writeLevel) {
        // JEDEC DDR3 write-leveling feedback = the sampled CK level the DRAM drives
        // back on DQ. Two capture sources, selected by [restoreFullDq0Read]:
        //   - LEGACY (restoreFullDq0Read=false): the per-lane sclk-captured DQ0
        //     static level [wlFb0] (built above). HW-verified (fbmap=06) but costs
        //     DQ0/DQ8 read quality.
        //   - FULL-READ (restoreFullDq0Read=true, the per-bit-deskew build): OR-
        //     reduce the lane's captured qBeats (all 8 DQ x 4 sub-beats). During WL
        //     the FPGA drives its OWN DQS (wlPulse) which reaches DQSBUFM.DQSI on the
        //     DQS bidir pad, and the read gate is forced open (rdGate |= wlReadEn),
        //     so DQSR90 pulses and the IDDRX2DQA Q DOES capture the static WL level
        //     - no sclk bypass, so DQ0/DQ8 keep their full DQS-strobed read. The
        //     static level lands on every beat + every DQ of the lane, so an OR over
        //     the lane's 8 bits x 4 beats is robust to which beat the pointer hits.
        //     HW must confirm fbmap flips on this path (the decisive first bench
        //     measurement). The legacy build is the fallback if it does not.
        final List<Logic> laneFb;
        if (restoreFullDq0Read) {
          laneFb = [
            for (var l = 0; l < laneCount; l++)
              [
                for (var b = 0; b < 8; b++)
                  for (var k = 0; k < 4; k++) qBeats[k][l * 8 + b],
              ].swizzle().or().named('wl_fb_lane_$l'),
          ];
        } else {
          laneFb = wlFb0;
        }
        final selFb = laneCount == 1
            ? laneFb[0]
            : cases(wlLaneIn!, {
                for (var l = 0; l < laneCount; l++)
                  Const(l, width: laneSelW): laneFb[l],
              }, defaultValue: laneFb[0]);
        final wlFbReg = Logic(name: 'wl_fb_reg');
        Sequential(sclk, reset: sclkReset, [wlFbReg < selFb]);
        output('wl_feedback') <= wlFbReg;
      }

      // Assemble each sub-beat into a dataBits-wide word, then pair beats into the
      // two 32-bit fabric words per SCLK cycle. The write side packs a 32-bit word
      // as {fall_beat(high), rise_beat(low)} = {beat_odd, beat_high : beat_even}.
      // Match it here: wordLo = {beat1, beat0}, wordHi = {beat3, beat2}.
      final qb0 = qBeats[0].rswizzle().named('cap_qb0');
      final qb1 = qBeats[1].rswizzle().named('cap_qb1');
      final qb2 = qBeats[2].rswizzle().named('cap_qb2');
      final qb3 = qBeats[3].rswizzle().named('cap_qb3');

      // The four captured sub-beats of the CURRENT sclk cycle, in NATURAL IDDRX2DQA
      // order (Q0..Q3 = the four consecutive DRAM burst beats). The per-DQ BitSlip
      // that rotates the beat phase is applied LATER, in the trainable deserialize,
      // as a proper sliding window over the {prev, cur} 8-beat history (litedram
      // ecp5ddrphy.py L376-400), NOT as a same-cycle 4-way rotation here.
      //
      // WHY THE OLD SAME-CYCLE ROTATION WAS WRONG (2026-07-09, the beat-scramble
      // root cause): the prior code rotated {qb0..qb3} cyclically WITHIN the current
      // sclk cycle (slp=1 -> q1,q2,q3,q0), then a SEPARATE word-granularity sliding-
      // pair anchor tried to do the {prev,cur} pairing. litedram instead slides ONE
      // 4-beat window across the 8-beat {prev4, cur4} concatenation: a slp of 1
      // pulls in the PREVIOUS cycle's tail beat (r[1:5] = prev_q1,prev_q2,prev_q3,
      // cur_q0), which the same-cycle wrap (cur_q1..cur_q0) can NEVER reproduce. The
      // two mechanisms composed into a permutation that could not align the burst at
      // ANY offset -> a written 5A5A5A5A read back beat-scrambled (A5975210) at every
      // tap. The fix is to use litedram's single 8-wide sliding bitslip below.
      final beat0 = qb0.named('cap_beat0');
      final beat1 = qb1.named('cap_beat1');
      final beat2 = qb2.named('cap_beat2');
      final beat3 = qb3.named('cap_beat3');
      // ON-CHIP WRITE-EYE CAPTURE: latch lane-0's 4 captured sub-beats (byte0, 8
      // DQ bits each) while the write OE window is open. During a write the
      // IDDRX2DQA samples the FPGA's OWN driven DQ, so wr_cap = what the write
      // DRIVES (reg9). [7:0]=beat0 .. [31:24]=beat3.
      final wrCapReg = Logic(name: 'ddr_wr_cap', width: 32);
      final capWord = [
        beat0.slice(7, 0),
        beat1.slice(7, 0),
        beat2.slice(7, 0),
        beat3.slice(7, 0),
      ].rswizzle();
      Sequential(sclk, reset: sclkReset, [
        If(oeWindow, then: [wrCapReg < capWord]),
      ]);
      output('wr_cap') <= wrCapReg;
      // 144MHz DLL-on hardware: the DQS-strobed capture lands the two beats of a
      // word in the OPPOSITE sub-beat slots from the write packing: written
      // 0x40DE2222 read back at a clean tap as 0x222240DE (the 16-bit halves
      // swapped, beat0 carried the high half, beat1 the low). Pair them in the
      // captured order ({beat0, beat1}) so the round-trip word is correct. This is
      // the x2 IDDRX2DQA DQS path only (the x1 static read is a different path).
      final wordLo = [beat0, beat1].swizzle().named('cap_word_lo'); // beats 0,1
      final wordHi = [beat2, beat3].swizzle().named('cap_word_hi'); // beats 2,3

      // The within-word 16-bit half order, in ONE place. HALF-SWAP FIX (2026-07-11,
      // OrangeCrab creek DLL-on): the WRITE path packs beat0 = rise = wrWord[15:0]
      // (LOW 16 bits) and beat1 = fall = wrWord[31:16] (HIGH 16 bits): see beatVec()
      // above (even beat = dqRise = low16, odd beat = dqFall = high16). So to
      // round-trip a written word EXACTLY, the read must place the ODD beat (fall =
      // high16) in the MSBs and the EVEN beat (rise = low16) in the LSBs:
      //   readWord = (oddBeat << 16) | evenBeat = (fall << 16) | rise = wrWord.
      // The prior order [evenBeat, oddBeat].swizzle() = (rise << 16) | fall SWAPPED
      // the two halves, so a written 0xC0DE0000 (rise 0x0000, fall 0xC0DE) read back
      // 0x0000C0DE and EXACT-match was impossible at ANY rcs rotation or per-bit
      // deskew (neither can swap the two fabric halves): the multi-session
      // "capN4 popcount-frames but exact C0DE never lands / deskew bn0" wall.
      // HW-confirmed via a popcount-per-half probe: a written 0x0F0F0101 (hi pc4 / lo
      // pc1) read back with the fall (0x0F, pc4) byte in the LOW half. This was the
      // half-swap the comment predicted ("flip it HERE only"). The prior order
      // "looked correct" only because ddr_read_gather_test's golden model ALSO put
      // beat0 = high16 (inverted vs the real write): test corrected to match.
      // Trainable DLL-on path only (packWord below). The non-trainable [wordLo]/
      // [wordHi] mux (line above) and the DLL-off datapath are UNCHANGED.
      Logic packWord(Logic evenBeat, Logic oddBeat) =>
          [oddBeat, evenBeat].swizzle();

      // Cross-window read pairing (readCrossPair). The read preamble / write-to-
      // read turnaround delays the WHOLE captured burst by one SCLK relative to
      // the sequencer-timed read window: the burst's first beat-window (beats
      // 0..3) does not present a fully-captured SCLK word until ONE cycle after
      // the FSM's nominal first capture (rdBeats==0), so the nominal capture reads
      // a stale / half-filled window (cosim: word0 returns word2's data, on the
      // bench: "word0 low read stale, words 1..3 clean"). The high SCLK word
      // (beats 4..7) is delayed by the same one cycle.
      //
      // litedram handles exactly this turnaround by deserializing the BL8 burst
      // from a SLIDING pair of adjacent capture windows (register the previous
      // window and Cat(prev, cur), ecp5ddrphy.py L398-400), which is equivalent to
      // shifting the deserialize point one capture cycle later. We mirror that by
      // advancing BOTH SCLK capture points one cycle when readCrossPair is set:
      // the low SCLK word is latched at rdBeats==1 (not 0) and the high SCLK word
      // at rdBeats==2 (not 1), so the capture lands on the fully-filled,
      // turnaround-delayed burst windows. That is the same prev/cur cross-window
      // step litedram takes, expressed in the sequencer-timed FSM, and it makes
      // the cold first read bit-perfect with no warm-up read.
      final loBeat = readCrossPair ? 1 : 0;
      final hiBeat = readCrossPair ? 2 : 1;

      // Read fabric on SCLK. IDDRX2DQA presents Q0..Q3 in the SCLK domain already,
      // so there is no eclk->sclk cross to retime here (unlike Milestone 1). The
      // 8-beat BL8 burst maps to two SCLK words: SCLK cycle 0 -> words 0,1 (beats
      // 0..3), cycle 1 -> words 2,3 (beats 4..7). beatSel picks which of the four
      // 32-bit words the sequencer wants.
      final word = mux(rdBeat[0], wordHi, wordLo);
      if (trainable) {
        // TRAINABLE / real DQS read: litedram-style SLIDING-PAIR deserialize,
        // anchored on a TIMED TAIL (not on DATAVALID).
        //
        // HARDWARE HISTORY (144MHz, DLL-on, DQS read ALIVE):
        //   M4a (gate-pinned, single-cycle latch): a read of word0 AND word1 both
        //   returned word2's data (0x40DE2222): the word SELECTION collapsed onto
        //   one fixed gearbox cycle (`word = mux(rdBeat[0], wordHi, wordLo)` picked
        //   lo/hi within ONE capture cycle, and the deferred +1 latch overshot the
        //   burst into a HOLD cycle where wordLo==wordHi).
        //   M4b (DATAVALID-rising-edge anchor + sliding pair): the deserialize
        //   shift WORKED: clean-eye readbacks moved off word2 onto WORD0
        //   (0x40DE00xx) at some taps. BUT word0 STILL == word1: DATAVALID is held
        //   HIGH as a LEVEL across the whole sweep (DIAG: DV=1, never a clean 2-beat
        //   toggle), so the dvRise anchor could still latch the {prev,cur} pair on a
        //   gearbox HOLD/repeat cycle where the four prev beats are NOT distinct.
        //
        //   M4c (fixed const readTail anchor + sliding pair): latched DISTINCT
        //   beats (bench saw word3 0x40DE3333 and a real w0!=w1 line), proving the
        //   {prev,cur} capture works, but readTail=2 mostly landed on HOLD cycles
        //   (w0==w1 at most taps, scrambled words across the TAP sweep). The right
        //   capture cycle is config-dependent and rebuilding per readTail was slow.
        //
        // FIX (M4d, this code, litedram ecp5ddrphy.py L434): make the timed-tail
        // anchor RUNTIME-SWEEPABLE by tying it to the SAME runtime RDSLACK knob
        // [rdSlackRt] the ddrlevel firmware already walks (with READCLKSEL and the
        // read TAP). The {prev,cur} capture anchors at rdPipe[clSys + rdSlackRt], so
        // each RDSLACK sweep step moves the fabric capture cycle and the existing
        // TAP x RCS x RDSLACK sweep finds the read cycle in ONE build (no per-value
        // rebuild). DATAVALID/BURSTDET stay wired ONLY as the software read-leveling
        // oracle (the live + sticky seen-bits, output above). They no longer gate
        // the data capture. This is exactly litedram's model: rddata_valid from the
        // timed TappedDelayLine tail, DATAVALID/BURSTDET as firmware-visible status.
        //
        //   1. ANCHOR: rdAnchor = rdPipe[clSys + rdSlackRt], a RUNTIME tap on the
        //      read-command shift register (the SAME indexed-mux pattern, padded to
        //      the full 2^slackW range with the s==0 fallback, as [windowOpen]). The
        //      ddrlevel RDSLACK loop sweeps rdSlackRt 0..maxRdSlack, stepping the
        //      capture cycle. When the anchor lands on the right cycle the IDDRX2DQA
        //      gearbox holds BL8 beats 0..3 in beat0..3. Latch them into the
        //      registered "prev window" (burstPrev0..3 <= beat0..3) and arm the
        //      one-shot [rdAssemble].
        //   2. SLIDING PAIR: one sclk later the gearbox has advanced and live
        //      beat0..3 hold BL8 beats 4..7 (the "cur window"). The held burstPrev
        //      (beats 0..3) Cat the live beat0..3 (beats 4..7) is the full 8 beats -
        //      exactly litedram's Cat(prev, cur).
        //   3. ASSEMBLE: on the [rdAssemble] sclk assemble the four fabric words
        //      from those 8 beats with [packWord] (the single HW-verified within-
        //      word helper, NO half-swap) and select by the FULL 2-bit rdBeat.
        //      rdValid asserts on this assemble cycle.
        //
        // The [windowOpen]/[rdGate] to the DQSBUFM (READ0/READ1) is UNCHANGED: it
        // already tracks rdSlackRt, so the gate and the capture move together. The
        // gate still produces the gearbox data and only the fabric CAPTURE cycle is
        // now runtime-tuned. The non-trainable (timed) path below and the write-
        // leveling feedback path are untouched.
        //
        // The runtime anchor tap. Built with the SAME bounds-safe indexed barrel-mux
        // as [windowOpen]: a contiguous slice rdPipe[clSys + s] for s in
        // 0..maxRdSlack, padded to the full 2^slackW index range with the s==0
        // fallback (rdPipe[clSys]) so an out-of-range rdSlackRt degrades to the
        // CL-aligned anchor rather than indexing past the vector. DATAVALID/BURSTDET
        // are NOT consumed here: they remain wired only as the software read-
        // leveling oracle (live + sticky seen-bit outputs, built earlier).
        // Lockstep -1 with the gate (board round-trip offset): anchor base clSys-1
        // so burstPrev latches the burst's FIRST half (beats 0..3 = words 0,1) which
        // the down-shifted valid window now presents first. Moving the anchor ALONE
        // (clSys-1 with the gate still at clSys) read PRE-window garbage (DV=0). The
        // gate moves with it.
        final anchorFallback = rdPipe[clSys - 1]; // s == 0 anchor (lockstep -1)
        final anchorCands = <Logic>[
          for (var s = 0; s <= maxRdSlack; s++) rdPipe[clSys - 1 + s],
          for (var s = maxRdSlack + 1; s < (1 << rdSlackRt!.width); s++)
            anchorFallback,
        ];
        final rdAnchor = anchorCands
            .rswizzle()
            .named('rd_anchor_slack')[rdSlackRt]
            .named('rd_anchor');
        // The burst's cycle-0 half (BL8 beats 0..3), latched on the [rdAnchor] tap
        // and held one sclk so it pairs with the CUR cycle's beats (BL8 beats 4..7)
        // on the assemble cycle. This IS the registered "prev window" of litedram's
        // Cat(prev, cur).
        final burstPrev0 = Logic(name: 'rd_burst0', width: dataBits);
        final burstPrev1 = Logic(name: 'rd_burst1', width: dataBits);
        final burstPrev2 = Logic(name: 'rd_burst2', width: dataBits);
        final burstPrev3 = Logic(name: 'rd_burst3', width: dataBits);
        // One-shot: assemble + select + rdValid on the sclk AFTER the anchor.
        final rdAssemble = Logic(name: 'rd_assemble');
        // (litedram ecp5ddrphy.py L376-400 read datapath, bitslips=4). The sliding-
        // pair anchor above gives the full BL8 as an 8-beat window in DRAM burst
        // order:
        //   hist8 = [burstPrev0..3 (beats 0..3), beat0..3 (beats 4..7)]
        // but WHICH captured beat is burst-beat-0 is a build/board-dependent gearbox
        // phase (the DQSR90 read-clock phase at DLL-on 144MHz picks a different Q as
        // beat0 than the CL-derived anchor predicts). litedram compensates with a
        // per-DQ BitSlip that SLIDES a 4-beat window across a continuously-shifting
        // {prev,cur} register. We express the equivalent realignment as an 8-position
        // runtime ROTATION of the anchored 8-beat window: aligned[p] = hist8[(slp +
        // p) % 8], slp in 0..7. NOTE (rotate vs slide): unlike litedram's monotone
        // slide (which can pull in the NEXT burst's beats at slp 5..7), this is a
        // pure cyclic rotate of the anchor-selected 8 samples: it reorders beats
        // WITHIN the window only. That is sufficient here because the COARSE
        // whole-cycle framing is done by the separate [rdSlackRt] anchor (which
        // moves the capture by whole sclk cycles = 4 beats). The reachable
        // alignment set is therefore [anchor coarse-cycle] x [rotate sub-window]:
        // the anchor picks the cycle pair, the rotate picks beat-0 within the 8-beat
        // {prev,cur} span, so any beat offset within a +-1-cycle bracket is
        // reachable. At the correctly-anchored cycle slp=0 gives the in-order burst.
        // This is what the old same-cycle 4-way rotation could NOT do: it permuted
        // within ONE sclk cycle only, so a burst whose beat0 fell in the previous
        // cycle was unreachable at every tap: the beat-scramble root cause.
        // slp is the FULL 3-bit runtime READCLKSEL knob [readClkSelRt] (READCLKSEL
        // itself is not a useful lever on this silicon, so it is repurposed as the
        // 8-way bitslip while still driving the DQSBUFM.READCLKSEL pin harmlessly).
        // The ddrlevel firmware ALREADY sweeps RCS 0..7 (rotate) AND RDSLACK 0..7
        // (anchor) AND RDTAP AND DYNDELAY, so the anchor x rotate eye is found in
        // ONE build with NO firmware change. On the non-trainable build there is no
        // rotation (that path never reaches here).
        final hist8 = <Logic>[
          burstPrev0,
          burstPrev1,
          burstPrev2,
          burstPrev3,
          beat0,
          beat1,
          beat2,
          beat3,
        ];
        final slp = readClkSelRt!.named('rd_bitslip');
        Logic alignedBeat(int p) => cases(slp, {
          for (var s = 0; s < 8; s++) Const(s, width: 3): hist8[(s + p) % 8],
        }, defaultValue: hist8[p]).named('rd_aligned_beat$p');
        // The four fabric words of the BL8 burst, packed with the HW-verified
        // within-word half order ([packWord]), sourced from the bitslip-aligned
        // 8-beat burst:
        //   word0 = aligned beats 0,1   word2 = aligned beats 4,5
        //   word1 = aligned beats 2,3   word3 = aligned beats 6,7
        // rdBeat (= the requested beatSel, full 2 bits) picks which word to keep.
        final aBeat0 = alignedBeat(0);
        final aBeat1 = alignedBeat(1);
        final aBeat2 = alignedBeat(2);
        final aBeat3 = alignedBeat(3);
        final aBeat4 = alignedBeat(4);
        final aBeat5 = alignedBeat(5);
        final aBeat6 = alignedBeat(6);
        final aBeat7 = alignedBeat(7);
        final word0 = packWord(aBeat0, aBeat1).named('rd_word0');
        final word1 = packWord(aBeat2, aBeat3).named('rd_word1');
        final word2 = packWord(aBeat4, aBeat5).named('rd_word2');
        final word3 = packWord(aBeat6, aBeat7).named('rd_word3');
        final selWord = cases(rdBeat, {
          Const(0, width: 2): word0,
          Const(1, width: 2): word1,
          Const(2, width: 2): word2,
          Const(3, width: 2): word3,
        }, defaultValue: word0).named('rd_sel_word');
        Sequential(sclk, reset: sclkReset, [
          rdPipe < [rdPipe.getRange(0, pipeLen - 1), rdStart].swizzle(),
          If(rdStart, then: [rdBeat < beatSel]),
          rdValid < 0,
          rdAssemble < 0,
          // ANCHOR (timed tail, RUNTIME RDSLACK-tuned): the [rdAnchor] tap (at
          // rdPipe[clSys + rdSlackRt]) lands on the capture cycle the firmware's
          // RDSLACK step selects, when it is the right cycle the gearbox holds BL8
          // beats 0..3. Latch the prev half and arm the one-shot assemble for the
          // NEXT sclk, by which time the cur cycle holds beats 4..7 to complete the
          // sliding pair. No DATAVALID gating.
          If(
            rdAnchor,
            then: [
              burstPrev0 < beat0,
              burstPrev1 < beat1,
              burstPrev2 < beat2,
              burstPrev3 < beat3,
              rdAssemble < 1,
            ],
          ),
          // ASSEMBLE cycle: the captured window is now the SLIDING PAIR
          // {burstPrev0..3 (beats 0..3), beat0..3 (beats 4..7)}. Select the
          // requested word by the FULL 2-bit rdBeat and ack. This is the
          // Cat(prev, cur) deserialize point.
          If(rdAssemble, then: [rdData < selWord, rdValid < 1]),
        ]);
        // [rdActive]/[rdBeats] are the non-trainable sequencer-count bookkeeping.
        // The trainable capture is now wholly [rdPipe]-timed (the fixed [rdAnchor]
        // tap), so they stay at reset here and the gate runs off windowOpen alone.
      } else {
        // NON-TRAINABLE (legacy / Xilinx-style): sequencer-timed capture. rdValid
        // is timed off the [rdPipe] counter, never DATAVALID (which is X in sim).
        // This is the proven single-clock bring-up path, unchanged.
        Sequential(sclk, reset: sclkReset, [
          rdPipe < [rdPipe.getRange(0, pipeLen - 1), rdStart].swizzle(),
          If(rdStart, then: [rdBeat < beatSel]),
          rdValid < 0,
          If(windowOpen, then: [rdActive < 1, rdBeats < 0]),
          If(
            rdActive,
            then: [
              rdBeats < rdBeats + 1,
              // Two capture cycles: the low SCLK word covers beatSel 0/1 (low bit
              // of beatSel selects wordLo vs wordHi), the high covers 2/3. The
              // capture cycle is [loBeat]/[hiBeat]: 0/1 normally, advanced to 1/2
              // when readCrossPair steps past the write->read turnaround delay.
              If(
                rdBeats.eq(Const(loBeat, width: 3)),
                then: [
                  If(~rdBeat[1], then: [rdData < word, rdValid < 1]),
                ],
              ),
              If(
                rdBeats.eq(Const(hiBeat, width: 3)),
                then: [
                  If(rdBeat[1], then: [rdData < word, rdValid < 1]),
                ],
              ),
              If(rdBeats.eq(Const(hiBeat + 1, width: 3)), then: [rdActive < 0]),
            ],
          ),
        ]);
      }
    } else {
      // The hardware-PROVEN pre-Milestone-4 path (worked on the OrangeCrab at 48
      // MHz). Bidirectional x2 DQ REQUIRES the DQS-bonded IOLOGIC (DLL-locked),
      // which nextpnr cannot pack DLL-off ("IDDRXN and ODDRXN on the same pin is
      // unsupported"). x1 IDDRX1F+ODDRX1F SHARE one bidir-pad SCLK (clk90), which
      // DOES pack. Everything runs on a single CK-rate fabric: DQ/DM/DQS launch on
      // [clk90] (the dedicated PHY-PLL -90deg phase) so the data eyes straddle the
      // CK-aligned strobe. Reads capture each DQ through a static DELAYG into an
      // IDDRX1F on the SAME clk90 (a bidir pad's input + output IOLOGIC must share
      // SCLK). The sequencer feeds wrStart/wrData on [clk] = CK (ddr.dart selects
      // the CK-rate sequencer clock when !dllOn). Ported from the committed HEAD
      // DdrPhyEcp5, adapted to the PHY-owned Ecp5Bb pads (vs HEAD's dq_out/dq_oe).

      // The x1 datapath never uses the DQSBUFM strobes. Drive the forward-declared
      // [rdGate] (DQSBUFM READ0/READ1, unused DLL-off) to a defined 0 so the
      // unconditional DQSBUFM has a defined (but unused) read gate.
      rdGate <= Const(0);

      // wrStart pulses at the WRITE command. Data must be on the pins CWL cycles
      // later for 4 CKs. A shift register delays the launch, then a beat counter
      // walks the 4 beat-pairs. Only the addressed word's two beats carry data
      // (DM low). The launch taps sit [oddrLatency] cycles early: ODDRX1F
      // pipelines ~2 cycles between sampling D and presenting at the pad
      // (measured on the OrangeCrab). CK is periodic so its ODDR latency is
      // invisible. Commands are plain registers, only the write burst needs this.
      const oddrLatency = 2;
      final wrPipe = Logic(name: 'wr_pipe', width: cwl);
      final wrBeats = Logic(name: 'wr_beats', width: 3);
      final wrActive = Logic(name: 'wr_active');
      final wrWord = Logic(name: 'wr_word', width: 32);
      final wrSel = Logic(name: 'wr_sel', width: 4);
      final wrBeat = Logic(name: 'wr_beat', width: 2);
      Sequential(clk, reset: clkReset, [
        wrPipe < [wrPipe.getRange(0, cwl - 1), wrStart].swizzle(),
        If(wrStart, then: [wrWord < wrData, wrSel < wrMask, wrBeat < beatSel]),
        If(wrPipe[cwl - 1 - oddrLatency], then: [wrActive < 1, wrBeats < 0]),
        If(
          wrActive,
          then: [
            wrBeats < wrBeats + 1,
            If(wrBeats.eq(Const(3, width: 3)), then: [wrActive < 0]),
          ],
        ),
      ]);
      final beatNow = wrBeats.getRange(0, 2);
      final beatHit = (wrActive & beatNow.eq(wrBeat)).named('wr_beat_hit');

      // OE delays: the tristate path is fabric-driven (no ODDR), so the OE is
      // delayed to track the burst in pad time (an undelayed OE would drop before
      // the last beats clear the ODDR pipeline, chopping the tail to Hi-Z).
      final wrActiveD1 = Logic(name: 'wr_active_d1');
      final wrActiveD2 = Logic(name: 'wr_active_d2');
      final wrActiveD3 = Logic(name: 'wr_active_d3');
      final wrActiveD4 = Logic(name: 'wr_active_d4');
      Sequential(clk, reset: clkReset, [
        wrActiveD1 < wrActive,
        wrActiveD2 < wrActiveD1,
        wrActiveD3 < wrActiveD2,
        wrActiveD4 < wrActiveD3,
      ]);
      // Active-high HiZ enable for the Ecp5Bb `.t` (T=1 -> HiZ, T=0 -> drive). The
      // DQ/DQS drive window is wrActiveD2|D3|D4, so HiZ is its complement.
      final dqDriveWin = (wrActiveD2 | wrActiveD3 | wrActiveD4).named(
        'dq_drive_win',
      );
      final dqPadTriN = (~dqDriveWin).named('dq_pad_tri_n');

      // DQ: low half-word in the q0 slot (rising beat), high in q1 (falling), both
      // halves in the same clk90 cycle (the q0=rise assignment is silicon-
      // calibrated). DM gates which beats the part keeps. Each DQ pad is a plain
      // bidirectional Ecp5Bb: ODDRX1F drive on clk90 -> `.i`, fabric OE -> `.t`,
      // pad read `.o` -> the DELAYG+IDDRX1F read capture below.
      final dqRise = wrWord.getRange(0, dataBits);
      final dqFall = wrWord.getRange(dataBits, 32);
      final dqReadBits = <Logic>[];
      for (var i = 0; i < dataBits; i++) {
        final dqDrive = Ecp5Oddrx1f(
          sclk: clk90,
          rst: clkReset,
          d0: dqRise[i],
          d1: dqFall[i],
          name: 'dq_oddr_$i',
        ).q;
        final dqBb = Ecp5Bb(
          i: dqDrive,
          t: dqPadTriN,
          b: dqPadNet[i],
          name: 'dq_bb_$i',
        );
        dqReadBits.add(dqBb.o);
      }

      // DM: mask everything except the addressed word's enabled byte lanes (DM=1
      // = ignore this byte). Same-cycle slots: q0 (rising) masks lanes 0/1, q1
      // (falling) masks 2/3. Output-only pad (no tristate).
      final dmBits = <Logic>[
        for (var l = 0; l < laneCount; l++)
          Ecp5Oddrx1f(
            sclk: clk90,
            rst: clkReset,
            d0: ~(beatHit & wrSel[l]),
            d1: ~(beatHit & wrSel[2 + l]),
            name: 'dm_oddr_$l',
          ).q,
      ];
      dmOut <= dmBits.rswizzle();

      // DQS: toggles 1/0 during the burst, EXPLICIT pseudo-differential (dqs_p +
      // dqs_n), exactly like CK/CK#. The _p pad is the PHY-owned Ecp5Bb built
      // earlier (dqsDrive/dqsTriN feed it): drive its `.i` with the strobe ODDR
      // and its `.t` with the delayed OE (active-high HiZ). The _n pad is a
      // SEPARATE Ecp5Bb on the dedicated _n net, driven by the complement ODDR
      // (d0=~wrActive, d1=1), same OE. (DLL-on uses the single SSTL135D_I diff pad
      // with nextpnr deriving _n. No _n net exists there.)
      //
      // CLOCK: the DQS strobe ODDRs run on [clk90b] = CLKOS2 (a 50%-duty PLL
      // output), NOT `clk`/sclk. This is the write-side structural fix: the DQS
      // pad is output-only (no read IDDR), so it can use its own clock and still
      // pack. With the DQ on the 50%-duty CLKOS (clk90) and the DQS on the 50%-
      // duty CLKOS2 (clk90b), BOTH edge spacings are structurally tCK/2, so the
      // DQS edges can center BOTH DQ beats (vs the old `clk`/sclk DQS whose
      // non-50% edges only centered one, HW write sweep: non-overlapping good
      // zones). CLKOS2_CPHASE tunes the DQS-vs-DQ centering. The OE window stays
      // on the clk-domain drive window (wide preamble/postamble margin).
      final dqsClk = clk90b!;
      final dqsPadTriN = (~dqDriveWin).named('dqs_pad_tri_n');
      for (var l = 0; l < laneCount; l++) {
        dqsDrive[l] <=
            Ecp5Oddrx1f(
              sclk: dqsClk,
              rst: clkReset,
              d0: wrActive,
              d1: Const(0),
              name: 'dqs_oddr_$l',
            ).q;
        dqsTriN[l] <= dqsPadTriN;
        // Explicit DQS# complement pad (the all-taps-E0 fix). Built only when the
        // _n net exists (DLL-off + a board _n pin). The complement strobe edges
        // mirror dqs_p so the DRAM's differential strobe receiver sees a valid
        // pair on write.
        if (dqsNPadNet != null) {
          final dqsNDrive = Ecp5Oddrx1f(
            sclk: dqsClk,
            rst: clkReset,
            d0: ~wrActive,
            d1: Const(1),
            name: 'dqs_n_oddr_$l',
          ).q;
          Ecp5Bb(
            i: dqsNDrive,
            t: dqsPadTriN,
            b: dqsNPadNet[l],
            name: 'dqs_n_bb_$l',
          );
        }
      }

      // Read engine. rdStart pulses at the READ command. Each DQ passes through a
      // static DELAYG and an IDDRX1F on clk90 (shared bidir-pad clock), a window
      // counter opens CL+rdSlack cycles after the command, captures the 4 beat-
      // pairs, and selects the addressed word. rdSlack is the [readSlack] ctor
      // knob (HEAD/bring-up used 1): DLL-off read latency is CL-1 and tDQSCK is
      // large, so the burst lands earlier than DLL-on arithmetic predicts. It is
      // the full-CYCLE bench axis (slides the whole capture window). [readPairMode]
      // below is the half-beat EDGE/assembly axis, and [readTaps] (the DELAYG) is
      // the sub-beat eye axis.
      final rdSlack = readSlack;
      final rdPipe = Logic(name: 'rd_pipe', width: cl + rdSlack);
      final rdBeats = Logic(name: 'rd_beats', width: 3);
      final rdActive = Logic(name: 'rd_active');
      final rdBeat = Logic(name: 'rd_beat', width: 2);
      final q0Bits = <Logic>[];
      final q1Bits = <Logic>[];
      // SINGLE x1 capture per DQ pad. PROVEN (3 nextpnr pack probes) that a bidir
      // DQ pad at DLL-off admits ONLY x1-in + x1-out on ONE shared clock: a 2nd
      // IDDR fails ("D must connect only to a top level input"), an x2 read IDDR
      // (IDDRX2F) + x1 write conflicts ("IDDRX1_ODDRX1 vs IDDRXN") and + x2 write
      // crashes nextpnr ("IDDRXN+ODDRXN unsupported"), and a read IDDR on a clock
      // != the write ODDR's conflicts ("conflicting clocks"). So read = one
      // IDDRX1F on clk90 (the same clock the write ODDR uses), two edges q0/q1
      // fixed tCK/2 apart. The eye-landing lever is the per-pad DELAYG read tap
      // ([readTaps], now wired). CLKOS_CPHASE is inert for read-vs-write (write +
      // read share clk90, so it shifts both together).
      // PER-LANE read deskew: byte0 (lane0 DQ0-7 rise) reads STALE on marginal
      // HW reads while lane1/fall are clean = lane0 has a read-skew the single
      // uniform DELAYG cannot center. READ_TAP_LANE0 (env, 0..127) overrides
      // lane 0's static read tap independently. Other lanes keep [readTaps].
      // Swept on HW to land lane0's rise edge. Default = readTaps (no change).
      final readTapLane0 = int.parse(
        Platform.environment['READ_TAP_LANE0'] ?? '$readTaps',
      );
      for (var i = 0; i < dataBits; i++) {
        final dly = Ecp5Delayg(
          a: dqReadBits[i],
          delValue: (i ~/ 8) == 0 ? readTapLane0 : readTaps,
          name: 'dq_dly_$i',
        );
        final iddr = Ecp5Iddrx1f(
          sclk: clk90,
          rst: clkReset,
          d: dly.z,
          name: 'dq_iddr_$i',
        );
        q0Bits.add(iddr.q0);
        q1Bits.add(iddr.q1);
      }
      final q0Cap = q0Bits.rswizzle().named('cap_q0'); // clk90 rise-edge sample
      final q1Cap = q1Bits.rswizzle().named('cap_q1'); // clk90 fall-edge sample

      // x1 READ DESERIALIZE ASSEMBLY ([readPairMode], the bench knob).
      // The write->read turnaround / read preamble dead-zones the clk90 RISE
      // sample (q0): on this turnaround q0 reads a constant, READ-TAP-INSENSITIVE
      // garbage value while the FALL sample (q1) is clean (bench, write C1C1C1C1:
      // same-cycle high16=q1 clean, low16=q0 garbage. The {q0Cap,q1Prev} cross
      // recovered low16=q1Prev but high16=q0 stayed garbage). So the usable data
      // is on q1 only. [readPairMode] selects how the word's two halves are sourced:
      //   0 = {q1Cap, q0Cap}   HEAD same-cycle (high16=fall q1, low16=rise q0)
      //   1 = {q0Cap, q1Prev}  cross: low16 from the registered clean q1
      //   2 = {q1Cap, q1Prev}  q1-ONLY: both halves from the clean fall edge
      // FSM ADVANCE RATE: the read FSM advances ONE fabric WORD per clk90 cycle
      // (= TWO DRAM beats/cycle, q0+q1 are the two beats of one word, rdBeats
      // counts the 4 words). So q1Cap and q1Prev are the clean fall-beats of
      // CONSECUTIVE WORDS (2 DRAM beats apart), NOT adjacent beats within one word:
      // mode 2 reads uniform data (C1C1C1C1) correctly but for general data the
      // real cure is centering q0 back into the eye via the (now-wired) read tap,
      // or a 1-beat/cycle q1-only redeserialize. Modes 1/2 read the previous
      // cycle's registered samples, so they capture one cycle later (the
      // sliding-pair point), mode 0 is same-cycle and byte-identical to HEAD.
      final cross = readPairMode != 0;
      final q1Prev = Logic(name: 'cap_q1_prev', width: dataBits);
      // {high16, low16}. Swizzle puts the first list element in the MSBs.
      final word = (switch (readPairMode) {
        1 => [q0Cap, q1Prev],
        2 => [q1Cap, q1Prev],
        _ => [q1Cap, q0Cap],
      }).swizzle().named('rd_word');
      // Cross modes land the assembled word one cycle later (the sliding-pair
      // deserialize point): match rdBeat+1 and extend the active window by one.
      // Dual-phase and same-cycle modes capture at rdBeats==rdBeat.
      final capMatch = cross
          ? rdBeats.eq((rdBeat.zeroExtend(3) + 1).named('rd_cap_beat'))
          : rdBeats.getRange(0, 2).eq(rdBeat);
      final lastBeat = cross ? 4 : 3;

      Sequential(clk, reset: clkReset, [
        rdPipe < [rdPipe.getRange(0, cl + rdSlack - 1), rdStart].swizzle(),
        If(rdStart, then: [rdBeat < beatSel]),
        rdValid < 0,
        // Register the clean fall sample for the cross-cycle sliding pair.
        q1Prev < q1Cap,
        If(rdPipe[cl + rdSlack - 1], then: [rdActive < 1, rdBeats < 0]),
        If(
          rdActive,
          then: [
            rdBeats < rdBeats + 1,
            If(capMatch, then: [rdData < word, rdValid < 1]),
            If(rdBeats.eq(Const(lastBeat, width: 3)), then: [rdActive < 0]),
          ],
        ),
      ]);

      // Write-control diagnostic counters (DLL-on builds these from the x2 OE/DM/
      // data windows). Provide the SAME outputs DLL-off, driven from the x1
      // engine's equivalents (the trainable STATUS path reads them), so the port
      // set is identical across both builds.
      final wrOeCount = Logic(name: 'ddr_wr_oe_count', width: 8);
      final wrDmCount = Logic(name: 'ddr_wr_dm_count', width: 8);
      final wrDatCount = Logic(name: 'ddr_wr_dat_count', width: 8);
      final dmAnyLow = [
        for (var l = 0; l < laneCount; l++) beatHit & (wrSel[l] | wrSel[2 + l]),
      ].swizzle().or().named('ddr_wr_dm_any_low');
      Logic satInc(Logic ctr, Logic ev) =>
          mux(ev & ~ctr.eq(Const(0xFF, width: 8)), ctr + 1, ctr);
      Sequential(
        clk,
        reset: clkReset,
        resetValues: {
          wrOeCount: Const(0, width: 8),
          wrDmCount: Const(0, width: 8),
          wrDatCount: Const(0, width: 8),
        },
        [
          wrOeCount < satInc(wrOeCount, dqDriveWin),
          wrDmCount < satInc(wrDmCount, dmAnyLow),
          wrDatCount < satInc(wrDatCount, wrActive),
        ],
      );
      addOutput('wr_oe_count', width: 8) <= wrOeCount;
      addOutput('wr_dm_count', width: 8) <= wrDmCount;
      addOutput('wr_dat_count', width: 8) <= wrDatCount;

      // Write-leveling feedback output: the x1 DLL-off path has no DQS-strobed WL
      // capture, so when the writeLevel build is requested at DLL-off drive the
      // feedback to a defined 0 (the WL FSM in the sequencer still terminates via
      // its bounded sweep). Keeps the port present for the writeLevel build.
      if (writeLevel) {
        output('wl_feedback') <= Const(0);
      }
    }
  }
}
