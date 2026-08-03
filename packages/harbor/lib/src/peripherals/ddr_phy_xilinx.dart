import 'package:rohd/rohd.dart';

import '../blackbox/xilinx/xilinx.dart';
import 'ddr_phy.dart';
import 'ddr_read_assembler.dart';

/// Xilinx 7-series (Spartan 7) DDR3 PHY for the DLL-off bring-up
/// configuration, the structural counterpart of [DdrPhyEcp5]: DDR CK equals
/// the system clock, commands are 1T SDR-registered, and the data path uses
/// ODDR/IDDR gearing with an MMCM-derived 90-degree write-launch clock and
/// static IDELAYE2 read taps.
///
/// IMPORTANT: not yet silicon-calibrated. The ECP5 PHY's magic constants were
/// measured on the OrangeCrab. The equivalents here ([oddrLatency], [readTaps],
/// the read-window slack, the clk90 phase, and the IDELAYCTRL reference clock)
/// are best-effort placeholders to be tuned during Arty S7 bring-up. The
/// structure elaborates and emits clean SystemVerilog, the timing numbers are
/// where the board work happens.
///
/// Read training (a runtime IDELAYE2 walk) is a follow-up: this builds the
/// static read path only, mirroring the ECP5 non-trainable case.
class DdrPhyXilinx extends DdrPhy {
  /// IDELAYCTRL RDY: high once the delay line has calibrated against a stable
  /// REFCLK after a >= 52 ns RST. Surfaced so the controller can splice it into
  /// the read-training STATUS register (the calibration smoking gun).
  Logic get idelayRdy => output('idelay_rdy');

  /// Lane-selected DQ write-leveling feedback (ctrl83 domain). During WL the
  /// DRAM samples CK on the DQS rising edge and drives the (static) result back
  /// on DQ. This is the captured feedback bit the sequencer's WL FSM samples. On
  /// ddr3Fast the read ISERDESE2 free-runs on CK (no DQS gate), so the static
  /// level appears on its Q beats directly. Only present on the writeLevel build
  /// (X in sim, real on hardware). The sequencer already ticks on ctrl83, so this
  /// is the SAME clock domain (no CDC), unlike the ECP5 sclk-crossed feedback.
  Logic get wlFeedbackOut => output('wl_feedback');

  DdrPhyXilinx(
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
    // DQ read returns (from the controller's pads).
    required Logic dqIn,
    required int rowBits,
    required int baBits,
    int dataBits = 16,
    int clkMhz = 48,
    // JEDEC CAS latency / CAS write latency in CK cycles. 6 on the 48 MHz DLL-off
    // path, 5 for DDR3-667 (the >=3000 ps tCK speed bin) on the ddr3Fast path.
    // Drives the read-window CL anchor and the write-launch CWL offset.
    int cl = 6,
    int cwl = 6,
    // CK cycles per controller (CLKDIV) tick. 1 on the 48 MHz path (the PHY runs
    // at the CK rate). 4 on ddr3Fast (the OSERDESE2/ISERDESE2 gearbox serializes
    // 4 CK per ctrl83 tick), so a CK-quoted CWL/CL splits into a whole-tick launch
    // (CWL~/4) plus a sub-tick beat offset (CWL%4 CK = (CWL%4)*2 DDR beats).
    int ckCyclesPerTick = 1,
    int readTaps = 16,
    // Read-window slide in whole CK cycles (the coarse read-landing knob). The
    // DQ capture happens on the local clock with no read-DQS gating, so the
    // window that opens (CL + readSlack + iddrLatency) cycles after the read
    // command must be swept on hardware to land on the returned burst. Threaded
    // from --ddr-read-slack.
    int readSlack = 1,
    // When true, derive the 90-degree write-launch clock from an on-chip MMCM
    // (the timing-correct path, used on a real Vivado backend). When false, the
    // 90-degree clock is just [clk] with no MMCM: the openXC7 Spartan-7 flow
    // cannot use an MMCM at all (its output divider does not take effect on
    // silicon, see the River notes), so a DLL-off bring-up at a low CK rate
    // (~12 MHz, ~83 ns bit period) launches DQ/DQS straight off the system
    // clock. Coarse but workable given the wide eye.
    bool mmcmPhaseClock = true,
    // REAL-SPEED DDR3-667 READ DATAPATH (the production counterpart of the
    // 48 MHz DLL-off IDDR path). When true, the read side is rebuilt the
    // UberDDR3 / LiteDRAM way and this PHY runs at real DDR3 speed:
    //   - a full DDR3 clock tree (MMCM ZHOLD -> ck333 DDR CK / ctrl83
    //     controller=CLKDIV=CK/4 / idelayref200 / ck90 write-launch, each on its
    //     own BUFG) is built inline from [clk] (the ~100 MHz or ~12 MHz osc).
    //   - each of the 16 DQ bits is captured pad -> IDELAYE2(VAR_LOAD, DDLY) ->
    //     ISERDESE2(DATA_WIDTH=8, DDR, NETWORKING, IOBDELAY=IFD, CLK=ck333,
    //     CLKDIV=ctrl83 on a SEPARATE BUFG: the routing key, OCLK/OCLKB
    //     UNCONNECTED: the routing fix), so the WHOLE BL8 (8 beats) arrives on
    //     Q1..Q8 in one ctrl83 cycle.
    //   - ONE IDELAYCTRL (200 MHz ref, RST held >= 52 ns) calibrates all 16.
    //   - a [DdrBl8SerdesAssembler] captures the 128-bit line on the read window
    //     and selects the beatSel word, keeping the rd_data/rd_valid contract.
    // The controller drives this PHY on the ctrl83 clock ([clk] here IS the
    // 83 MHz controller clock when ddr3Fast is set, see HarborDdrController's
    // ddr3Fast wiring), and ck333/ck90/idelayref200 come off the internal tree.
    // When false the existing 48 MHz IDDR path is byte-for-byte unchanged.
    bool ddr3Fast = false,
    // Read-DQS window gate (ddr3Fast only). When true, the read capture window is
    // opened by the DRAM's own read strobe (DQS captured as data on CK, its
    // toggling picks the valid ctrl83 cycle) instead of the fixed CL+readSlack
    // tap, which mis-frames under the i+d read cadence. False = the fixed-tap path
    // is byte-for-byte unchanged.
    bool dqsGatedRead = false,
    // ddr3Fast clock tree, supplied by the caller (genip builds the shared MMCM
    // DDR3 tree once so the sequencer's ddr_clk == this PHY's controller clock).
    // [clk] is the ctrl83 (= CK/4 = CLKDIV) controller clock, [ckFast] is the
    // ck333 DDR CK (ISERDESE2 CLK), [ck90Fast] is the 90-degree ck333 for the
    // write launch, [idelayRef] is the ~200 MHz IDELAYCTRL reference. Required
    // when ddr3Fast is set, ignored otherwise.
    Logic? ckFast,
    Logic? ck90Fast,
    // [ckDqsFast] is the DDR3 write DQS launch clock (default 180-degree ck333,
    // the UberDDR3 Arty HR-bank oracle's !i_ddr3_clk): DQS launches on this while
    // DQ/DM ride ck90Fast, so the DQS edge lands centered in the DQ eye AND the
    // strobe frames the write off CK (JEDEC tDQSS). Optional: when null, the DQS
    // OSERDES falls back to ckFast (the prior ck0 behaviour), so an old caller
    // that does not supply it stays byte-identical.
    Logic? ckDqsFast,
    Logic? idelayRef,
    double idelayRefFastMhz = 200.0,
    // ddr3Fast owns its DQ/DQS pads (like the ECP5 PHY) so the write DQ/DQS
    // OSERDESE2's OQ (data) + TQ (in-site tristate) drive the pad IOBUF I/T pins
    // directly, keeping the tristate in-site (ODDR_TDDR.IN_USE), the fix for the
    // OLOGIC_D1 overused=32 route stall that a shared FABRIC tristate causes.
    // Required when ddr3Fast. The controller passes the inout pad nets and does
    // NOT build its own TriStateBuffer for these. DQ read data comes from the
    // OSERDESE2's sibling IDELAYE2/ISERDESE2 off the pad IOBUF's O output, so the
    // dqIn PORT is unused in ddr3Fast (kept for the 48 MHz path).
    Logic? padDq,
    Logic? padDqs,
    Logic? padDqsN,
    // OPTIONAL per-lane read-training controls (from XilinxReadTrainRegs). All
    // null on the non-trainable build, which keeps the read path byte-identical
    // to the static baseline: the IDELAYE2s stay FIXED and the fabric bitslip
    // stays the HARBOR_DDR_BITSLIP compile-time select. When present, each per-DQ
    // IDELAYE2 becomes VARIABLE and takes CE/INC/LD gated by an [idelayLane]
    // match, and the fabric bitslip select becomes a runtime 2-bit rotate
    // register that advances on each [bitslip] pulse. [bitslipLane] is accepted
    // for interface parity with the ISERDESE2 per-lane BITSLIP but the fabric
    // re-pair is word-wide (all lanes share one select), so it is not consumed.
    Logic? idelayLd,
    Logic? idelayCntValue,
    Logic? idelayLane,
    Logic? bitslip,
    Logic? bitslipLane,
    // ddr3Fast runtime read-window select: a 4-bit tap into the ISERDESE2 read
    // pipe (reg12). When present it overrides the compile-time [readSlack]-
    // derived window tap, so firmware walks the coarse ctrl83 capture cycle to
    // land the BL8 line without a rebuild. Ignored on the 48 MHz IDDR path.
    Logic? windowSel,
    // Read-calibration channel from the sequencer's sRdCal FSM. While
    // [rdCalActive] the PHY takes its per-lane IDELAY tap/bitslip/window from
    // these instead of the firmware regs above, and reports per-lane MPR match
    // on [rdCalMatchOut]. Tied off (firmware path) when null.
    Logic? rdCalActive,
    Logic? rdCalIdelayLd,
    Logic? rdCalTap, // 5-bit absolute IDELAY tap
    Logic? rdCalLane, // laneSelW
    Logic? rdCalWindow, // 4-bit read window for rdCalLane
    Logic? rdCalBitslip,
    // When [writeLevel] is set, the sequencer's WL FSM drives these controls to
    // train each byte lane's write DQS-to-CK alignment. On ddr3Fast the Arty HR
    // bank has NO per-lane output ODELAY, so the only per-lane write actuator is
    // the BEAT ROTATION of a lane's DQS/DQ within the OSERDESE2 8-beat word (the
    // same lever [HARBOR_DDR_DQBEAT1] exposes): each beat is 0.5 CK, so a 0..7
    // rotation walks the DQS edge across 4 CK. The PHY: (a) during WL ([wlEn])
    // drives the SELECTED lane's DQS as a single rising edge at beat [pos] (from
    // [wlStrobe]) while DQ stays an INPUT so the DRAM's WL feedback comes back on
    // DQ, exposed as [wlFeedbackOut]. (b) steps the per-lane rotation pointer on
    // [wlDelayRst]/[wlDelayInc]. (c) after WL ([wlDone]) applies the trained
    // per-lane tap to the normal write DQ+DQS beats. Off (default) leaves the
    // rotation at the env fallback and the read/write path byte-identical. The
    // port set (names/widths) mirrors [DdrPhyEcp5] so the PHY-agnostic sequencer
    // wires the same WL channel to either PHY.
    bool writeLevel = false,
    Logic? wlEn,
    Logic? wlDelayRst,
    Logic? wlDelayInc,
    Logic? wlStrobe,
    Logic? wlLane,
    Logic? wlTrained,
    Logic? wlDone,
    // Firmware write-beat OVERRIDE (Xilinx runtime write-DQS re-center). When
    // [wlPosOvrEn], each byte lane's write-beat rotation [pos] is forced to the
    // per-lane 3-bit field in [wlPosOvr] (bits [l*4 +: 3]) instead of the WL-
    // trained tap, so the FSBL can sweep the write launch at any CK without a
    // rebuild (and without WL, which needs a roughly-right DQS to even train).
    Logic? wlPosOvr,
    Logic? wlPosOvrEn,
    // Write/command timing tuning, threaded from the region params + board
    // defaults (previously the HARBOR_DDR_CMDSLOT/WRSHIFT/WRBEAT env reads).
    // [cmdSlot] picks which of the 4 CK edges of a ddr3Fast tick carries the
    // command (clamped 0..3). [writeShift] slides the whole write-launch window
    // in ticks. [wrBeatOffset] is the sub-tick DDR beat rotation, null derives
    // it from CWL ((cwl%tick)*2 | 1). All ddr3Fast-only.
    int cmdSlot = 0,
    int writeShift = 0,
    int? wrBeatOffset,
    super.name = 'ddr_phy',
  }) {
    // CL/CWL now come from the [cl]/[cwl] parameters (6 on the 48 MHz DLL-off
    // path, 5 for DDR3-667). Real values come from the part config and speed bin.

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
    dqIn = addInput('dq_in', dqIn, width: dataBits);

    // ddr3Fast clock-tree inputs (the shared MMCM DDR3 tree from genip). Only
    // present in ddr3Fast mode. [clk] above IS the ctrl83 controller/CLKDIV clock.
    Logic? ckFastIn, ck90FastIn, ckDqsFastIn, idelayRefIn;
    LogicNet? padDqIn, padDqsIn, padDqsNIn;
    if (ddr3Fast) {
      if (ckFast == null || ck90Fast == null || idelayRef == null) {
        throw ArgumentError(
          'ddr3Fast requires ckFast (ck333), ck90Fast (ck333@90) and '
          'idelayRef (~200 MHz) clock nets from the DDR3 clock tree.',
        );
      }
      if (padDq == null || padDqs == null || padDqsN == null) {
        throw ArgumentError(
          'ddr3Fast requires the DQ/DQS/DQS# inout pad nets (padDq, padDqs, '
          'padDqsN): the write OSERDESE2 owns the pad IOBUF so its in-site '
          'tristate (TQ) reaches the pad T pin directly.',
        );
      }
      ckFastIn = addInput('ck_fast', ckFast);
      ck90FastIn = addInput('ck90_fast', ck90Fast);
      // Optional dedicated DQS launch clock (180-deg CK). Falls back to ckFast
      // (ck0) when the caller does not wire it, keeping old callers unchanged.
      ckDqsFastIn = ckDqsFast != null
          ? addInput('ck_dqs_fast', ckDqsFast)
          : null;
      idelayRefIn = addInput('idelay_ref', idelayRef);
      padDqIn = addInOut('pad_dq', padDq, width: dataBits);
      padDqsIn = addInOut('pad_dqs', padDqs, width: dataBits ~/ 8);
      padDqsNIn = addInOut('pad_dqs_n', padDqsN, width: dataBits ~/ 8);
    }

    // Write-leveling control inputs from the sequencer's WL FSM. Registered only
    // when [writeLevel], tied off internally otherwise. WL is only realizable on
    // the ddr3Fast OSERDES/ISERDES datapath (the beat-rotation actuator + the
    // free-running ISERDESE2 feedback capture), so a writeLevel build must be
    // ddr3Fast. The ddr.dart gate enforces this (writeLevel && ddr3Fast).
    assert(
      !writeLevel || ddr3Fast,
      'writeLevel on the Xilinx PHY requires ddr3Fast (no per-lane write '
      'actuator exists on the 48 MHz IDDR path).',
    );
    final laneCount = dataBits ~/ 8;
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
    // Firmware write-beat override (per-lane 3-bit fields packed 4b/lane) + its
    // enable. Tied off (disabled) when not driven.
    // Fixed 8-bit (holds up to 2 lanes x 4b), matching the reg14 wr_beat_ovr
    // output width; each lane slices its own 4b field. Fixed (not 4*laneCount) so
    // a laneCount=1 (x8) part still accepts the 8-bit register value.
    final wlPosOvrIn = writeLevel
        ? addInput(
            'wl_pos_ovr',
            (wlPosOvr ?? Const(0, width: 8)).zeroExtend(8),
            width: 8,
          )
        : null;
    final wlPosOvrEnIn = writeLevel
        ? addInput('wl_pos_ovr_en', wlPosOvrEn ?? Const(0))
        : null;

    addOutput('rd_data', width: 32);
    addOutput('rd_valid');
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
    addOutput('dq_out', width: dataBits);
    addOutput('dq_oe');
    addOutput('dqs_out', width: dataBits ~/ 8);
    addOutput('dqs_n_out', width: dataBits ~/ 8);
    addOutput('dqs_oe');
    // IDELAYCTRL RDY, surfaced for the STATUS register (see [idelayRdy]).
    addOutput('idelay_rdy');
    if (writeLevel) {
      // Lane-selected DQ feedback the DRAM drives back during WL. Driven from the
      // free-running ISERDESE2 capture in the ddr3Fast read block below. On the
      // (unreachable) writeLevel && !ddr3Fast path it is tied off just below.
      addOutput('wl_feedback');
    }
    // WL is only wired on ddr3Fast. On the 48 MHz IDDR path there is no per-lane
    // write actuator, so tie the feedback off (the ddr.dart gate never enables
    // writeLevel here, but keep the port defined-and-driven).
    if (writeLevel && !ddr3Fast) {
      output('wl_feedback') <= Const(0);
    }

    // 90-degree write-launch clock. With [mmcmPhaseClock] it comes from an MMCM
    // in 1:1 mode with a 90-degree CLKOUT0 phase (the timing-correct path). The
    // multiplier keeps the VCO in the 7-series 600-1200 MHz window. The MMCM
    // uses a BUFG in the feedback path and COMPENSATION ZHOLD (the default of
    // XilinxMmcme2Adv): openXC7 only locks the MMCM that way. clk90 is buffered
    // onto a global clock net so it can drive the IDDR reads and the ODDRs.
    // Without the MMCM ([mmcmPhaseClock] false) the launch clock is just [clk].
    // IDELAYCTRL reference clock and its ACTUAL frequency (MHz). The IDELAYE2
    // taps only calibrate when IDELAYCTRL is fed a real ~200 MHz reference whose
    // rate matches the IDELAYE2 REFCLK_FREQUENCY parameter, otherwise RDY never
    // asserts and the VARIABLE taps do not move (the empty-eye read-training
    // bug). In the MMCM branch a dedicated CLKOUT1 supplies it, in the else
    // branch there is no ~200 MHz source, so this falls back to [clk] (which
    // will NOT calibrate. The else path is the openXC7-unusable-MMCM bring-up
    // and is not the trainable build).
    // REAL-SPEED READ FOUNDATION PROBE (HARBOR_DDR_REALCLK=1): de-risk that the
    // FULL DDR3-667 clock tree (MMCM ZHOLD -> ck333 / controller83 /
    // idelayref200 / ck90, each on its own BUFG, the buildXilinxDdr3ClockTree
    // arrangement) can drive an ISERDESE2 DATA_WIDTH=8 + IDELAYCTRL such that
    // (a) they ROUTE together and (b) IDELAYCTRL CALIBRATES (RDY=1) at these
    // real clocks. When set, the DDR3 tree REPLACES the phy_mmcm as the source
    // of clk90 + the ~200 MHz IDELAYCTRL reference, so the design keeps a SINGLE
    // IDELAYCTRL (nextpnr-xilinx rejects >1 IDELAYCTRL in the default
    // IODELAY_GROUP) fed by the real 200 MHz reference, and the probe adds only
    // the ISERDESE2 DW8 (CLK=ck333, CLKDIV=controller83 on a SEPARATE BUFG: the
    // routing key) plus its DDLY IDELAYE2. ck333 and controller83 are surfaced
    // for the probe below. The divides come from solveDdr3ClockTree (the same
    // solver buildXilinxDdr3ClockTree uses), so the emitted MMCM/BUFG topology
    // matches the helper. This PHY is a plain Module (not a BridgeModule), so it
    // wires the tree inline rather than calling the helper directly.
    // ISERDESE2-based read capture is UNROUTEABLE on openXC7/xc7s50 (no BUFR
    // bels, no BUFG->ILOGIC-clock arc), which is why the production read path
    // is IDDR.
    final Logic clk90;
    final Logic idelayRefclk;
    final double idelayRefMhz;
    if (ddr3Fast) {
      // The DDR3 clock tree is supplied by the caller (genip). [clk] is the
      // ctrl83 controller/CLKDIV clock. The ISERDESE2 CLK is ck333 and the read
      // datapath below uses [clk] as CLKDIV. The write launch rides ck333@90 and
      // the single IDELAYCTRL is fed by the ~200 MHz reference.
      clk90 = ck90FastIn!;
      idelayRefclk = idelayRefIn!;
      idelayRefMhz = idelayRefFastMhz;
    } else if (mmcmPhaseClock) {
      final vcoMult = (600 / clkMhz).round().clamp(2, 64).toDouble();
      // CLKOUT1 divides the VCO down to ~200 MHz for the IDELAYCTRL reference.
      // VCO = vcoMult * clkMhz. Divide by 3 lands 624 MHz -> 208 MHz for the
      // 48 MHz build, inside IDELAYCTRL's 190-210 MHz tolerance.
      const idelayRefDivide = 3;
      final mmcm = XilinxMmcme2Adv(
        clkfboutMult: vcoMult,
        clkout0Divide: vcoMult,
        divclkDivide: 1,
        clkinPeriod: 1000.0 / clkMhz,
        clkout0Phase: 90.0,
        clkout1Divide: idelayRefDivide,
        name: 'phy_mmcm',
      );
      mmcm.input('CLKIN1').srcConnection! <= clk;
      mmcm.input('CLKIN2').srcConnection! <= Const(0);
      mmcm.input('CLKINSEL').srcConnection! <= Const(1);
      final phyFbBufg = XilinxBufg(name: 'phy_mmcm_fbbufg');
      phyFbBufg.input('I').srcConnection! <= mmcm.output('CLKFBOUT');
      mmcm.input('CLKFBIN').srcConnection! <= phyFbBufg.output('O');
      mmcm.input('RST').srcConnection! <= reset;
      mmcm.input('PWRDWN').srcConnection! <= Const(0);
      final clk90Bufg = XilinxBufg(name: 'phy_clk90_bufg');
      clk90Bufg.input('I').srcConnection! <= mmcm.output('CLKOUT0');
      clk90 = clk90Bufg.output('O');
      // ~208 MHz IDELAYCTRL reference off CLKOUT1, buffered onto a global net.
      final idelayRefBufg = XilinxBufg(name: 'phy_idelayref_bufg');
      idelayRefBufg.input('I').srcConnection! <= mmcm.output('CLKOUT1');
      idelayRefclk = idelayRefBufg.output('O');
      idelayRefMhz = vcoMult * clkMhz / idelayRefDivide;
    } else {
      clk90 = clk;
      idelayRefclk = clk;
      idelayRefMhz = clkMhz.toDouble();
    }

    // CK/CK#: free-running DDR CK via DDR outputs. Explicit pseudo-differential
    // pair (CK# is the inverse phase). In ddr3Fast the CK toggles at the ck333
    // DDR rate (the ODDR launches at 333 MHz so the pin runs at 333 MHz),
    // otherwise it mirrors clk (the DLL-off CK == system clock path).
    //
    // ORACLE-MATCHED PHASE (routing-friendly variant): CK, command/address AND
    // DQS all launch on ck0 (== the proven-packable ck0 leaf), so DQS is
    // edge-aligned to CK (JEDEC tDQSS) and command keeps its proven 0-deg-from-CK
    // relationship. The DQ+DM eye centering (DQS 90 deg into the DQ bit) is done
    // instead by launching DQ+DM on ck90 with an ODD wrBeatOffset: an odd beat
    // rotation re-pairs the DDR rise/fall sub-phases and shifts the effective DQ
    // launch by 180 deg, so ck90 (naively DQ lagging DQS by 90) becomes an
    // effective 270-deg launch = DQ LEADS DQS by 90 = DQS edge centered in the DQ
    // eye. This lands the same relationship as the UberDDR3 oracle (CK==DQS, DQ
    // leads 90) using only ck0/ck90 and the existing HARBOR_DDR_WRBEAT knob, no
    // ck270 clock, no leaf overload (command stays on ck0, not the ck90 leaf that
    // overflowed to uncharacterized IMUX31 pips), no segbits patching.
    final ckLaunch = ddr3Fast ? ckFastIn! : clk;
    if (ddr3Fast) {
      // True differential CK via OBUFDS. ONE ODDR toggles at the CK rate and the
      // OBUFDS makes the complement AT THE PAD: the master OBUF (IOB33M) drives
      // pin_ck and the slave OBUF plus IOB output inverter (IOB33S) drives
      // pin_ck_n. A matched master/slave P/N pair keeps the CK/CK# crossing
      // clean, so the DRAM on-die DLL holds lock at the rated CK speed. The old
      // two independent single-ended ODDRs skewed the crossing (separate
      // insertion delays), which drifted the DLL and made reads unstable.
      final ckOddr = XilinxOddr(
        c: ckLaunch,
        d1: Const(1),
        d2: Const(0),
        r: reset,
        name: 'ck_oddr',
      );
      final ckDiff = XilinxObufds(i: ckOddr.q, name: 'ck_obufds');
      ckOut <= ckDiff.o;
      ckNOut <= ckDiff.ob;
    } else {
      // DLL-off path: single-ended pseudo-differential pair (CK# is the inverse
      // phase). Low speed, so a matched diff pad is not needed.
      ckOut <=
          XilinxOddr(
            c: ckLaunch,
            d1: Const(1),
            d2: Const(0),
            r: reset,
            name: 'ck_oddr',
          ).q;
      ckNOut <=
          XilinxOddr(
            c: ckLaunch,
            d1: Const(0),
            d2: Const(1),
            r: reset,
            name: 'ck_n_oddr',
          ).q;
    }

    // Command/address: 1T SDR registers.
    //
    // ddr3Fast CK-ALIGNED COMMAND/ADDRESS PATH (the UberDDR3 recipe). On the
    // 48 MHz path every command pin is a 1T register on `clk` (== CK there), so a
    // command occupies exactly one CK. On ddr3Fast `clk` is ctrl83 = CK/4, so a
    // 1T-held command spans FOUR CK rising edges. The old "SERDES only cs_n, hold
    // everything else" minimization was WRONG: it left ras_n/cas_n/we_n/addr/ba/
    // cke/odt/reset_n on the ctrl83 register net while cs_n rode an OSERDESE2, so
    // those pins reached the pad LATENCY-SKEWED vs cs_n (different insertion delay
    // through the fabric-register vs the OLOGIC-serializer path). At DDR3-667 that
    // skew is a whole bit period, so the DRAM decoded a MIS-COMMANDED bus -> stored
    // nothing -> every read = the constant 0x73145241 (a faithful capture of an
    // idle terminated bus, the read datapath was fasm-byte-identical to the oracle).
    //
    // THE FIX (this is the named root cause): serialize ALL command/control AND
    // address pins through matched SDR-W4 (4:1) OSERDES exactly like the oracle's
    // OSERDESE2_cmd (ddr3_phy.v, DATA_RATE_OQ("SDR"), DATA_WIDTH(4), CLK=ck333,
    // CLKDIV=ctrl83, D1..D4 = the 4 CK-slot values). Every pin then shares the same
    // OLOGIC->pad insertion delay and CK alignment. The 4 per-CK-slot vectors are
    // built in the write block below (where the proven-routing BUFH ck333/ctrl83
    // clocks live). Here we only REGISTER each command value into a stable ctrl83-
    // domain latch (*Reg) the slot-vector builder fans out, the *Out pins are then
    // driven by the SDR-W4 OSERDES, not by this register.
    //
    // Command pins (cs_n/ras_n/cas_n/we_n/cke/odt): the real value on CK-slot
    // [cmdSlot] and a NOP (cs_n high, ras=cas=we high, cke/odt held) on the other
    // 3 slots, so the DRAM decodes the command exactly once. Address/ba/reset_n:
    // the same value on all 4 slots (held, but now latency-matched to cs_n through
    // an identical OSERDES). The registered latches:
    final csNReg = ddr3Fast ? Logic(name: 'cs_n_reg') : null;
    final rasNReg = ddr3Fast ? Logic(name: 'ras_n_reg') : null;
    final casNReg = ddr3Fast ? Logic(name: 'cas_n_reg') : null;
    final weNReg = ddr3Fast ? Logic(name: 'we_n_reg') : null;
    final ckeReg = ddr3Fast ? Logic(name: 'cke_reg') : null;
    final odtReg = ddr3Fast ? Logic(name: 'odt_reg') : null;
    final baReg = ddr3Fast ? Logic(name: 'ba_reg', width: baBits) : null;
    final addrReg = ddr3Fast ? Logic(name: 'addr_reg', width: rowBits) : null;
    final resetNReg = ddr3Fast ? Logic(name: 'reset_n_reg') : null;
    Sequential(
      clk,
      reset: reset,
      resetValues: {
        if (!ddr3Fast) csNOut: Const(1) else csNReg!: Const(1),
        if (ddr3Fast) rasNReg!: Const(1),
        if (ddr3Fast) casNReg!: Const(1),
        if (ddr3Fast) weNReg!: Const(1),
        if (ddr3Fast) ckeReg!: Const(0),
        if (ddr3Fast) odtReg!: Const(0),
        if (ddr3Fast) baReg!: Const(0, width: baBits),
        if (ddr3Fast) addrReg!: Const(0, width: rowBits),
        if (ddr3Fast) resetNReg!: Const(0),
        if (!ddr3Fast) resetNOut: Const(0),
      },
      ddr3Fast
          ? [
              ckeReg! < cke,
              csNReg! < csN,
              rasNReg! < cmd[2],
              casNReg! < cmd[1],
              weNReg! < cmd[0],
              baReg! < ba,
              addrReg! < addr,
              odtReg! < odt,
              resetNReg! < resetN,
            ]
          : [
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

    // Write engine: wrStart pulses at the WRITE command, the DQ/DQS/OE launch
    // window opens [writeLaunch] cycles later for 4 CKs of BL8, only the
    // addressed word's two beats carrying data. The launch cycle is the write
    // twin of the read-window landing: the DRAM captures the burst at a
    // CWL-derived offset that the untuned base (cwl-1-oddrLatency) misses, so
    // [writeShift] slides the whole launch window (the Xilinx twin of the ECP5
    // OPTION-A wrShift). Threaded from the region params / board default.
    const oddrLatency = 1;
    const wrPipeLen = 16;
    // WRITE-LAUNCH CWL OFFSET (the crux: FIXED 2026-07-09). The WRITE command
    // reaches the pad on CK slot [cmdSlot] of the issuing tick. The DRAM expects
    // the first DQ/DQS beat CWL CKs LATER. On ddr3Fast one tick = ckCyclesPerTick
    // (=4) CK and the whole BL8 launches in ONE tick (the OSERDESE2 serializes 8
    // beats = 4 CK aligned to the CLKDIV/tick edge), so a CK-quoted CWL splits:
    //   whole-tick part  = ceil(CWL / ckCyclesPerTick) -> the wrPipe launch index
    //   residual CK part = the sub-tick beat rotation of the data/DM/DQS pattern
    //                      (wrBeatOffset below), since a tick-granular launch can
    //                      only place beat0 on a CK-slot boundary.
    //
    // ROOT-CAUSE (rtl-reviewer + the DQS-phase-invariance HW proof): the OLD base
    // `(cwl ~/ ckCyclesPerTick) - oddrLatency` = (5//4) - 1 = 0 CANCELLED CWL to
    // zero, so the data/DQS burst launched on the SAME tick as the WRITE command
    // instead of CWL CK later. The burst then landed OUTSIDE the DRAM's post-WRITE
    // data-capture window, so it captured NOTHING, and, decisively, NO DQS sub-CK
    // phase could rescue it (the whole burst-vs-command relationship was wrong),
    // which is exactly why the full 90..270 DQS phase sweep read A==B invariantly.
    // The oracle delays the data/DQS by STAGE2_DATA_DEPTH = ceil((CWL - k)/4) + 1
    // controller cycles PAST the command, ceil(CWL/ckCyclesPerTick) is the same
    // whole-tick delay (=2 for CWL=5), which is what the launch must carry. The
    // command has its own ~2-cycle serialize latency, the data pipe is made this
    // many cycles LONGER so the net offset on the pads is ~CWL. HARBOR_DDR_WRSHIFT
    // sweeps around this CORRECT base for the residual tree-insertion delay.
    //
    // On the 48 MHz path (ckCyclesPerTick=1) the formula is unchanged
    // (cwl-1-oddrLatency), so the 48 MHz launch stays byte-identical.
    final writeLaunch =
        (ckCyclesPerTick > 1
                ? ((cwl + ckCyclesPerTick - 1) ~/ ckCyclesPerTick) + writeShift
                : cwl - 1 - oddrLatency + writeShift)
            .clamp(0, wrPipeLen - 1);
    // Sub-tick residual as a DDR beat rotation (0 on the 48 MHz path).
    //
    // DQ+DM launch on ck90 (not ck0) so the effective launch is a quarter cycle
    // off the DQS/CK (on ck0). A DDR OSERDES emits rise-beat on the launch-clock
    // rising edge and fall-beat on the falling edge, so an ODD beat rotation
    // re-pairs every rise-beat with the opposite launch sub-phase = shifts the
    // effective DQ launch by 180 deg: ck90 (naive DQ lags DQS by 90) + odd offset
    // -> effective 270 deg -> DQ LEADS DQS by 90 -> DQS edge centered in the DQ
    // eye. So the CWL-derived even residual ((cwl%tick)*2) is bumped by +1 to make
    // it ODD, the extra one-beat whole-burst slip is absorbed by writeLaunch. The
    // PARITY sets the sub-bit DQ-vs-DQS phase (odd = centered), the VALUE sets the
    // whole-bit burst alignment. Sweep [wrBeatOffset] over ODD values
    // (1,3,5,7) to land the burst. If only an even value reads (shifted-by-one-bit)
    // data, the DQ launch-clock lead sign is inverted from this model and DQ should
    // move to the ck0 family instead. The ctor param overrides, null derives it.
    final wrBeatOffsetEff = ckCyclesPerTick > 1
        ? (wrBeatOffset ?? (((cwl % ckCyclesPerTick) * 2) | 1))
        : 0;
    final wrPipe = Logic(name: 'wr_pipe', width: wrPipeLen);
    final wrBeats = Logic(name: 'wr_beats', width: 3);
    final wrActive = Logic(name: 'wr_active');
    final wrWord = Logic(name: 'wr_word', width: 32);
    final wrSel = Logic(name: 'wr_sel', width: 4);
    final wrBeat = Logic(name: 'wr_beat', width: 2);
    Sequential(clk, reset: reset, [
      wrPipe < [wrPipe.getRange(0, wrPipeLen - 1), wrStart].swizzle(),
      If(wrStart, then: [wrWord < wrData, wrSel < wrMask, wrBeat < beatSel]),
      If(wrPipe[writeLaunch], then: [wrActive < 1, wrBeats < 0]),
      If(
        wrActive,
        then: [
          wrBeats < wrBeats + 1,
          If(wrBeats.eq(Const(3, width: 3)), then: [wrActive < 0]),
        ],
      ),
    ]);

    final beatNow = wrBeats.getRange(0, 2);
    final beatHit = wrActive & beatNow.eq(wrBeat);

    final dqRise = wrWord.getRange(0, dataBits);
    final dqFall = wrWord.getRange(dataBits, 32);

    // DEBUG: the LATCHED write word the PHY actually launches (rise half, low
    // 16b). Bus-synced upstream and exposed via STATUS reg4 so firmware can read
    // whether the real bus write data (e.g. HAMMER 0x..AA55, or 0x5678) reaches
    // the PHY: the decisive write-data-path test (fixed value => data lost in
    // the bus->sequencer->PHY path, real value => the launch/DQS/DRAM-capture is
    // the fault). dataBits==16 on the Arty x16 part.
    addOutput('dbg_wrword', width: 16);
    output('dbg_wrword') <= wrWord.getRange(0, 16);

    // In ddr3Fast the write OSERDESE2s own the DQ pad IOBUFs, the read datapath
    // sources DQ from those IOBUF O outputs (this net), NOT the dq_in port.
    Logic? ddr3FastDqReadIn;
    // Read-DQS pad IOBUF .O outputs (one per DQS lane), captured for the read
    // window gate. Assigned in the DQS write loop, read in the dqsGatedRead block.
    List<Logic>? dqsReadIn;
    // The 4-bit runtime window selector (reg12/windowSel). Set in the windowOpen
    // definition; the dqsGatedRead block reuses its low bits as the tunable
    // strobe->window offset the FSBL read-setup sweeps.
    Logic? windowIdxSig;
    // The single shared BUFH ck333 (built in the write block) that BOTH the
    // write OSERDESE2 CLK and the read ISERDESE2 CLK ride.
    Logic? ddr3FastSharedCk;
    // The BUFH'd ctrl83 (CK/4) that clocks the OSERDESE2/ISERDESE2 parallel-load
    // (CLKDIV). Built once in the write block on a distinct BUFG from ck333 (so
    // the BUFG->BUFH arc routes) and lands on the I/O clock LEAF, so BOTH the
    // write serialize AND the read deserialize load their 8-beat word on it. The
    // read MUST share it: a DATA_WIDTH=8 ISERDESE2 with CLKDIV unconnected never
    // clocks its parallel register, so Q1..Q8 freeze and every read returns a
    // fixed constant regardless of stored data / IDELAY tap / capture window.
    Logic? ddr3FastCkDiv;
    // DQ-drive-overlap diagnostic counter (ddr3Fast): counts write bursts where
    // the pad OE window overlaps the data-serialize cycle. Surfaced via the
    // dbg output so STATUS can read it (0 = pad muzzled during the burst).
    Logic? ddr3FastDriveOverlap;

    // OE staging: cover the pad-time burst plus a preamble ahead and postamble
    // slack behind so the DQS tail is not chopped to high-Z. Shared by both the
    // 48 MHz fabric-tristate path and the ddr3Fast in-site-tristate path (the
    // latter feeds the OSERDESE2 T1, active-HIGH = high-Z, so it inverts this).
    final wrActiveD1 = Logic(name: 'wr_active_d1');
    final wrActiveD2 = Logic(name: 'wr_active_d2');
    final wrActiveD3 = Logic(name: 'wr_active_d3');
    final wrActiveD4 = Logic(name: 'wr_active_d4');
    Sequential(clk, reset: reset, [
      wrActiveD1 < wrActive,
      wrActiveD2 < wrActiveD1,
      wrActiveD3 < wrActiveD2,
      wrActiveD4 < wrActiveD3,
    ]);
    final oeActive = (wrActiveD2 | wrActiveD3 | wrActiveD4).named('oe_active');

    // ddr3Fast SINGLE-CYCLE burst strobe: at ckCyclesPerTick=4 the OSERDESE2
    // serializes the WHOLE BL8 (8 beats = 4 CK) in ONE ctrl100 CLKDIV cycle: the
    // cycle dataLineReg presents (= the cycle after wrPipe[writeLaunch], same edge
    // dataLineReg latches). The old DQS gate used the 4-cycle-wide [wrActive]
    // (correct for the 48 MHz fabric-ODDR multi-CK burst) which made DQS toggle
    // for 16 CK across 4 cycles while the DQ data spans only ONE cycle, no
    // defined preamble/edge vs the single burst, so the DRAM never framed the
    // write (HW: clean read, A==B, writes never land). wrBurst is high for exactly
    // the ONE serialize cycle so DQS frames the burst. wrBurstPre is the cycle
    // BEFORE it (the DQS write preamble). Only built/used on ddr3Fast.
    final wrBurst = Logic(name: 'wr_burst');
    final wrBurstPost = Logic(name: 'wr_burst_post');
    // DQS-only whole-tick launch offset (tDQSS walk). The full WRSHIFT/WRBEAT/CWL
    // grid landed NO write (A==B across every point): the whole-burst launch and
    // the sub-tick DQ-vs-DQS beat parity slide DQ and DQS TOGETHER, so the
    // DQS-vs-CK relationship the DRAM frames its write off (tDQSS: first DQS
    // rising edge within +/-0.25 tCK of a CK rising edge) never moves. This gate
    // shifts DQS's launch cycle INDEPENDENTLY of DQ by [dqsShift] whole ctrl100
    // ticks (each = ckCyclesPerTick CK), so the DQS strobe train walks relative
    // to CK/DQ in 4-CK steps: the coarse tDQSS knob. Positive = DQS later,
    // negative = earlier. 0 = DQS on the same wrBurst cycle as DQ, the launch
    // that lands writes on this part.
    final dqsShift = 0;
    // The DQS burst gate = wrPipe tapped [dqsShift] ticks off the DQ launch, then
    // registered the SAME +1 as wrBurst so it lands on the serialize cycle.
    final dqsLaunchIdx = (writeLaunch + dqsShift).clamp(0, wrPipeLen - 1);
    final wrBurstDqs = Logic(name: 'wr_burst_dqs');
    if (ddr3Fast) {
      // wrPipe[writeLaunch] is high on cycle N (dataLineReg latches this edge,
      // valid N+1). Register it: wrBurst high on N+1 (== the serialize cycle),
      // wrBurstPost high on N+2 (the postamble cycle just after the burst).
      Sequential(clk, reset: reset, [
        wrBurst < wrPipe[writeLaunch],
        wrBurstPost < wrBurst,
        // DQS gate: tapped at the DQS-shifted launch index (walks tDQSS).
        wrBurstDqs < wrPipe[dqsLaunchIdx],
      ]);
    } else {
      wrBurst <= Const(0);
      wrBurstPost <= Const(0);
      wrBurstDqs <= Const(0);
    }

    if (ddr3Fast) {
      // Per DQ bit: one OSERDESE2 (DATA_RATE_OQ=DDR, DATA_RATE_TQ=BUF,
      // DATA_WIDTH=8) serializes the 8-beat line onto OQ and produces the in-site
      // tristate on TQ (BUF pass-through of T1). OQ -> pad IOBUF I, TQ -> pad
      // IOBUF T, so data + tristate stay in the OLOGIC (ODDR_TDDR.IN_USE) and the
      // D1 pin never contends with a GND tie: the UberDDR3 oracle recipe and the
      // fix for the ddr3Fast route stall at overused=32.
      //
      // The whole BL8 launches in ONE ctrl83 (CLKDIV) cycle on the ck333@90
      // launch clock (clk90). The write gearbox spreads the single addressed word
      // into the 8 data beats + the 8 DM beats.
      final gearbox = DdrBl8WriteGearbox(
        wrWord: wrWord,
        wrSel: wrSel,
        wrBeat: wrBeat,
        dataBits: dataBits,
        name: 'wr_gearbox',
      );
      // Apply the sub-tick CWL residual as a beat rotation: shift the addressed
      // word's data/DM beats LATER by [wrBeatOffset] beats so the burst reaches
      // the pad CWL%ckCyclesPerTick CK into the launch tick (the whole-tick part
      // is [writeLaunch]). Only <=2 beats carry data and the rest are 0/masked,
      // so a left shift (beat b <- beat b-offset, zero/mask-fill the freed low
      // beats) is exact, a wrap is unnecessary. dmShiftFill = 1 (masked) keeps
      // the freed low beats from writing. On the 48 MHz path wrBeatOffset=0 so
      // both lines pass through unchanged (byte-identical).
      final dmLanes0 = dataBits ~/ 8;
      Logic shiftDataLine(Logic line) => wrBeatOffsetEff == 0
          ? line
          : [
              line.getRange(0, dataBits * (8 - wrBeatOffsetEff)),
              Const(0, width: dataBits * wrBeatOffsetEff),
            ].swizzle();
      Logic shiftDmLine(Logic line) => wrBeatOffsetEff == 0
          ? line
          : [
              line.getRange(0, dmLanes0 * (8 - wrBeatOffsetEff)),
              Const(-1, width: dmLanes0 * wrBeatOffsetEff), // masked (DM=1)
            ].swizzle();
      final gbData = shiftDataLine(gearbox.dataLine);
      final gbDm = shiftDmLine(gearbox.dmLine);
      // Register the 8-beat data + DM lines on the launch pulse so they present
      // for the whole CLKDIV cycle the OSERDESE2 serializes (the write mirror of
      // the read-window capture). wrPipe[writeLaunch] is that launch cycle.
      final dataLineReg = Logic(name: 'wr_data_line', width: dataBits * 8);
      final dmLineReg = Logic(name: 'wr_dm_line', width: (dataBits ~/ 8) * 8);
      // DM defaults to all-masked (DM=1 = ignore) so idle beats never write.
      Sequential(clk, reset: reset, [
        If(
          wrPipe[writeLaunch],
          then: [dataLineReg < gbData, dmLineReg < gbDm],
          orElse: [dmLineReg < Const(-1, width: (dataBits ~/ 8) * 8)],
        ),
      ]);
      // DEBUG: the LAUNCHED write line beats 0+1 (post-gearbox, the OSERDESE2 D
      // inputs). For a beatSel=0 write these are the written word {fall,rise}, so
      // firmware can compare this to wrWord (reg4), if it tracks the pattern the
      // gearbox/launch is intact and the fault is DQS/DRAM-capture. If it is stuck
      // the gearbox is the bug. Exposed via STATUS reg5.
      // Beats 3+4: wrBeatOffset (=3 at cwl5) shifts the beatSel=0 write word up to
      // beats 3,4 (beats 0-2 are shifted-in zeros), so THIS is where the launched
      // word lives. If it tracks wrWord the gearbox/launch is intact.
      addOutput('dbg_dataline', width: 32);
      // Beats 3,4 (where a beatSel=0 x16 write word lands) = getRange(48,80). For
      // a narrow lane (x8: dataLineReg is 64 wide) that overruns, so fall back to
      // the low 32 bits. This is a debug probe, the exact beats don't matter.
      final dlLo = dataLineReg.width >= 80 ? 3 * 16 : 0;
      output('dbg_dataline') <= dataLineReg.getRange(dlLo, dlLo + 32);
      // T1 (tristate control): active-HIGH = high-Z. Drive low (output) over the
      // OE window, high (high-Z) otherwise. One T1 net feeds all DQ + DQS
      // OSERDESE2s so the in-site tristate tracks the burst.
      //
      // CRITICAL ddr3Fast timing: the whole BL8 launches in ONE CLKDIV cycle.
      // dataLineReg latches on wrPipe[writeLaunch] (call it cycle N) so it is
      // valid on N+1, and the OSERDESE2 serializes D1..D8 during N+1 (OQ presents
      // D1 on the CLKDIV reload edge). wrActive also asserts on N+1 (from
      // wrPipe[writeLaunch]). The shared [oeActive] = wrActiveD2|D3|D4 opens the
      // pad only on N+3..N+5, TWO cycles AFTER the data has already serialized,
      // so the DQ pad is HIGH-Z for the entire burst and the DRAM captures
      // nothing (every read then returns a constant idle-bus pattern). That OE
      // window was tuned for the 48 MHz fabric-ODDR path (multi-CK burst, OE must
      // lead), NOT the single-CLKDIV OSERDESE2 launch.
      //
      // CRITICAL (the A==B / all-zeros-read bug): the ddr3Fast READ DQ is sourced
      // from THIS write IOBUF's .O output (ddr3FastDqReadIn -> the read IDELAY
      // idatain), so whenever the write OE holds the pad DRIVEN (T low) the read
      // ISERDESE2 samples the FPGA's OWN driven value, not the DRAM. The old
      // window `wrPipe[writeLaunch] | wrActive | wrActiveD1` = wrActive is FOUR
      // ctrl100 cycles wide, so the FPGA drove the shared DQ pad for ~6 cycles
      // around every write: (a) the one-cycle data burst was SMEARED into a long
      // driven run (DRAM never captured a clean burst), (b) with a non-zero
      // writeLaunch the wide OE slid into the read capture cycle and every read
      // came back 0x00000000 (HW-confirmed: WRSHIFT=1 read all-zeros incl. an
      // UNWRITTEN address). Narrow the OE to EXACTLY the single-cycle serialize
      // plus one preamble (N) and one postamble (N+2) so the pad is driven for 3
      // ctrl100 cycles centered on the burst and HIGH-Z everywhere else (reads see
      // the DRAM). wrBurst is high on N+1 (the serialize cycle), wrBurstPost on
      // N+2. The base 48 MHz [oeActive] is left untouched.
      // Cover the DQ burst (wrBurst/post) AND the DQS burst (wrBurstDqs, which
      // may be shifted by dqsShift) plus one preamble cycle each, so the pad is
      // driven for the whole strobe train regardless of the tDQSS walk. When
      // dqsShift==0 wrBurstDqs==wrBurst so this reduces to the old 3-cycle window.
      // wrPipe[dqsLaunchIdx] (undelayed) = the DQS preamble cycle (one before the
      // registered wrBurstDqs burst cycle). wrBurstDqsPost = one cycle after.
      final wrBurstDqsPost = Logic(name: 'wr_burst_dqs_post');
      Sequential(clk, reset: reset, [wrBurstDqsPost < wrBurstDqs]);
      final oeFast =
          (wrPipe[writeLaunch] |
                  wrBurst |
                  wrBurstPost |
                  wrPipe[dqsLaunchIdx] |
                  wrBurstDqs |
                  wrBurstDqsPost)
              .named('oe_fast');
      final dqT1 = (~oeFast).named('dq_t1');

      // UART-observable confirmation instrument (no LA): count write bursts where
      // the pad OE window actually OVERLAPS the data-serialize cycle (wrBurst).
      // With a muzzled window this stays 0, once OE covers the burst it climbs one
      // per write. Surfaced through STATUS via [ddr3FastDriveOverlap].
      final driveOverlap = (wrBurst & oeFast).named('drive_overlap');
      final overlapCount = Logic(name: 'wr_overlap_count', width: 8);
      Sequential(clk, reset: reset, [
        If(
          driveOverlap & ~overlapCount.eq(Const(0xFF, width: 8)),
          then: [overlapCount < overlapCount + 1],
        ),
      ]);
      ddr3FastDriveOverlap = overlapCount;

      // WRITE-TIMING LA OBSERVABILITY (ddr3Fast). The DQS-vs-DQ write alignment
      // that decides whether the DRAM latches a write is set by these ctrl100
      // markers: the DQ serialize cycle (wrBurst) must be strobed by the DQS
      // burst (wrBurstDqs) with the pad driven (oeFast). Fan them to the LA (via
      // genip's dbg_la) so a scope-free capture shows whether the DQS launch fires
      // and lines up with the DQ burst: a ctrl100-level mis-alignment (the whole
      // reason writes miss) is directly visible here.
      addOutput('dbg_wr', width: 8);
      output('dbg_wr') <=
          [
            wrPipe[writeLaunch], // [7] launch pulse (cycle N)
            wrBurst, // [6] DQ serialize cycle (N+1)
            wrBurstPost, // [5] DQ postamble (N+2)
            wrPipe[dqsLaunchIdx], // [4] DQS preamble
            wrBurstDqs, // [3] DQS burst cycle
            wrBurstDqsPost, // [2] DQS postamble
            oeFast, // [1] pad OE window (T low = driven)
            wrActive, // [0] write-active (4-cycle envelope)
          ].swizzle();

      // ALL DDR clocks ride PLAIN GLOBAL BUFGs, ZERO regional BUFH/BUFHCE,
      // EXACTLY matching the HW-verified UberDDR3 oracle (clk_wiz.v = 4 plain
      // BUFGs: CK/CLKDIV/idelayref/ck90, ddr3_phy.v drives the read ISERDESE2
      // .CLK straight off the CK BUFG net i_ddr3_clk, NOT a separate buffer).
      //
      // WHY (the R2 400MHz exact-oracle blocker): a regional BUFHCE on the read
      // CLK made nextpnr-xilinx 0.8.2's clock packer bind it to the WRONG clock
      // region (top X0Y12) not the DDR region, so BUFGCTRL_X0Y5->BUFHCE_X0Y12
      // failed to route on every seed. The oracle has NO regional buffer to
      // mis-bind: all four clocks are global BUFGs on the global CLK_BUFG_REBUF
      // spine, which reaches any region's HCLK leaf. Removing the deviation
      // removes the region-bind failure.
      //
      // The CK BUFG net feeds BOTH the write OSERDESE2 CLK and (shared, no
      // separate buffer) the read ISERDESE2 CLK: identical to the oracle's
      // single i_ddr3_clk driving both. CLKDIV is the controller/CLKDIV BUFG
      // ([clk] = ctrl100 = CK/4 = i_controller_clk). ck90 (DQ/DM launch) is its
      // own BUFG. (The prior IMUX31 spill worry that motivated the BUFHs is a
      // non-issue for the oracle's all-BUFG arrangement on this exact part. The
      // OCLKM IMUX31 segbits are also safe-vendored in the build-env DB.)
      // ckFastIn is ALREADY a global BUFG output (the tree's ddr_ck_fast BUFG).
      // Wrapping it in ANOTHER BUFG here is an illegal cascaded BUFG->BUFG that
      // openXC7's lenient router accepts but that is physically dead: it kills
      // the ENTIRE clock network (every clock, raw input included, measured dead
      // on HW). The HW-verified UberDDR3 oracle buffers ONCE in clk_wiz then
      // feeds the SERDES CLK/CLKDIV pins DIRECTLY. Do the same: use the already
      // buffered input clock straight, no second BUFG.
      final sharedFastCk = ckFastIn!;
      ddr3FastSharedCk = sharedFastCk;
      final writeCk = sharedFastCk;
      // CLKDIV for the DATA_WIDTH=8 DDR gearbox is CLK/4 = the controller clock
      // (ctrl100 = [clk] = i_controller_clk). (ck90 is the same RATE as CK, not
      // /4, so it is the WRONG CLKDIV for the 8:1 serialize.) On its own plain
      // BUFG, exactly as the oracle feeds i_controller_clk to every OSERDES/
      // ISERDES CLKDIV.
      // [clk] is already the controller's global BUFG net (tree ddr_clk / CLKDIV),
      // feed it straight. A second BUFG here is the same illegal cascade.
      final writeCkDiv = clk;
      // ORACLE-MATCHED WRITE PHASING (UberDDR3 ddr3_phy.v, ODELAY_SUPPORTED=0 /
      // Arty S7 HR bank). Two hard rules the JEDEC DDR3 write requires:
      //   (1) DQS must be EDGE-ALIGNED to CK (tDQSS: the first rising DQS edge
      //       aligns to a CK rising edge within +/-0.25 tCK). The DRAM frames the
      //       write burst off CK, so DQS off-by-90 sits at the very edge of tDQSS
      //       and (with insertion delay) falls out of spec -> nothing latches.
      //   (2) DQS edges must fall in the CENTER of each DQ bit (a 90-degree DQ/DQS
      //       offset), so the DRAM captures stable DQ, not the transition.
      // The oracle satisfies BOTH by launching CK and DQS on the SAME phase
      // (its !i_ddr3_clk) and DQ+DM a quarter cycle EARLIER (i_ddr3_clk_90 leads),
      // so CK==DQS (rule 1) and DQ leads DQS by 90 deg (rule 2).
      //
      // Our DQ/DQS relation was ALREADY correct: DQ launched on ck0 leads DQS on
      // ck90 by 90 deg, so DQS is already centered in the DQ eye. The ONLY defect
      // was that CK also rode ck0 (0 deg) while DQS rode ck90, leaving DQS 90 deg
      // OFF CK (tDQSS violated), which is what kept the DRAM from latching writes
      // (HW: writes issued + pad driven, reads still a constant). THE FIX: DQ+DM
      // launch on this ck90 clock while CK, command AND DQS all stay on ck0 (the
      // proven-packable leaf), and an ODD wrBeatOffset turns the ck90 DQ launch
      // into an effective 270-deg (DQ leads DQS by 90 = centered eye, DQS==CK for
      // tDQSS). See the ckLaunch comment above for the full phase rationale.
      //
      // BUFG (not BUFH) for this ck90 DQ/DM launch clock: the OSERDES CLK pin
      // reaches the OLOGIC clock LEAF (IOI_LEAF_GCLK) from the GLOBAL clock spine a
      // BUFG lands on, for ALL 18 DQ+DM OLOGIC sites. A BUFH lands only on ONE clock
      // region's regional (CLK_HROW) track, which nextpnr cannot arc to every one of
      // the 18 sites, so it spills the unreachable ones onto the fabric IOI_IMUX31
      // pip, and prjxray's spartan7 segbits DB does NOT characterize the OCLKM/SING/
      // TBYTETERM IMUX31 keys, so fasm2frames aborts. The spill was SEED-DEPENDENT
      // (one lucky seed packed, most did not). This is EXACTLY how the HW-verified
      // UberDDR3 drives its 16+ DQ/DM OSERDES CLK on this same xc7s50: a plain BUFG
      // off the ck90 PLLE2 CLKOUT, no BUFH, no XDC pragma (grep confirms zero BUFH in
      // its tree). ck90 has its own dedicated BUFGCTRL (ddr_ck90_fast) so the BUFG is
      // directly available. As of the all-BUFG exact-oracle arrangement, the read
      // ISERDESE2 CLK (sharedFastCk) + CLKDIV are ALSO on plain BUFGs (above):
      // the whole tree is now 4 global BUFGs, ZERO regional BUFH, matching the
      // oracle exactly (the read-CLK BUFG shares the CK net, no separate buffer).
      // ck90FastIn is already the tree's ddr_ck90 global BUFG, feed it straight,
      // no second BUFG (same illegal cascade otherwise).
      final writeCkData = ck90FastIn!;
      // Share this leaf-landed CLKDIV with the read ISERDESE2 deserializer.
      ddr3FastCkDiv = writeCkDiv;

      // DQS LAUNCH CLOCK (the never-varied sub-CK DQS-vs-CK phase). The HW-
      // verified UberDDR3 Arty HR-bank oracle (ddr3_phy.v, ODELAY_SUPPORTED=0)
      // launches the DQS OSERDES on !i_ddr3_clk (180-deg / inverted CK) while
      // DQ/DM ride ck90, so the DQS edge lands centered in the DQ eye AND the
      // strobe stays edge-framed to CK for tDQSS. Our prior code launched DQS on
      // ck0 (0-deg) and tried to fake the eye centering via an odd wrBeatOffset,
      // that never landed a write (A==B across the entire coarse sweep) because
      // CK and DQS both rode ck0, so the DQS-vs-CK phase was ALWAYS 0 and a
      // whole-tick shift only re-lands the same phase. The genip DDR3 tree now
      // supplies a dedicated CLKOUT4 at 180-deg (sweepable) as ckDqsFast, drive
      // the DQS OSERDES from it. Falls back to ck0 (writeCk) when the caller does
      // not wire ckDqsFast (old behaviour, byte-identical for that caller).
      final writeCkDqsBufg = ckDqsFastIn != null
          ? XilinxBufg(name: 'dqf_dqsck_bufg')
          : null;
      if (writeCkDqsBufg != null) {
        writeCkDqsBufg.input('I').srcConnection! <= ckDqsFastIn!;
      }
      final writeCkDqs = writeCkDqsBufg?.output('O') ?? writeCk;

      // DEBUG: heartbeat on writeCkDqs (the DQS launch clock). If this clock is
      // dead/unrouted the write DQS OSERDES never serializes a strobe and the DRAM
      // captures NO write (at any DQS phase): the exact symptom. Async-sampled
      // into STATUS reg6: nonzero/varying => writeCkDqs is ALIVE, constant 0 =>
      // dead (a DQS-clock routing bug, the fix).
      final dqsClkHb = Logic(name: 'dqsclk_hb', width: 8);
      Sequential(writeCkDqs, reset: reset, [dqsClkHb < dqsClkHb + 1]);
      addOutput('dbg_dqsclk', width: 8);
      output('dbg_dqsclk') <= dqsClkHb;

      // The oracle (UberDDR3 ddr3_phy.v OSERDESE2_cmd) serializes EVERY command,
      // control AND address pin through its own 4:1 SDR OSERDESE2
      // (DATA_RATE_OQ="SDR", DATA_WIDTH=4, CLK=ck333, CLKDIV=ctrl83, D1..D4 = the
      // 4 CK-slot values, OQ->pad). That is THE reason its DRAM responds and ours
      // did not: every pin reaches the pad through an IDENTICAL OLOGIC serializer,
      // so the whole command bus is CK-aligned and same-latency. Our old scheme
      // SERDES'd only cs_n (as a DATA_WIDTH=8 DDR level) and 1T-held the rest on
      // the ctrl83 register net, so ras/cas/we/addr/ba/cke/odt reached the pad
      // latency-skewed vs cs_n -> the DRAM was mis-commanded at DDR3-667 -> stored
      // nothing -> the constant-read symptom. Here we match the oracle exactly.
      //
      // Slot assembly:
      //  * Command pins (cs_n/ras_n/cas_n/we_n/cke/odt): the REAL value on CK slot
      //    [cmdSlot], a NOP (cs_n=1, ras=cas=we=1, cke/odt held to their idle
      //    level) on the other 3, so the command decodes exactly once (the DRAM
      //    only samples a command on the CK edge where cs_n is low).
      //  * Address/ba/reset_n: the SAME value on all 4 slots (held), but now
      //    routed through an OSERDES identical to cs_n's, so they are latency-
      //    matched and stable across the cs_n-low CK edge.
      // Launches on the ck0 BUFG (writeCk = sharedFastCk, the CK/DQS phase) + BUFG
      // ctrl100 (writeCkDiv = CLKDIV) built above, NO new clock buffers, and the
      // proven-PACKABLE leaf (the DQ+DM ck90 launch carries the eye-centering
      // instead, via the odd wrBeatOffset). An SDR-W4 serializer at
      // CLK=ck0/CLKDIV=ctrl83 has a 4:1 ratio, exactly one serialized bit per CK
      // rising edge, so slot s lands on CK edge s of each ctrl83 tick (unlike the
      // old DATA_WIDTH=8 DDR cs_n which spanned a level over two beats).
      //
      // cmdSlot is a bring-up knob (threaded from the region params / board
      // default): the ck333-vs-ctrl83 phase out of the MMCM tree decides which of
      // the 4 CK edges of a tick is "edge 0", so the correct slot is tunable.
      final cmdSlotClamped = cmdSlot.clamp(0, 3);
      // Build a matched SDR-W4 OSERDES for one command/address BIT. [onSlot] is
      // the value driven on CK slot [cmdSlot], [offSlot] is the value on the other
      // 3 slots (== onSlot for held address/ba pins, or the NOP level for command
      // pins). initOq sets the OQ reset level so the bus is idle out of reset.
      Logic cmdSerdesBit(
        Logic onSlot,
        Logic offSlot, {
        required String name,
        required String initOq,
      }) {
        final beats = [
          for (var s = 0; s < 4; s++) s == cmdSlotClamped ? onSlot : offSlot,
        ];
        return XilinxOserdese2(
          // Command/address launch on ck0 (writeCk): the SAME phase as CK and DQS
          // (all on ck0), so command keeps its proven 0-deg-from-CK relationship
          // (stable across the cs_n-low CK sampling edge) AND stays on the
          // proven-PACKABLE ck0 leaf. Moving the 24 command OSERDES onto the ck90
          // leaf overflowed it onto uncharacterized IMUX31 pips and killed
          // fasm2frames. The DQ eye centering is instead done via an odd
          // wrBeatOffset on the DQ+DM ck90 launch (see the CK comment above).
          clk: writeCk,
          clkdiv: writeCkDiv,
          d: beats,
          hasTristate: false,
          dataRateOq: 'SDR',
          dataWidth: 4,
          initOq: initOq,
          rst: reset,
          name: name,
        ).oq;
      }

      // cs_n / ras_n / cas_n / we_n: command value on cmdSlot, deselect (1) else.
      csNOut <=
          cmdSerdesBit(csNReg!, Const(1), name: 'csnf_oserdes', initOq: "1'b1");
      rasNOut <=
          cmdSerdesBit(
            rasNReg!,
            Const(1),
            name: 'rasnf_oserdes',
            initOq: "1'b1",
          );
      casNOut <=
          cmdSerdesBit(
            casNReg!,
            Const(1),
            name: 'casnf_oserdes',
            initOq: "1'b1",
          );
      weNOut <=
          cmdSerdesBit(weNReg!, Const(1), name: 'wenf_oserdes', initOq: "1'b1");
      // cke / odt: level signals, hold the registered level on all 4 slots (the
      // NOP for these is the CURRENT level, they must not toggle mid-tick), so
      // onSlot == offSlot. Still routed through the matched OSERDES for identical
      // pad latency.
      ckeOut <=
          cmdSerdesBit(ckeReg!, ckeReg, name: 'ckef_oserdes', initOq: "1'b0");
      odtOut <=
          cmdSerdesBit(odtReg!, odtReg, name: 'odtf_oserdes', initOq: "1'b0");
      // reset_n: single held level, all 4 slots.
      resetNOut <=
          cmdSerdesBit(
            resetNReg!,
            resetNReg,
            name: 'resetnf_oserdes',
            initOq: "1'b0",
          );
      // Address + bank: held value on all 4 slots (onSlot == offSlot), one matched
      // OSERDES per bit so the whole address bus is CK-aligned with cs_n.
      final baBitsOut = <Logic>[];
      for (var b = 0; b < baBits; b++) {
        final bit = baReg![b];
        baBitsOut.add(
          cmdSerdesBit(bit, bit, name: 'baf_oserdes_$b', initOq: "1'b0"),
        );
      }
      baOut <= baBitsOut.rswizzle();
      final addrBitsOut = <Logic>[];
      for (var a = 0; a < rowBits; a++) {
        final bit = addrReg![a];
        addrBitsOut.add(
          cmdSerdesBit(bit, bit, name: 'addrf_oserdes_$a', initOq: "1'b0"),
        );
      }
      addrOut <= addrBitsOut.rswizzle();

      // The WL actuator is a per-lane beat rotation of the DQS/DQ OSERDESE2 word
      // (0.5 CK per beat). Per byte lane a 3-bit [pos] tracks the rotation: during
      // WL ([wlEnIn]) the SELECTED lane follows the FSM rst/inc (wlDelayRst loads
      // 0, wlDelayInc steps one beat). After WL (rising edge of wlDone) it latches
      // the trained tap [wlTrainedIn] so normal writes rotate by the CK-aligned
      // beat. [wlPulse] is the single-ctrl83-cycle DQS strobe derived from the
      // held [wlStrobe] (mirrors the ECP5 wl_dqs_pulse), so each WL strobe emits
      // exactly one DQS rising edge (placed at beat [pos]). Built only when
      // writeLevel, off, the DQ/DQS beats keep the env [dqBeat1] rotation.
      final wlPos = <Logic>[];
      final Logic wlPulse;
      if (writeLevel) {
        for (var l = 0; l < laneCount; l++) {
          final pos = Logic(name: 'wl_pos_$l', width: 3);
          final wlDonePrev = Logic(name: 'wl_done_prev_$l');
          final applyDone = Logic(name: 'wl_apply_done_$l');
          final selected = wlLaneIn!.eq(Const(l, width: laneSelW));
          // Trained tap for this lane (4b field, only bits[2:0] are a valid beat).
          final trainedTap = wlTrainedIn!.getRange(l * 4, l * 4 + 3);
          // Firmware override tap for this lane (low 3 bits of its 4b field).
          final ovrTap = wlPosOvrIn!.getRange(l * 4, l * 4 + 3);
          Sequential(
            clk,
            reset: reset,
            resetValues: {
              pos: Const(0, width: 3),
              wlDonePrev: Const(0),
              applyDone: Const(0),
            },
            [
              wlDonePrev < wlDoneIn!,
              If(
                wlPosOvrEnIn!,
                // Firmware override wins: force this lane's write-beat rotation
                // to the swept tap (the runtime write-DQS re-center knob).
                then: [pos < ovrTap],
                orElse: [
                  If(
                    wlEnIn!,
                    then: [
                      // During WL: the selected lane follows the FSM rst/inc.
                      If(selected & wlRstIn!, then: [pos < 0]),
                      If(selected & wlIncIn!, then: [pos < pos + 1]),
                    ],
                    orElse: [
                      // After WL: latch the trained tap ONCE (rising edge of
                      // wlDone) so normal writes rotate by the CK-aligned beat.
                      If(
                        wlDoneIn & ~wlDonePrev & ~applyDone,
                        then: [pos < trainedTap, applyDone < 1],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
          wlPos.add(pos);
        }
        // Single-cycle DQS strobe = the rising edge of wl_strobe (held high for
        // the whole sub-step) in the ctrl83 domain (== the OSERDESE2 CLKDIV load
        // domain), so the WL DQS word is emitted for exactly one BL8 window.
        final wlStrobePrev = Logic(name: 'wl_strobe_prev');
        Sequential(clk, reset: reset, [wlStrobePrev < wlStrobeIn!]);
        wlPulse = (wlStrobeIn & ~wlStrobePrev).named('wl_dqs_pulse');
      } else {
        wlPulse = Const(0);
      }

      // PER-LANE WRITE SKEW (HARBOR_DDR_DQBEAT1). The x16 DRAM is two INDEPENDENT
      // byte lanes (DQ[7:0]/DQS0, DQ[15:8]/DQS1), each with its own DQ-vs-DQS flight
      // skew at the DRAM. One shared launch centers only ONE lane's write eye
      // (HW-confirmed at cmdSlot=2/WRSHIFT=-1/WRBEAT=3: byte-lane 0 writes 0xFF
      // cleanly, byte-lane 1 captures ~0). This rotates byte-lane 1's DQ beats by
      // [dqBeat1] beats (0.5 CK each) relative to lane 0, re-centering lane 1's data
      // on its (shared-timed) DQS. It is the only per-lane write alignment the Arty
      // HR bank allows (no ODELAYE2 for a sub-bit per-lane output delay). Sweep to
      // land lane 1, lane 0 (i<8) is untouched.
      const dqBeat1 = 0;
      // Per-DQ OSERDESE2 + pad IOBUF. IOBUF.O is the read return into the read
      // datapath's dqIn (replaces the dq_in port in ddr3Fast).
      final dqReadIn = <Logic>[];
      for (var i = 0; i < dataBits; i++) {
        // Byte-lane 1 (DQ[15:8]) rotates its data beats by dqBeat1 vs lane 0.
        final laneShift = (i ~/ 8 == 1) ? dqBeat1 : 0;
        int rot(int b) => (((b - laneShift) % 8) + 8) % 8;
        final beats = [
          for (var b = 0; b < 8; b++)
            writeLevel
                // WL build: RUNTIME per-lane rotation from the trained
                // pointer [pos]. Output beat b sources DRAM beat
                // (b - pos) mod 8. The 3-bit subtract wraps mod 8 and the
                // cases-mux picks that source beat from dataLineReg. This
                // replaces the compile-time env rot() so the WL-trained tap
                // (not the env dqBeat1) centers each lane's write.
                ? cases(
                    (Const(b, width: 3) - wlPos[i ~/ 8]).named(
                      'dq_rotsel_${i}_$b',
                    ),
                    {
                      for (var s = 0; s < 8; s++)
                        Const(s, width: 3): dataLineReg.getRange(
                          s * dataBits + i,
                          s * dataBits + i + 1,
                        ),
                    },
                  )
                : dataLineReg.getRange(
                    rot(b) * dataBits + i,
                    rot(b) * dataBits + i + 1,
                  ),
        ];
        final os = XilinxOserdese2(
          clk: writeCkData, // ck90 (on a BUFG): DQ launched on ck90 with an ODD
          // wrBeatOffset gives an effective 270-deg launch = DQ LEADS DQS (on ck0
          // == CK) by 90 deg, so the DQS edge lands centered in the DQ eye while
          // DQS stays CK-aligned (tDQSS). Only DQ+DM ride ck90 (~18 OSERDES) and the
          // BUFG lands them all on the OLOGIC leaf (UberDDR3's proven config).
          clkdiv: writeCkDiv, // ctrl83 = CK/4 (the 8:1 DDR gear ratio)
          d: beats,
          t1: dqT1,
          rst: reset,
          name: 'dqf_oserdes_$i',
        );
        final iob = XilinxIobuf(
          i: os.oq,
          t: os.tq,
          io: padDqIn![i],
          name: 'dqf_iobuf_$i',
        );
        dqReadIn.add(iob.o);
      }
      // Feed the read datapath from the pad IOBUF outputs (not the dq_in port).
      ddr3FastDqReadIn = dqReadIn.rswizzle();

      // DM: one OSERDESE2 per byte lane, no tristate (a plain output OBUF).
      final dmLanes = dataBits ~/ 8;
      final dmObufBits = <Logic>[];
      for (var l = 0; l < dmLanes; l++) {
        final dmBeats = [
          for (var b = 0; b < 8; b++)
            dmLineReg.getRange(b * dmLanes + l, b * dmLanes + l + 1),
        ];
        final os = XilinxOserdese2(
          clk:
              writeCkData, // ck90 BUFG, same phase as DQ (DM masks the DQ beats,
          // so it must launch on the identical clock + share the odd wrBeatOffset).
          clkdiv: writeCkDiv,
          d: dmBeats,
          hasTristate: false,
          rst: reset,
          name: 'dmf_oserdes_$l',
        );
        final ob = XilinxObuf(name: 'dmf_obuf_$l');
        ob.input('I').srcConnection! <= os.oq;
        dmObufBits.add(ob.output('O'));
      }
      // Drive the DM pin bus from the per-lane OBUF outputs.
      dmOut <= dmObufBits.rswizzle();

      // DQS: one OSERDESE2 per strobe lane launching the toggling pattern
      // {1,0,1,0,1,0,1,0} over the burst on ck0: the SAME phase as CK (ckLaunch
      // also rides ck0), so DQS is edge-aligned to CK (JEDEC tDQSS). DQ+DM ride
      // ck90 with an ODD wrBeatOffset for an effective 270-deg launch = DQ leads
      // DQS by 90 = DQS edge centered in the DQ eye. Keeping DQS (+CK+command) on
      // the ck0 leaf is what makes the design pack (the ck90-command variant spilled
      // to uncharacterized IMUX31 pips). In-site tristate matched to the DQ window.
      // Explicit pseudo-differential _n.
      // DQS toggle {1,0,1,0,1,0,1,0} over the 8 beats, gated to the SINGLE burst
      // cycle [wrBurst] (NOT the 4-cycle wrActive). This makes DQS a clean 4-CK
      // strobe train that frames exactly the one BL8 the OSERDESE2 serializes,
      // with the parked-low state on the surrounding cycles serving as the write
      // preamble/postamble (the pad OE opens one cycle early via oeFast so the
      // preamble low is driven). The old 4-cycle wrActive gate toggled DQS for 16
      // CK across 4 cycles with no defined edge vs the 1-cycle data burst = the
      // write never framed (A==B on HW).
      final dqsToggle = [
        Const(1), Const(0), Const(1), Const(0), //
        Const(1), Const(0), Const(1), Const(0),
      ];
      // PER-LANE DQS STROBE POSITION (HARBOR_DDR_DQSBEAT1). Companion to
      // HARBOR_DDR_DQBEAT1 (which rotates lane1's DQ): this rotates lane1's DQS
      // toggle beats by [dqsBeat1] (0.5 CK each) so the strobe train can be moved
      // vs the (shared-timed) DQ and vs CK. x16 diagnosis 2026-07: lane1 writes
      // capture the parked-low state (reads 0x00) and are INSENSITIVE to DQ
      // rotation => DQS1's edges are not framing lane1's data burst at the DRAM,
      // this is the actuator to place them. Non-writeLevel build only (the WL
      // build rotates DQS via the trained wlPos). Sweep 0..7 to land lane1, lane0
      // (l==0) is untouched. An odd value shifts the DQS edges 0.5 CK vs DQ = a
      // discrete sub-beat DQS-vs-DQ phase (no fine MMCM phase on this HR bank).
      const dqsBeat1 = 0;
      // ORACLE-MATCH DQS CLOCK: the UberDDR3 Arty HR-bank oracle clocks the write
      // DQS OSERDES on `.CLK(!i_ddr3_clk)`: the CK net INVERTED ON-CHIP (exact
      // 180-deg, same net + matched insertion delay as CK/command), NOT a separate
      // CLKOUT4 180-deg net. Our separate CLKOUT4 had insertion-delay skew that
      // pushed the DQS edge off tDQSS at the DRAM (writes never latched, and the
      // CLKOUT4 phase sweep had no effect because the net skew dominated). Use the
      // inverted CK net.
      const dqsUseInvCk = true;
      final dqsClk = writeCk;
      // Read-DQS tap: the DQS pad IOBUF's .O output is the strobe the DRAM drives
      // back during a read. On creek's pinout DQS (K1/L1) is NOT clock-capable, so
      // it cannot clock the read ISERDESE2 (openXC7 has no PHASER); instead capture
      // it on CK like a DQ lane and use its toggling to GATE the read window in
      // fabric (see the dqsGatedRead block below). One entry per DQS lane.
      dqsReadIn = <Logic>[];
      for (var l = 0; l < dmLanes; l++) {
        final selected = writeLevel
            ? wlLaneIn!.eq(Const(l, width: laneSelW))
            : Const(0);
        // P-rail DQS beats + the per-lane OE (dqsT1L). Off the writeLevel build:
        // the plain toggle gated to the burst cycle (byte-identical to before). On
        // it: normal writes ROTATE the toggle by the trained beat [wlPos[l]] so
        // DQS tracks the rotated DQ, and WL mode emits a SINGLE rising edge at beat
        // [pos] so the DRAM samples CK on exactly one DQS edge.
        final List<Logic> dqsPBeats;
        final Logic dqsT1L;
        if (!writeLevel) {
          // Rotate lane1's DQS strobe by dqsBeat1 beats (0.5 CK each) vs lane0.
          final laneShift = (l == 1) ? dqsBeat1 : 0;
          int rot(int b) => (((b - laneShift) % 8) + 8) % 8;
          dqsPBeats = [
            for (var b = 0; b < 8; b++)
              (dqsToggle[rot(b)] & wrBurstDqs).named('dqsp_${l}_$b'),
          ];
          dqsT1L = dqT1;
        } else {
          dqsPBeats = <Logic>[];
          for (var b = 0; b < 8; b++) {
            // Normal write: rotate the toggle by the trained beat. (b - pos) mod 8
            // via the 3-bit wrap + cases-mux, matching the DQ rotation above.
            final normal = cases(
              (Const(b, width: 3) - wlPos[l]).named('dqs_rotsel_${l}_$b'),
              {for (var s = 0; s < 8; s++) Const(s, width: 3): dqsToggle[s]},
            );
            final gatedNormal = (normal & wrBurstDqs).named('dqsnorm_${l}_$b');
            // WL: single 0->1 step at beat [pos] (drives 1 iff b >= pos), gated to
            // the selected lane and the one-cycle [wlPulse], low otherwise (the
            // driven-low preamble). Sweeping pos walks the edge across the CK
            // period (0.5 CK/beat): the WL scan actuator.
            final wlStep = Const(
              b,
              width: 3,
            ).gte(wlPos[l]).named('dqs_wlstep_${l}_$b');
            final wlBeat = (selected & wlPulse & wlStep).named(
              'dqs_wl_${l}_$b',
            );
            dqsPBeats.add(
              mux(wlEnIn!, wlBeat, gatedNormal).named('dqsp_${l}_$b'),
            );
          }
          // Force the SELECTED lane's DQS OE open across WL (t1=0 = drive) so it
          // drives the preamble-low + strobe edge, non-selected lanes keep dqT1
          // (HiZ when oeFast=0). DQ stays an INPUT during WL (oeFast=0 -> dqT1=1).
          dqsT1L = mux(wlEnIn! & selected, Const(0), dqT1).named('dqs_t1_$l');
        }
        final osP = XilinxOserdese2(
          clk: dqsClk, // !CK (inverted on-chip) = 180-deg, matching the oracle.
          clkInverted: dqsUseInvCk,
          clkdiv: writeCkDiv,
          d: dqsPBeats,
          t1: dqsT1L,
          initOq: "1'b1",
          rst: reset,
          name: 'dqsf_oserdes_$l',
        );
        final osN = XilinxOserdese2(
          clk: dqsClk, // !CK (complement rail, same inverted CK net)
          clkInverted: dqsUseInvCk,
          clkdiv: writeCkDiv,
          // N rail = complement of the (possibly rotated) P beats, so the
          // differential and the dqsBeat1 rotation track together.
          d: [
            for (var b = 0; b < 8; b++) (~dqsPBeats[b]).named('dqsn_${l}_$b'),
          ],
          t1: dqsT1L,
          rst: reset,
          name: 'dqsnf_oserdes_$l',
        );
        final dqsIob = XilinxIobuf(
          i: osP.oq,
          t: osP.tq,
          io: padDqsIn![l],
          name: 'dqsf_iobuf_$l',
        );
        // The P-rail pad input = the read strobe (DQS# is the complement, unused
        // for the gate). Feeds the read-DQS capture ISERDESE2 below.
        dqsReadIn.add(dqsIob.o);
        XilinxIobuf(
          i: osN.oq,
          t: osN.tq,
          io: padDqsNIn![l],
          name: 'dqsnf_iobuf_$l',
        );
      }
      // The base dq_out/dq_oe/dqs_out/dqs_n_out/dqs_oe outputs are unused in
      // ddr3Fast (the PHY drives the pads directly), tie them to safe constants
      // so they are not left undriven.
      dqOut <= Const(0, width: dataBits);
      dqOe <= Const(0);
      dqsOut <= Const(0, width: dmLanes);
      dqsNOut <= Const(0, width: dmLanes);
      dqsOe <= Const(0);
    } else {
      // DQ: rising half-word in the D1 slot, falling in D2, on the 90-degree
      // clock so the eyes straddle DQS.
      final dqBits = <Logic>[
        for (var i = 0; i < dataBits; i++)
          XilinxOddr(
            c: clk90,
            d1: dqRise[i],
            d2: dqFall[i],
            r: reset,
            name: 'dq_oddr_$i',
          ).q,
      ];
      dqOut <= dqBits.rswizzle();

      // DM: mask every beat except the addressed word's enabled byte lanes
      // (DM=1 means ignore). D1 masks lanes 0/1, D2 lanes 2/3.
      final dmBits = <Logic>[
        for (var i = 0; i < dataBits ~/ 8; i++)
          XilinxOddr(
            c: clk90,
            d1: ~(beatHit & wrSel[i]),
            d2: ~(beatHit & wrSel[2 + i]),
            r: reset,
            name: 'dm_oddr_$i',
          ).q,
      ];
      dmOut <= dmBits.rswizzle();

      // DQS: toggles during the burst, edge-aligned to CK.
      final dqsBits = <Logic>[
        for (var i = 0; i < dataBits ~/ 8; i++)
          XilinxOddr(
            c: clk,
            d1: wrActive,
            d2: Const(0),
            r: reset,
            name: 'dqs_oddr_$i',
          ).q,
      ];
      dqsOut <= dqsBits.rswizzle();
      // DQS#: explicit pseudo-differential complement.
      final dqsNBits = <Logic>[
        for (var i = 0; i < dataBits ~/ 8; i++)
          XilinxOddr(
            c: clk,
            d1: ~wrActive,
            d2: Const(1),
            r: reset,
            name: 'dqs_n_oddr_$i',
          ).q,
      ];
      dqsNOut <= dqsNBits.rswizzle();
      dqsOe <= oeActive;
      dqOe <= oeActive;
    }

    // Read engine. Each DQ bit flows: pad -> IDELAYE2 (static tap) ->
    // IDDR (SAME_EDGE, clk90) producing Q1 (rise) / Q2 (fall) per bit per
    // cycle. ISERDESE2 is NOT used: nextpnr-xilinx's xc7s50 chipdb has no BUFR
    // bels for its CLKDIV pin, making it unrouteable. IDDR has no CLKDIV and
    // routes fine. A DdrReadWordAssembler registers 4 beat-words over the
    // CL+slack read window and selects the addressed word, keeping the existing
    // rd_data/rd_valid interface. Every IDELAYE2 needs an IDELAYCTRL.
    //
    // IDELAYCTRL RST reset-stretch: the delay line only calibrates (RDY
    // asserts) after its RST is held asserted for at least TIDELAYCTRL_RPW
    // (>= 52 ns per DS181), THEN deasserted, with a stable REFCLK. Wiring RST
    // straight to the fabric reset yields a single-cycle pulse. On a fast clock
    // (or a very short external reset) that is under 52 ns, RDY never asserts,
    // and the VARIABLE/VAR_LOAD taps stay FROZEN (the empty-eye read bug seen on
    // HW: read value identical at taps 0/8/16/24). Stretch RST with a power-up
    // counter clocked on the (stable, always-running) IDELAYCTRL reference so
    // RST stays asserted for a generous ~1 us window after power-up/reset, then
    // releases clean. hold-cycles = ceil(1_000_000 ps / refPeriod_ps), at
    // ~208 MHz that is ~208 cycles (~1 us), well above the 52 ns minimum.
    final refPeriodPs = 1000000.0 / idelayRefMhz; // period(ps) = 1e6 / f(MHz)
    const holdPs = 1000000.0; // ~1 us hold (>> 52 ns TIDELAYCTRL_RPW)
    final rstHoldCycles = (holdPs / refPeriodPs).ceil().clamp(16, 1 << 20);
    final rstCtrWidth = (rstHoldCycles + 1).bitLength;
    final rstCtr = Logic(name: 'idelayctrl_rst_ctr', width: rstCtrWidth);
    final rstHeld = Logic(name: 'idelayctrl_rst_held');
    // Count up on the reference clock until the hold target, then release. A
    // fabric reset restarts the count so RST re-stretches on every reset.
    Sequential(idelayRefclk, reset: reset, [
      If(
        rstCtr.lt(Const(rstHoldCycles, width: rstCtrWidth)),
        then: [rstCtr < rstCtr + 1, rstHeld < 1],
        orElse: [rstHeld < 0],
      ),
    ]);
    // RST asserted while stretching OR while the fabric reset is asserted.
    final idelayctrlRst = (rstHeld | reset).named('idelayctrl_rst');
    final idelayRdyNet = XilinxIdelayctrl(
      refclk: idelayRefclk,
      rst: idelayctrlRst,
      name: 'idelayctrl',
    ).rdy;
    output('idelay_rdy') <= idelayRdyNet;

    // Read window ANCHORED at CAS latency (mirrors ddr_phy_ecp5.dart).
    // rdPipe[cl + rdSlack - 1] asserts on the cycle beatWord (or the ddr3Fast
    // BL8 line) carries beat0, readSlack is swept on HW to land on the real
    // return point. The cl term is essential: dropping it opens ~cl cycles too
    // early and every streaming burst collapses to one replicated beat
    // (hi16==hi16, streaming-read bug). In ddr3Fast the read pipe counts on the
    // ctrl83 clock and CL is in CONTROLLER cycles (CK/4), so the CL landing tap
    // divides down accordingly, the exact tap is a HW bring-up sweep, the
    // structure/routing does not depend on it.
    final rdSlack = readSlack;
    const pipeLen = 16;
    final rdPipe = Logic(name: 'rd_pipe', width: pipeLen);
    Sequential(clk, reset: reset, [
      rdPipe < [rdPipe.getRange(0, pipeLen - 1), rdStart].swizzle(),
    ]);
    // ddr3Fast: CL is in CK cycles but the read pipe ticks on ctrl83 (CK/4). The
    // whole-tick part of CL = cl ~/ ckCyclesPerTick indexes the read pipe, the
    // sub-tick residual (CL % ckCyclesPerTick CK) is absorbed by the per-lane
    // ISERDESE2 BITSLIP (the read twin of the write beat-offset), swept via
    // HARBOR_DDR_BITSLIP / the trainable bitslip. The exact whole-tick tap is
    // also HW-swept via readSlack / the runtime windowSel (reg12). On the 48 MHz
    // path (ckCyclesPerTick=1) this is the original (cl+rdSlack-1).
    final windowTap = ddr3Fast
        ? ((cl ~/ ckCyclesPerTick) + rdSlack).clamp(1, pipeLen - 1)
        : (cl + rdSlack - 1);
    // Read-calibration channel from the sequencer's sRdCal FSM. On the read-cal
    // build these drive the per-lane IDELAY/bitslip and the read window while
    // rdCalAct; the firmware train regs (below) still apply otherwise (so Linux
    // can retune post-boot). Tied off to the firmware path when null.
    final hasRdCal = rdCalActive != null;
    final rdCalAct = hasRdCal
        ? addInput('rd_cal_active', rdCalActive)
        : Const(0);
    final rdCalLd = hasRdCal
        ? addInput('rd_cal_idelay_ld', rdCalIdelayLd!)
        : Const(0);
    final rdCalTapIn = hasRdCal
        ? addInput('rd_cal_tap', rdCalTap!, width: 5)
        : Const(0, width: 5);
    final rdCalLaneIn = hasRdCal
        ? addInput('rd_cal_lane', rdCalLane!, width: laneSelW)
        : Const(0, width: laneSelW);
    final rdCalWinIn = hasRdCal
        ? addInput('rd_cal_window', rdCalWindow!, width: 4)
        : Const(0, width: 4);
    final rdCalBs = hasRdCal
        ? addInput('rd_cal_bitslip', rdCalBitslip!)
        : Const(0);
    // The cal-located read window: latch rdCalWindow while calibrating so it
    // persists after the phase (reset to the compile-time tap for pre-cal reads).
    final calWindowReg = Logic(name: 'cal_window_reg', width: 4);
    if (hasRdCal) {
      Sequential(
        clk,
        reset: reset,
        resetValues: {calWindowReg: Const(windowTap, width: 4)},
        [
          If(rdCalAct, then: [calWindowReg < rdCalWinIn]),
        ],
      );
    }

    // ddr3Fast can override the compile-time window tap at RUNTIME (reg12): the
    // BL8 line lands in a specific ctrl83 cycle after rd_start, and which cycle
    // is a board-tuning unknown, so firmware walks [windowSel] over the read
    // pipe to find the capturing cycle. selectFrom indexes rd_pipe by the
    // 4-bit tap, without windowSel the static compile-time tap is used. With
    // read-cal, the cal-live/cal-locked window wins.
    final Logic windowOpen;
    if (ddr3Fast) {
      final Logic winIdx;
      if (hasRdCal) {
        winIdx = mux(rdCalAct, rdCalWinIn, calWindowReg);
      } else if (windowSel != null) {
        winIdx = addInput('window_sel', windowSel, width: 4);
      } else {
        winIdx = Const(windowTap, width: 4);
      }
      windowIdxSig = winIdx;
      windowOpen = winIdx
          .selectFrom([for (var t = 0; t < pipeLen; t++) rdPipe[t]])
          .named('window_open');
    } else {
      windowOpen = rdPipe[windowTap].named('window_open');
    }

    // 16x [pad -> IDELAYE2(VAR_LOAD or FIXED, DDLY) -> ISERDESE2(DW8, DDR,
    // NETWORKING, IOBDELAY=IFD, CLK=ck333, CLKDIV=ctrl83)] delivers the WHOLE
    // BL8 (8 beats) per lane in ONE ctrl83 cycle on Q1..Q8. The line is packed
    // beat-major {beat7..beat0}, each beat dataBits wide, and a
    // [DdrBl8SerdesAssembler] selects the beatSel word. This is the UberDDR3 /
    // LiteDRAM read gearbox. OCLK/OCLKB are UNCONNECTED (the routing fix) and
    // CLK vs CLKDIV are two DISTINCT BUFG nets (the routing key).
    if (ddr3Fast) {
      // VAR_LOAD IDELAY on either the firmware-train build or the read-cal build.
      final ftrainable = idelayLd != null || hasRdCal;
      Logic? fLd, fCnt, fILane;
      if (idelayLd != null) {
        fLd = addInput('idelay_ld', idelayLd);
        fCnt = addInput('idelay_cntvalue', idelayCntValue!, width: 5);
        fILane = addInput('idelay_lane', idelayLane!, width: idelayLane.width);
      }
      // Effective IDELAY load pulse + tap: the read-cal channel wins while
      // rdCalAct, else the firmware regs (or 0 when a build lacks them).
      final effLoad = hasRdCal
          ? mux(rdCalAct, rdCalLd, fLd ?? Const(0))
          : (fLd ?? Const(0));
      final effTap = hasRdCal
          ? mux(rdCalAct, rdCalTapIn, fCnt ?? Const(0, width: 5))
          : (fCnt ?? Const(0, width: 5));
      // Per-lane BITSLIP: runtime on the trainable path (a per-lane pulse gated
      // by bitslipLane), else a static 0 rotation for all lanes.
      Logic? fBitslip, fBLane;
      const envBitslip = 0;
      if (bitslip != null) {
        fBitslip = addInput('bitslip', bitslip);
        fBLane = addInput(
          'bitslip_lane',
          bitslipLane!,
          width: bitslipLane.width,
        );
      }
      // The read ISERDESE2 CLK SHARES the CK global-BUFG net (sharedFastCk),
      // exactly as the oracle wires its read ISERDESE2 .CLK(i_ddr3_clk) = the
      // same net that drives the DDR CK: NO separate read-CLK buffer, NO
      // regional BUFH. This is the exact-oracle fix for the R2 400MHz build: a
      // regional BUFHCE here got mis-bound by nextpnr 0.8.2's clock packer to
      // the wrong clock region (BUFGCTRL_X0Y5->BUFHCE_X0Y12 unroutable). A global
      // BUFG on the CK net has no region to mis-bind. The whole DDR tree is now
      // 4 global BUFGs (CK/CLKDIV/idelayref/ck90), ZERO regional BUFH.
      final readCk = ddr3FastSharedCk!;
      // Assemble the 8 beats x dataBits line: for lane i, ISERDESE2 Qk is beat
      // (k-1). beat b's bit i sits at line[b*dataBits + i].
      final laneQ = <List<Logic>>[]; // laneQ[i] = [Q1..Q8] for lane i
      for (var i = 0; i < dataBits; i++) {
        // Load-enable for DQ bit i. Firmware addresses per DQ bit (fILane == i);
        // the read-cal channel addresses per BYTE lane (all 8 DQ of lane i~/8
        // get the swept tap), so the cal hit is a byte-lane compare.
        final fwHit = fILane != null
            ? fILane.eq(Const(i, width: fILane.width))
            : Const(0);
        final calHit = Const(i ~/ 8, width: laneSelW).eq(rdCalLaneIn);
        final laneHit = hasRdCal ? mux(rdCalAct, calHit, fwHit) : fwHit;
        final ddly = XilinxIdelaye2(
          // Read DQ from the write OSERDESE2's pad IOBUF O output (the PHY owns
          // the DQ pad in ddr3Fast), not the dq_in port.
          idatain: ddr3FastDqReadIn![i],
          // Static power-up read tap. In VAR_LOAD (trainable) mode the IDELAYE2
          // holds 0 until firmware loads a tap; the FIXED (untrainable) path bakes
          // readTaps.
          idelayValue: ftrainable ? 0 : readTaps,
          c: clk, // ctrl83 (the IDELAY control clock)
          refClkFrequency: idelayRefMhz,
          idelayType: ftrainable ? 'VAR_LOAD' : 'FIXED',
          ld: ftrainable ? (effLoad & laneHit) : null,
          cntValueIn: ftrainable ? effTap : null,
          name: 'dqf_idelay_$i',
        ).dataout;
        // Per-lane BITSLIP pulse: on the trainable path, gate the shared pulse
        // by a lane match, otherwise a compile-time constant per lane. The
        // read-cal channel wins while rdCalAct (byte-lane addressed).
        final Logic bsPulse;
        if (fBitslip != null || hasRdCal) {
          final fwBs = fBitslip != null
              ? (fBitslip & fBLane!.eq(Const(i, width: fBLane.width)))
              : Const(0);
          final calBs =
              rdCalBs & Const(i ~/ 8, width: laneSelW).eq(rdCalLaneIn);
          bsPulse = (hasRdCal ? mux(rdCalAct, calBs, fwBs) : fwBs).named(
            'dqf_bitslip_$i',
          );
        } else {
          bsPulse = Const(0);
        }
        // Fabric rotate register for this lane: advances one beat per bitslip
        // pulse (firmware reg11 or the read-cal channel). Resets to 0; the FSBL
        // sweeps it 0..7 exactly like it swept the old hardware BITSLIP.
        final iser = XilinxIserdese2(
          clk:
              readCk, // CK on the shared global BUFG net (== oracle i_ddr3_clk)
          clkb: readCk, // IS_CLKB_INVERTED inverts on-chip (one clk net)
          // CLKDIV = the SHARED BUFG'd ctrl100 (CK/4), the SAME net
          // the write OSERDESE2 uses. A DATA_WIDTH=8 ISERDESE2 loads its 8-beat
          // parallel word (Q1..Q8) and advances BITSLIP on CLKDIV, with it left
          // unconnected the parallel register never clocks and Q1..Q8 FREEZE, so
          // every read returns a fixed constant independent of the stored data,
          // the IDELAY tap, and the capture window (HW-confirmed: A==B==C read
          // 0x73145241 for any write/address). The write path already proved a
          // BUFH CLKDIV lands on the I/O clock leaf and routes (unlike a raw BUFG
          // net, which contended IOI_CLK0 -> overused=32), so sharing it gives
          // the read deserializer a real load clock without re-triggering the
          // route stall.
          clkdiv: ddr3FastCkDiv,
          ddly: ddly, // IOBDELAY=IFD: pad -> IDELAYE2 -> SERDES
          bitslip: bsPulse,
          rst: reset,
          dataWidth: 8,
          name: 'dqf_iser_$i',
        );
        // REAL XILINX BEAT ORDER: the ISERDESE2 presents Q1 = NEWEST (last-
        // arriving) sample and Q8 = OLDEST (first-arriving) sample. The BL8 read
        // burst arrives oldest-first, so beat 0 (the first DQ beat off the DRAM) =
        // Q8 and beat 7 = Q1. Store laneQ oldest-first (index 0 = Q8 = beat 0) so
        // the packing below indexes by chronological beat. This is the HW-verified
        // UberDDR3 / LiteDRAM convention. The earlier code packed beat0<-Q1 (time-
        // reversed) and the sim model was flipped to match, so both are corrected
        // together (iserdese2_sim.dart now presents Q1=newest too).
        laneQ.add([for (var q = 8; q >= 1; q--) iser.output('Q$q')]);
      }

      // Write-leveling DQ feedback capture. During WL the DRAM samples CK on the
      // DQS rising edge and drives the (static) result on every DQ of the lane.
      // Unlike ECP5 (whose read capture needs a DQS strobe), the ddr3Fast read
      // ISERDESE2 free-runs on the DDR CK net (readCk, no DQS gate), so the static
      // level appears on its Q beats directly, no self-driven-DQS trick needed.
      // Tap laneQ BEFORE the windowOpen/assembler logic: OR-reduce the selected
      // lane's 8 DQ bits x 8 captured beats into one bit and register it on ctrl83
      // (the SAME clock the sequencer's WL FSM ticks on, so no CDC). The static WL
      // level lands on every beat + every DQ of the lane, so the OR is robust to
      // which beat the free-running gearbox framed. SIM CAVEAT: the ISERDESE2 Q is
      // X in sim, so in sim the FSM is exercised by forcing wl_feedback. On
      // hardware this is the real feedback bit.
      if (writeLevel) {
        final laneFb = [
          for (var l = 0; l < laneCount; l++)
            [
              for (var i = l * 8; i < l * 8 + 8; i++)
                for (var q = 0; q < 8; q++) laneQ[i][q],
            ].swizzle().or().named('wl_fb_lane_$l'),
        ];
        final selFb = laneCount == 1
            ? laneFb[0]
            : cases(wlLaneIn!, {
                for (var l = 0; l < laneCount; l++)
                  Const(l, width: laneSelW): laneFb[l],
              }, defaultValue: laneFb[0]);
        final wlFbReg = Logic(name: 'wl_fb_reg');
        Sequential(clk, reset: reset, [wlFbReg < selFb]);
        output('wl_feedback') <= wlFbReg;
      }

      // Fallback beat rotate when the compile-time env bitslip is set on the
      // non-trainable path (the whole line rotates by envBitslip beats). Applied
      // by re-indexing the oldest-first laneQ. On the trainable path the ISERDESE2
      // BITSLIP does it.
      int qIdx(int beat) => bitslip == null ? ((beat + envBitslip) % 8) : beat;
      // Pack the line: line[beat*dataBits + lane] = laneQ[lane][qIdx(beat)],
      // where laneQ index is chronological (0 = Q8 = oldest = beat 0).
      final beatVecs = <Logic>[];
      for (var b = 0; b < 8; b++) {
        beatVecs.add(
          [for (var i = 0; i < dataBits; i++) laneQ[i][qIdx(b)]].rswizzle(),
        );
      }
      // rswizzle already puts lane0 in the LSB, swizzle the beats beat-major.
      final beatLine = [
        for (var b = 7; b >= 0; b--) beatVecs[b],
      ].swizzle().named('beat_line');

      // READ-DQS WINDOW GATE (dqsGatedRead). The fixed windowTap guess mis-frames
      // the capture under the i+d read cadence (icache fetch + dcache load both
      // reading DRAM): the DQ line lands a variable number of ctrl83 cycles after
      // rd_start, and a static tap latches the WRONG cycle (a stale line). Fix =
      // let the read strobe pick the cycle. Capture DQS on CK exactly like a DQ
      // lane (same IDELAY/CK/CLKDIV, so it deserializes cycle-aligned with
      // beatLine) and open the window on the cycle its 8 beats carry a burst. DQS
      // can't clock the capture on creek's non-clock-capable K1/L1 pins, but as
      // captured data its toggling still marks the valid cycle.
      Logic effWindowOpen = windowOpen;
      // DIAGNOSTIC: sticky map of which rd_pipe taps [7:0] ever saw the DQS burst
      // (0xAA/0x55). Read via reg7 (dbg_beats). Tells firmware WHERE the strobe
      // frames relative to the read command, vs the working DQ window
      // (RD_WINDOW_VAL). A single stable bit = a fixed offset exists; a spread =
      // the strobe position varies per read (no fixed offset can align it).
      Logic? dqsBurstMapDbg;
      if (dqsGatedRead) {
        // DQS IDELAY: VAR_LOAD so the FSBL can sweep the DQS eye centre INDEPENDENTLY
        // of DQ. DQS is edge-aligned with DQ, so the DQ-centred tap lands the DQS on
        // its transition edge (captured 0xA0 = half the beats metastable). Loaded
        // via reg10 with a sentinel fILane index (= dataBits, one past the last DQ
        // bit) the DQ bits do not use. Falls back to FIXED readTaps when the sentinel
        // does not fit the lane field (e.g. x16 uses all 16 indices).
        final sentinelFits =
            ftrainable && fILane != null && dataBits < (1 << fILane.width);
        final Logic dqsDdly = sentinelFits
            ? XilinxIdelaye2(
                idatain: dqsReadIn![0],
                idelayValue: 0,
                c: clk,
                refClkFrequency: idelayRefMhz,
                idelayType: 'VAR_LOAD',
                ld: fLd! & fILane.eq(Const(dataBits, width: fILane.width)),
                cntValueIn: fCnt,
                // DQS is a strobe (clock-like), not a data line - the IDELAY must
                // track it as a CLOCK to delay it correctly (UberDDR3 ddr3_phy.v).
                signalPattern: 'CLOCK',
                name: 'dqsf_gate_idelay',
              ).dataout
            : XilinxIdelaye2(
                idatain: dqsReadIn![0],
                idelayValue: readTaps,
                c: clk,
                refClkFrequency: idelayRefMhz,
                idelayType: 'FIXED',
                signalPattern: 'CLOCK',
                name: 'dqsf_gate_idelay',
              ).dataout;
        final dqsIser = XilinxIserdese2(
          clk: readCk,
          clkb: readCk,
          clkdiv: ddr3FastCkDiv,
          ddly: dqsDdly,
          bitslip: Const(0),
          rst: reset,
          dataWidth: 8,
          name: 'dqsf_gate_iser',
        );
        final dqsBeats = [
          for (var q = 8; q >= 1; q--) dqsIser.output('Q$q'),
        ].swizzle().named('dqs_gate_beats');
        // Burst present = the 8 strobe beats are the DDR3 read strobe's alternating
        // pattern (0xAA or 0x55, either frame polarity). This marks ONLY the fully
        // framed data-burst cycle: the read preamble (DQS low) and the floating
        // tristate DQS between bursts are not alternating, so they don't false-open.
        final dqsBurst =
            (dqsBeats.eq(Const(0xAA, width: 8)) |
                    dqsBeats.eq(Const(0x55, width: 8)))
                .named('dqs_burst');
        // Honor the strobe only inside a widened window around the CL tap so our own
        // write strobe / floating idle DQS on the shared pad cannot false-trigger a
        // read (writes assert no rd_start, so rd_pipe gates them out; this bounds
        // the search to the real return region).
        final loTap = (windowTap - 2).clamp(0, pipeLen - 1);
        final hiTap = (windowTap + 3).clamp(0, pipeLen - 1);
        final readWin = [
          for (var t = loTap; t <= hiTap; t++) rdPipe[t],
        ].swizzle().or().named('dqs_read_win');
        final dqsGated = (dqsBurst & readWin).named('dqs_gated');
        // TUNABLE strobe->window offset. The DQ line lands a fixed few ctrl83 cycles
        // after the strobe is first detected (the read preamble puts DQS ahead of
        // the DQ data). Delay [dqsGated] through a shift register and pick the tap
        // with windowSel[2:0] (reg12), so the FSBL read-setup sweep AUTO-FINDS the
        // offset in one build instead of a compile-time guess. Offset 0 (no runtime
        // window reg) = fire on the detect cycle.
        final dqsHist = Logic(name: 'dqs_gated_hist', width: 7);
        Sequential(clk, reset: reset, [
          dqsHist < [dqsHist.getRange(0, 6), dqsGated].swizzle(),
        ]);
        final dqsDelays = [dqsGated, for (var k = 0; k < 7; k++) dqsHist[k]];
        final offSel = windowIdxSig != null
            ? windowIdxSig.getRange(0, 3)
            : Const(0, width: 3);
        effWindowOpen = offSel.selectFrom(dqsDelays).named('dqs_window_open');
        // DIAGNOSTIC: latch the RAW captured DQS beats whenever a read is returning
        // (any of rd_pipe[3..7] high), so firmware sees what DQS-on-CK actually
        // deserializes: 0xAA/0x55 = clean strobe (then it's a position/offset
        // issue), 0x00/0xFF = static (OE not tristated / floating pad), anything
        // else = wrong sampling phase (the DQS edge lands on the CK capture edge).
        // Hold the last NON-ZERO capture in the return window: the DQS preamble and
        // postamble are low (0x00), so latching every cycle would overwrite the
        // burst with the postamble. Gating on dqsBeats!=0 keeps the actual toggling
        // burst value.
        // Cleared at each read start so reg7 reflects THIS read's strobe capture -
        // lets the FSBL DQS-eye sweep read a fresh value per IDELAY tap.
        final inReturn = rdPipe.getRange(3, 8).or().named('dqs_in_return');
        final rawDqs = Logic(name: 'dqs_raw', width: 8);
        Sequential(clk, reset: reset, [
          If(rdStart, then: [rawDqs < Const(0, width: 8)]),
          If(inReturn & dqsBeats.or(), then: [rawDqs < dqsBeats]),
        ]);
        dqsBurstMapDbg = rawDqs;
      }

      // DEBUG: lane-0's 8 CAPTURED beats (beat0..7 in bits[0..7]) latched on
      // windowOpen -> STATUS reg7. For an MPR read (DRAM pattern 0,FF,0,FF,...)
      // this should read 0b01010101/0xAA, all-0 => the DRAM is NOT driving the
      // MPR pattern (not in MPR mode / MRS or read cmd not landing), a non-zero
      // but non-alternating value => a capture/bitslip issue, not a command one.
      final dbgBeats = Logic(name: 'dbg_beats_int', width: 8);
      Sequential(clk, reset: reset, [
        If(
          effWindowOpen,
          then: [
            dbgBeats <
                [for (var b = 7; b >= 0; b--) beatLine[b * dataBits]].swizzle(),
          ],
        ),
      ]);
      addOutput('dbg_beats', width: 8);
      // With dqsGatedRead on, reg7 reports the DQS burst-position map instead of
      // the DQ beats, so firmware can see where the strobe frames (the diagnostic).
      output('dbg_beats') <= (dqsGatedRead ? dqsBurstMapDbg! : dbgBeats);

      // Read-cal per-lane MPR match. Lane l's DQ0 across the 8 captured beats is
      // an alternating byte (0x55 or 0xAA, phase set by which beat framed as
      // beat0) exactly when that lane reads the DRAM's MPR 0,FF,0,FF pattern
      // cleanly. Latch each lane's pattern on windowOpen and report the match so
      // the sequencer's sRdCal sweep can locate every lane's read eye. Both
      // alternating polarities count (bitslip picks the frame).
      if (hasRdCal) {
        final matchBits = <Logic>[];
        for (var l = 0; l < laneCount; l++) {
          final patReg = Logic(name: 'rd_cal_pat_$l', width: 8);
          Sequential(clk, reset: reset, [
            If(
              windowOpen,
              then: [
                patReg <
                    [
                      for (var b = 7; b >= 0; b--)
                        beatLine[b * dataBits + l * 8],
                    ].swizzle(),
              ],
            ),
          ]);
          matchBits.add(
            (patReg.eq(Const(0xAA, width: 8)) |
                    patReg.eq(Const(0x55, width: 8)))
                .named('rd_cal_match_$l'),
          );
        }
        addOutput('rd_cal_match', width: laneCount);
        output('rd_cal_match') <= matchBits.rswizzle();
      }

      final asm = DdrBl8SerdesAssembler(
        clk,
        reset,
        beatLine: beatLine,
        rdStart: rdStart,
        beatSel: beatSel,
        windowOpen: effWindowOpen,
        dataBits: dataBits,
        name: 'rd_bl8_assembler',
      );
      rdData <= asm.rdData;
      rdValid <= asm.rdValid;
      // The ISERDESE2 read path is complete, skip the IDDR path entirely. Drive
      // the fabric debug probe with the read window + IDELAYCTRL RDY.
      addOutput('dbg_probe', width: 5);
      output('dbg_probe') <=
          [
            idelayRdyNet,
            wrActive,
            effWindowOpen,
            beatHit,
            dqRise[0] ^ beatLine[0],
          ].swizzle();
      // DQ-drive-overlap counter to STATUS (the no-LA write-datapath witness).
      addOutput('wr_overlap_count', width: 8);
      output('wr_overlap_count') <= ddr3FastDriveOverlap!;
      return;
    }

    // Read-training bundle: present iff idelayLd was given. When present, each
    // per-DQ IDELAYE2 is VAR_LOAD (the reliable UberDDR3 absolute-tap mode) and
    // takes a 5-bit CNTVALUEIN + an LD pulse gated by an idelayLane match:
    // firmware writes an absolute tap and pulses LD to load it into one lane's
    // delay line (CE/INC are unused in VAR_LOAD). Null keeps the FIXED
    // static-tap baseline.
    final trainable = idelayLd != null;
    Logic? ldPort, cntPort, ilanePort;
    if (trainable) {
      ldPort = addInput('idelay_ld', idelayLd);
      cntPort = addInput('idelay_cntvalue', idelayCntValue!, width: 5);
      ilanePort = addInput('idelay_lane', idelayLane!, width: idelayLane.width);
    }

    // Per DQ bit: IDELAYE2 (FIXED static tap, or VARIABLE when trainable) ->
    // IDDR (SAME_EDGE on clk90). Q1 = rising-edge capture, Q2 = falling-edge.
    final q1Bits = <Logic>[]; // rise
    final q2Bits = <Logic>[]; // fall
    // The IDDR capture clock is the clk90 BUFG net directly.
    final Logic iddrClk = clk90;
    for (var i = 0; i < dataBits; i++) {
      final laneHit = trainable
          ? ilanePort!.eq(Const(i, width: ilanePort.width))
          : null;
      final delayed = XilinxIdelaye2(
        idatain: dqIn[i],
        // Trainable path uses VAR_LOAD: the absolute tap arrives on CNTVALUEIN
        // and is loaded by an LD pulse (gated to this lane), so firmware jumps
        // straight to any tap 0..31. IDELAY_VALUE is the power-up tap (0). The
        // static path keeps its measured [readTaps] FIXED tap. REFCLK_FREQUENCY
        // must equal the ACTUAL IDELAYCTRL reference (208 MHz off CLKOUT1) for
        // correct tap resolution.
        idelayValue: trainable ? 0 : readTaps,
        c: clk,
        refClkFrequency: idelayRefMhz,
        idelayType: trainable ? 'VAR_LOAD' : 'FIXED',
        ld: trainable ? (ldPort! & laneHit!) : null,
        cntValueIn: trainable ? cntPort : null,
        name: 'dq_idelay_$i',
      ).dataout;
      final iddr = XilinxIddr(
        c: iddrClk,
        d: delayed,
        r: reset,
        name: 'dq_iddr_$i',
      );
      q1Bits.add(iddr.q1);
      q2Bits.add(iddr.q2);
    }
    // Fabric bitslip: IDDR SAME_EDGE presents q1=rise[n], q2=fall[n-1].
    // Register previous captures and select alignment via a 2-bit select. On the
    // non-trainable build the select is the HARBOR_DDR_BITSLIP compile-time env
    // (default 0 = same-cycle pair, swept on hardware). On the trainable build
    // it is a runtime rotate register that advances by one on every train
    // BITSLIP pulse (the fabric twin of the ISERDESE2 glitch-free beat rotate),
    // so firmware can search the beat alignment against a written pattern.
    final q1PrevBits = Logic(name: 'q1_prev', width: dataBits);
    final q2PrevBits = Logic(name: 'q2_prev', width: dataBits);
    Sequential(clk, reset: reset, [
      q1PrevBits < q1Bits.rswizzle(),
      q2PrevBits < q2Bits.rswizzle(),
    ]);
    // beatWord = {fall, rise}: fall in the high half, rise in the low half.
    // Select index 0 = same-cycle, 1 = fall[n]+rise[n-1], 2 = both-prev,
    // 3 = fall+fallPrev.
    Logic beatFor(int sel) => switch (sel & 3) {
      0 => [q2Bits.rswizzle(), q1Bits.rswizzle()].swizzle(),
      1 => [q2Bits.rswizzle(), q1PrevBits].swizzle(),
      2 => [q2PrevBits, q1PrevBits].swizzle(),
      _ => [q2Bits.rswizzle(), q2PrevBits].swizzle(),
    };
    final Logic beatWord;
    if (bitslip != null) {
      final bitslipPort = addInput('bitslip', bitslip);
      // bitslipLane is accepted for interface parity with the ISERDESE2 per-lane
      // BITSLIP but the fabric re-pair is word-wide, so it does not select a
      // lane, register it as an input so the port exists and mark it unused.
      final _ = addInput(
        'bitslip_lane',
        bitslipLane!,
        width: bitslipLane.width,
      );
      final bitslipSelReg = Logic(name: 'bitslip_sel', width: 2);
      Sequential(clk, reset: reset, [
        If(bitslipPort, then: [bitslipSelReg < bitslipSelReg + 1]),
      ]);
      beatWord = mux(
        bitslipSelReg.eq(Const(0, width: 2)),
        beatFor(0),
        mux(
          bitslipSelReg.eq(Const(1, width: 2)),
          beatFor(1),
          mux(bitslipSelReg.eq(Const(2, width: 2)), beatFor(2), beatFor(3)),
        ),
      ).named('beat_word');
    } else {
      beatWord = beatFor(0).named('beat_word');
    }

    final assembler = DdrReadWordAssembler(
      clk,
      reset,
      beatWord: beatWord,
      rdStart: rdStart,
      beatSel: beatSel,
      windowOpen: windowOpen,
      dataBits: dataBits,
      name: 'rd_assembler',
    );
    rdData <= assembler.rdData;
    rdValid <= assembler.rdValid;

    // Logic-analyzer debug probe: PHY-internal fabric signals not visible on a
    // pad. MUST be fabric nets, NOT the ODDR Q outputs (those are IOB-bound and
    // fault nextpnr with "illegal fanout"). [4]=windowOpen (read-window pulse,
    // replaces the now-internal rdActive), [3]=wrActive (write burst driving),
    // [2]=windowOpen again (read-window pulse), [1]=beatHit (this cycle's DQ
    // carries the addressed write word), [0]=the write-data bit going INTO the
    // DQ ODDR (dqRise[0]). Fanned to Pmod pins by the controller for the DDR
    // bring-up LA.
    addOutput('dbg_probe', width: 5);
    // On the REALCLK probe, surface the (single, DDR3-tree-referenced)
    // IDELAYCTRL RDY on dbg_probe[4] for the LA (the calibration smoking gun),
    // the same RDY is read over MMIO via the controller STATUS register
    // (idelay_rdy). The ISERDESE2 Q1..Q8 activity is folded into bit[0].
    output('dbg_probe') <=
        [windowOpen, wrActive, windowOpen, beatHit, dqRise[0]].swizzle();
  }
}
