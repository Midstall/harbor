/// Fabric 2:1 clock gearbox between the DDR3 controller LOGIC clock and the
/// SERDES/PHY clock, sitting at the 128-bit `o_phy_*` boundary between
/// [Ddr3Controller] and [Ddr3Phy].
///
/// WHY IT EXISTS
/// -------------
/// On the dense open-tools Spartan-7 (xc7s50) the controller command scheduler
/// (the wide 8-bank select mux) is congestion-limited: the routed logic only
/// holds ~56 MHz while the CK/4 controller clock runs ~83 MHz, a ~34% over-clock
/// that corrupts DDR under sustained fast DMA. The fix is to run the controller
/// LOGIC at CK/8 (~42 MHz, real margin) while keeping the DDR CK at 333 MHz and
/// the SERDES at CK/4 (a 7-series OSERDESE2/ISERDESE2 cannot serialize more than
/// DATA_WIDTH 8, so CK/8 on one primitive is impossible). This gearbox bridges
/// the two: the controller runs at CK/8, the PHY at CK/4, and the gearbox mux/
/// demuxes across the exact integer 2:1.
///
/// NOT A CDC
/// ---------
/// Both clocks are CLKOUTs off the SAME PLL VCO (phase-aligned, exact integer
/// 2:1), so this is a synchronous 2:1 mux/demux gated by a phase bit, not an
/// asynchronous FIFO. The phase bit is a serdes-clock (CK/4) flop that toggles
/// and is reset-aligned to 0 on the CK/4 edge that coincides with the CK/8 edge.
///
/// GEAR RATIO
/// ----------
/// [DdrParams.gearRatio] == 1 (the historical CK/4 controller) makes this module
/// a pure combinational pass-through, so it can be inserted unconditionally and
/// stay byte-identical. [DdrParams.gearRatio] == 2 (the CK/8 controller) engages
/// the 2:1 gearing. No other ratio is supported (a 7-series SERDES tops out at
/// DATA_WIDTH 8, so CK/8 controller + CK/4 SERDES is the only useful case).
///
/// WRITE PATH (controller @ CK/8 -> PHY @ CK/4)
/// -------------------------------------------
/// The controller holds each o_phy_* word stable for one CK/8 = two CK/4 ticks.
/// On the ACTIVE serdes tick ([writeDataPhase]) the gearbox forwards the whole
/// controller word verbatim (command + data + mask + tri controls + toggle). On
/// the BUBBLE serdes tick it drives a fully-idle beat: DESELECT command (all
/// per-slot cs_n forced high, every level line held), DQ/DQS tri controls forced
/// to high-Z, and DQS toggle forced low. So a single controller cycle drives at
/// most one CK/4 SERDES slot (one BL8), the other slot is idle: half the peak
/// command bandwidth, which is ample here (see the family notes).
///
/// The write DATA rides whatever controller cycle the controller's launch
/// pipeline places it on (the CWL launch is entirely inside the controller: the
/// PHY loads the command and data OSERDES on the SAME serdes edge with no
/// relative delay). The gearbox therefore treats data exactly like the command:
/// forwarded on the active tick, idle (DQ high-Z) on the bubble tick. See the
/// TIMING CAVEAT below for the one thing this does NOT fix.
///
/// READ PATH (PHY @ CK/4 -> controller @ CK/8)
/// ------------------------------------------
/// The ISERDES captures on every CK/4 tick (two captures per CK/8 cycle). The
/// gearbox latches the capture taken on [readCapturePhase] into a serdes-domain
/// register and holds it for the whole controller period, so the controller
/// samples a stable word on its CK/8 edge. [readCapturePhase] defaults to 1 (the
/// serdes tick immediately BEFORE the controller's sampling edge) so the held
/// value is settled at that edge. The exact capture phase is a bring-up knob
/// (the read window is retuned on hardware), hence a parameter.
///
/// SIDEBAND
/// --------
/// The odelay/idelay count-value + load pulses, bitslip, write-leveling-calib and
/// the PHY reset are calibration controls that change slowly relative to CK/4
/// (quasi-static), so they pass straight through on both ticks. They do not carry
/// per-CK data, so they need no slot treatment.
///
/// *** TIMING CAVEAT (read before wiring, T3) ***
/// -----------------------------------------------
/// This module faithfully maps controller cycle N onto CK/4 slot pair N and
/// inserts an idle bubble in the second slot. It does NOT, and cannot, change the
/// command-to-data or command-to-read CK SEPARATION that the controller itself
/// produces. Those separations ([Ddr3Controller] STAGE2_DATA_DEPTH and the read
/// delay) are computed in units of the SERDES DATAPATH cycle (a hard `/ 4`, i.e.
/// 4 CK per cycle). Running the UNMODIFIED controller at CK/8 makes every one of
/// those cycle-counted separations span 8 CK instead of 4, so a fixed CWL / CL
/// (a handful of CK, set by the DRAM) is no longer met. A 1-bit phase (4 CK of
/// resolution) cannot claw back a doubled multi-CK latency. Making the CK/8
/// controller launch writes/reads at the correct CK is a CONTROLLER change (make
/// the launch-depth / read-delay math datapath-ratio aware, or supply the gearbox
/// a per-cycle data-phase hint) and is explicitly out of scope for this isolated
/// gearbox. This module is proven against its own golden model; the end-to-end CK
/// alignment is the next task's job.
library;

import 'package:rohd/rohd.dart';

import 'ddr3_params.dart';

/// The controller/PHY `o_phy_*` boundary bridged as a synchronous 2:1 gearbox.
class Ddr3ControllerGearbox extends Module {
  final DdrParams params;

  /// Which of the two CK/4 ticks in a CK/8 period carries the controller word
  /// on the write path (the other tick is an idle bubble). 0 = the tick
  /// coincident with the CK/8 edge (the command boundary).
  final int writeDataPhase;

  /// Which CK/4 capture is handed to the controller on the read path. 1 = the
  /// tick just before the controller's CK/8 sampling edge (held value settled).
  final int readCapturePhase;

  int get gearRatio => params.gearRatio;
  int get serdes => params.serdesRatio;
  int get lanes => params.lanes;

  /// DQ pins across all lanes.
  int get dq => params.dqBits * lanes;

  /// Command word bit-length per SERDES slot: cs_n + {ras,cas,we} + odt + cke +
  /// reset_n (the 4 control lines + 3 command bits) + bank + row/col address.
  /// Mirrors [Ddr3Controller.cmdLen].
  int get cmdLen => 4 + 3 + params.baBits + params.rowBits;

  Ddr3ControllerGearbox(
    this.params, {
    required Logic controllerClk,
    required Logic serdesClk,
    required Logic rstN,
    // --- controller (CK/8) o_phy_* outputs, entering the gearbox ---
    required Logic cPhyCmd,
    required Logic cPhyDqsTriControl,
    required Logic cPhyDqTriControl,
    required Logic cPhyToggleDqs,
    required Logic cPhyData,
    required Logic cPhyDm,
    required Logic cPhyReset,
    required Logic cPhyOdelayDataCntvaluein,
    required Logic cPhyOdelayDqsCntvaluein,
    required Logic cPhyIdelayDataCntvaluein,
    required Logic cPhyIdelayDqsCntvaluein,
    required Logic cPhyOdelayDataLd,
    required Logic cPhyOdelayDqsLd,
    required Logic cPhyIdelayDataLd,
    required Logic cPhyIdelayDqsLd,
    required Logic cPhyBitslip,
    required Logic cPhyWriteLevelingCalib,
    // --- PHY (CK/4) iserdes returns, entering the gearbox ---
    required Logic pIserdesData,
    required Logic pIserdesDqs,
    required Logic pIserdesBitslipReference,
    this.writeDataPhase = 0,
    this.readCapturePhase = 1,
    super.name = 'ddr3_gearbox',
  }) : assert(
         params.gearRatio == 1 || params.gearRatio == 2,
         'gearbox supports gearRatio 1 (transparent) or 2 only',
       ),
       assert(
         writeDataPhase == 0 || writeDataPhase == 1,
         'writeDataPhase is a single phase bit',
       ),
       assert(
         readCapturePhase == 0 || readCapturePhase == 1,
         'readCapturePhase is a single phase bit',
       ) {
    // The controller clock is only meaningful to the CONTROLLER; the gearbox
    // itself lives in the serdes (CK/4) domain and encodes the CK/8 boundary in
    // the phase bit. The port is kept so T3 can wire the controller clock and so
    // the interface is stable across gearRatio.
    addInput('i_controller_clk', controllerClk);
    serdesClk = addInput('i_serdes_clk', serdesClk);
    rstN = addInput('i_rst_n', rstN);

    final cmdW = cmdLen * serdes;
    cPhyCmd = addInput('i_c_phy_cmd', cPhyCmd, width: cmdW);
    cPhyDqsTriControl = addInput('i_c_phy_dqs_tri_control', cPhyDqsTriControl);
    cPhyDqTriControl = addInput('i_c_phy_dq_tri_control', cPhyDqTriControl);
    cPhyToggleDqs = addInput('i_c_phy_toggle_dqs', cPhyToggleDqs);
    cPhyData = addInput('i_c_phy_data', cPhyData, width: params.wbDataBits);
    cPhyDm = addInput('i_c_phy_dm', cPhyDm, width: params.wbSelBits);
    cPhyReset = addInput('i_c_phy_reset', cPhyReset);
    cPhyOdelayDataCntvaluein = addInput(
      'i_c_phy_odelay_data_cntvaluein',
      cPhyOdelayDataCntvaluein,
      width: 5,
    );
    cPhyOdelayDqsCntvaluein = addInput(
      'i_c_phy_odelay_dqs_cntvaluein',
      cPhyOdelayDqsCntvaluein,
      width: 5,
    );
    cPhyIdelayDataCntvaluein = addInput(
      'i_c_phy_idelay_data_cntvaluein',
      cPhyIdelayDataCntvaluein,
      width: 5,
    );
    cPhyIdelayDqsCntvaluein = addInput(
      'i_c_phy_idelay_dqs_cntvaluein',
      cPhyIdelayDqsCntvaluein,
      width: 5,
    );
    cPhyOdelayDataLd = addInput(
      'i_c_phy_odelay_data_ld',
      cPhyOdelayDataLd,
      width: lanes,
    );
    cPhyOdelayDqsLd = addInput(
      'i_c_phy_odelay_dqs_ld',
      cPhyOdelayDqsLd,
      width: lanes,
    );
    cPhyIdelayDataLd = addInput(
      'i_c_phy_idelay_data_ld',
      cPhyIdelayDataLd,
      width: lanes,
    );
    cPhyIdelayDqsLd = addInput(
      'i_c_phy_idelay_dqs_ld',
      cPhyIdelayDqsLd,
      width: lanes,
    );
    cPhyBitslip = addInput('i_c_phy_bitslip', cPhyBitslip, width: lanes);
    cPhyWriteLevelingCalib = addInput(
      'i_c_phy_write_leveling_calib',
      cPhyWriteLevelingCalib,
    );

    pIserdesData = addInput('i_p_iserdes_data', pIserdesData, width: dq * 8);
    pIserdesDqs = addInput('i_p_iserdes_dqs', pIserdesDqs, width: lanes * 8);
    pIserdesBitslipReference = addInput(
      'i_p_iserdes_bitslip_reference',
      pIserdesBitslipReference,
      width: lanes * 8,
    );

    // --- PHY-facing outputs (CK/4) ---
    final oCmd = addOutput('o_p_phy_cmd', width: cmdW);
    final oDqsTri = addOutput('o_p_phy_dqs_tri_control');
    final oDqTri = addOutput('o_p_phy_dq_tri_control');
    final oToggle = addOutput('o_p_phy_toggle_dqs');
    final oData = addOutput('o_p_phy_data', width: params.wbDataBits);
    final oDm = addOutput('o_p_phy_dm', width: params.wbSelBits);
    final oReset = addOutput('o_p_phy_reset');
    final oOdDataCnt = addOutput('o_p_phy_odelay_data_cntvaluein', width: 5);
    final oOdDqsCnt = addOutput('o_p_phy_odelay_dqs_cntvaluein', width: 5);
    final oIdDataCnt = addOutput('o_p_phy_idelay_data_cntvaluein', width: 5);
    final oIdDqsCnt = addOutput('o_p_phy_idelay_dqs_cntvaluein', width: 5);
    final oOdDataLd = addOutput('o_p_phy_odelay_data_ld', width: lanes);
    final oOdDqsLd = addOutput('o_p_phy_odelay_dqs_ld', width: lanes);
    final oIdDataLd = addOutput('o_p_phy_idelay_data_ld', width: lanes);
    final oIdDqsLd = addOutput('o_p_phy_idelay_dqs_ld', width: lanes);
    final oBitslip = addOutput('o_p_phy_bitslip', width: lanes);
    final oWlCalib = addOutput('o_p_phy_write_leveling_calib');

    // --- controller-facing read returns (CK/8) ---
    final oIserData = addOutput('o_c_iserdes_data', width: dq * 8);
    final oIserDqs = addOutput('o_c_iserdes_dqs', width: lanes * 8);
    final oIserBs = addOutput(
      'o_c_iserdes_bitslip_reference',
      width: lanes * 8,
    );

    // Sideband (quasi-static) always passes straight through, both ratios.
    oReset <= cPhyReset;
    oOdDataCnt <= cPhyOdelayDataCntvaluein;
    oOdDqsCnt <= cPhyOdelayDqsCntvaluein;
    oIdDataCnt <= cPhyIdelayDataCntvaluein;
    oIdDqsCnt <= cPhyIdelayDqsCntvaluein;
    oOdDataLd <= cPhyOdelayDataLd;
    oOdDqsLd <= cPhyOdelayDqsLd;
    oIdDataLd <= cPhyIdelayDataLd;
    oIdDqsLd <= cPhyIdelayDqsLd;
    oBitslip <= cPhyBitslip;
    oWlCalib <= cPhyWriteLevelingCalib;

    if (gearRatio == 1) {
      // Transparent: the controller clock IS the SERDES CLKDIV, no gearing.
      // Pure combinational wire-through keeps the design byte-identical.
      oCmd <= cPhyCmd;
      oDqsTri <= cPhyDqsTriControl;
      oDqTri <= cPhyDqTriControl;
      oToggle <= cPhyToggleDqs;
      oData <= cPhyData;
      oDm <= cPhyDm;
      oIserData <= pIserdesData;
      oIserDqs <= pIserdesDqs;
      oIserBs <= pIserdesBitslipReference;
      return;
    }

    // --- gearRatio == 2: synchronous 2:1 mux/demux ---
    final reset = ~rstN;

    // Phase bit: toggles on the SERDES clock, reset-aligned to 0 on the CK/4
    // edge coincident with the CK/8 edge. phase == 0 is the controller-boundary
    // tick, phase == 1 is the second tick of the pair.
    final phase = Logic(name: 'serdes_phase');
    Sequential(serdesClk, reset: reset, [phase < ~phase]);

    // The write-active tick and the read-capture tick, resolved against the
    // phase bit (compile-time constant selection, no extra logic).
    final writeActive = writeDataPhase == 0 ? ~phase : phase;
    final readCapEn = readCapturePhase == 0 ? ~phase : phase;

    // DESELECT command: force every SERDES slot's cs_n high while holding all
    // level lines the controller drove. cs_n is the MSB of each cmdLen-wide slot
    // (see [Ddr3Controller._slotCmd]). ORing the controller word with this mask
    // deselects the DRAM for the whole bubble tick, keeping cke/reset_n/odt intact
    // so a DESELECT never disturbs a level during init or refresh.
    var maskBig = BigInt.zero;
    for (var j = 0; j < serdes; j++) {
      maskBig |= BigInt.one << (j * cmdLen + cmdLen - 1);
    }
    final csDeselectMask = Const(maskBig, width: cmdW);
    final cmdBubble = cPhyCmd | csDeselectMask;

    // WRITE: forward the controller word on the active tick, idle bubble on the
    // other. Command / tri controls / toggle are gated; data + mask ride through
    // (DQ is tri-stated on the bubble tick, so the held data never reaches a pad).
    oCmd <= mux(writeActive, cPhyCmd, cmdBubble);
    oDqTri <= mux(writeActive, cPhyDqTriControl, Const(1)); // high-Z on bubble
    oDqsTri <= mux(writeActive, cPhyDqsTriControl, Const(1));
    oToggle <= mux(writeActive, cPhyToggleDqs, Const(0)); // no DQS on bubble
    oData <= cPhyData;
    oDm <= cPhyDm;

    // READ: capture the selected CK/4 tick and hold it across the CK/8 period so
    // the controller samples a stable word. Serdes-domain register, updated only
    // on the read-capture tick.
    final capData = Logic(name: 'iserdes_cap_data', width: dq * 8);
    final capDqs = Logic(name: 'iserdes_cap_dqs', width: lanes * 8);
    final capBs = Logic(name: 'iserdes_cap_bs', width: lanes * 8);
    Sequential(serdesClk, reset: reset, [
      If(
        readCapEn,
        then: [
          capData < pIserdesData,
          capDqs < pIserdesDqs,
          capBs < pIserdesBitslipReference,
        ],
      ),
    ]);
    oIserData <= capData;
    oIserDqs <= capDqs;
    oIserBs <= capBs;
  }
}
