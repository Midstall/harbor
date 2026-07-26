import 'package:rohd/rohd.dart';

/// Xilinx read-training MMIO register decode: turns the DDR train-control
/// window writes into per-lane IDELAYE2 controls (an absolute VAR_LOAD tap +
/// LD pulse + lane) and a beat-align BITSLIP pulse. Mirrors the ECP5 stepper
/// decode idiom in `ddr.dart` (a `Case(regSel, ...)` over the strided control
/// registers) but produces the Xilinx primitive controls. Extracted as a
/// standalone [Module] so the register decode is unit-testable against driven
/// inputs.
///
/// The IDELAYE2 is driven in IDELAY_TYPE="VAR_LOAD" (the reliable UberDDR3
/// absolute-tap mode): firmware writes a 5-bit tap value and pulses LD to load
/// it in ONE write, instead of pulsing CE/INC to step. CE/INC are gone.
///
/// Register map (chosen ABOVE the ECP5 reg0..9 block so the two decode idioms
/// never collide. The `+N*8` byte stride is decoded on the bus offset bits
/// [6:3] in `ddr.dart`, so reg10 lands at +0x50, reg11 at +0x58):
///   reg10 (@ +0x50) IDELAY: `[4:0]` tap value (CNTVALUEIN), `[5]` LD,
///     `[9:6]` lane.
///     On [ctrlWriteEdge] with `[5]` set: latch the lane + the 5-bit tap value,
///     and pulse LD one cycle to load the absolute tap into the addressed lane's
///     IDELAYE2 CNTVALUEIN.
///   reg11 (@ +0x58) BITSLIP: `[3:0]` lane, `[4]` slip.
///     On [ctrlWriteEdge] with `[4]` set: latch the lane, pulse BITSLIP one
///     cycle.
///   reg12 (@ +0x60) WINDOW: `[3:0]` window tap (which rd_pipe stage the read
///     window opens on). LEVEL register (not a pulse): the latched value drives
///     a runtime mux over the ISERDESE2 read pipe so firmware can walk the
///     ctrl83 capture cycle (the coarse "which controller cycle does the BL8
///     line land" knob) WITHOUT a rebuild. Resets to [windowTapReset] so a
///     normal boot comes up at the baked window.
///
/// The LD/BITSLIP outputs are one-cycle pulses gated on the write EDGE, so a
/// held control write (bus stb high across multiple cycles until ack) fires
/// exactly one action, the same one-shot contract the ECP5 SET/LOAD/RDMOVE
/// toggles have. The WINDOW output is a held level (last-written tap).
class XilinxReadTrainRegs extends Module {
  Logic get idelayLd => output('idelay_ld');
  Logic get idelayCntValue => output('idelay_cntvalue');
  Logic get idelayLane => output('idelay_lane');
  Logic get bitslip => output('bitslip');
  Logic get bitslipLane => output('bitslip_lane');
  Logic get windowTap => output('window_tap');
  Logic get refl => output('refresh_level');

  XilinxReadTrainRegs(
    Logic clk,
    Logic reset, {
    required Logic regSel,
    required Logic wData,
    required Logic ctrlWrite,
    required Logic ctrlWriteEdge,
    int dataBits = 16,
    // The window-tap register reset value: a normal boot comes up at this
    // ISERDESE2 read-pipe stage without a firmware sweep (the baked eye).
    int windowTapReset = 2,
    super.name = 'xil_rdtrain',
  }) {
    final laneW = dataBits <= 1 ? 1 : (dataBits - 1).bitLength;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    regSel = addInput('reg_sel', regSel, width: 4);
    wData = addInput('w_data', wData, width: 32);
    ctrlWrite = addInput('ctrl_write', ctrlWrite);
    ctrlWriteEdge = addInput('ctrl_write_edge', ctrlWriteEdge);

    final ld = addOutput('idelay_ld');
    final cnt = addOutput('idelay_cntvalue', width: 5);
    final ilane = addOutput('idelay_lane', width: laneW);
    final slip = addOutput('bitslip');
    final blane = addOutput('bitslip_lane', width: laneW);
    final wtap = addOutput('window_tap', width: 4);
    // reg13 REFRESH LEVEL (@ +0x68): firmware-programmable refresh-rate shift for
    // the sequencer's dynamic tREFI. 0 = nominal 7.8us, 1 = 2x (3.9us), 2 = 4x
    // (1.95us). Resets to 2 (4x, high-temp-safe) so retention holds from the first
    // cycle even before firmware writes it. The FSBL sets it explicitly and Linux
    // can retune it (down when cool for bandwidth). The openXC7 toolchain has no
    // XADC Bel, so the die-temperature source is firmware, not the on-die sensor.
    final refl = addOutput('refresh_level', width: 2);

    final ldReg = Logic(name: 'ld_reg');
    final cntReg = Logic(name: 'cnt_reg', width: 5);
    final ilaneReg = Logic(name: 'ilane_reg', width: laneW);
    final slipReg = Logic(name: 'slip_reg');
    final blaneReg = Logic(name: 'blane_reg', width: laneW);
    // Window-tap LEVEL register: resets to the baked window so a normal boot is
    // calibrated. Firmware overwrites it to sweep the ctrl83 capture cycle.
    final wtapReg = Logic(name: 'wtap_reg', width: 4);
    // Refresh-level LEVEL register (reg13), resets to 2 (4x, safe).
    final reflReg = Logic(name: 'refl_reg', width: 2);

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        // The window tap resets to the baked value, the refresh level to 2 (4x), all
        // other regs reset to 0.
        wtapReg: windowTapReset & 0xF,
        reflReg: Const(2, width: 2),
      },
      [
        // Pulses default low each cycle (one-shot on the write edge).
        ldReg < 0,
        slipReg < 0,
        If(
          ctrlWrite,
          then: [
            Case(regSel, [
              CaseItem(Const(10, width: 4), [
                // reg10: [4:0] tap value, [5] LD, [9:6] lane.
                cntReg < wData.slice(4, 0),
                ilaneReg < wData.slice(6 + laneW - 1, 6),
                If(ctrlWriteEdge & wData[5], then: [ldReg < 1]),
              ]),
              CaseItem(Const(11, width: 4), [
                blaneReg < wData.slice(laneW - 1, 0),
                If(ctrlWriteEdge & wData[4], then: [slipReg < 1]),
              ]),
              CaseItem(Const(12, width: 4), [
                // reg12 WINDOW: [3:0] = ctrl83 read-pipe tap (held level).
                wtapReg < wData.slice(3, 0),
              ]),
              CaseItem(Const(13, width: 4), [
                // reg13 REFRESH LEVEL: [1:0] = refresh-rate shift (held level).
                reflReg < wData.slice(1, 0),
              ]),
            ]),
          ],
        ),
      ],
    );

    ld <= ldReg;
    cnt <= cntReg;
    ilane <= ilaneReg;
    slip <= slipReg;
    blane <= blaneReg;
    wtap <= wtapReg;
    refl <= reflReg;
  }
}
