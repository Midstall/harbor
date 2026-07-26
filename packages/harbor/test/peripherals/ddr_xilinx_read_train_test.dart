import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('reg10 IDELAY write edge pulses LD once and latches the lane', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final regSel = Logic(width: 4)..inject(0);
    final wData = Logic(width: 32)..inject(0);
    final ctrlWrite = Logic()..inject(0);
    final ctrlWriteEdge = Logic()..inject(0);
    final dut = XilinxReadTrainRegs(
      clk,
      reset,
      regSel: regSel,
      wData: wData,
      ctrlWrite: ctrlWrite,
      ctrlWriteEdge: ctrlWriteEdge,
    );
    await dut.build();
    Simulator.setMaxSimTime(3000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    // reg10 VAR_LOAD: tap=0x11 [4:0], LD(bit5)=1, lane=5 [9:6].
    regSel.inject(10);
    wData.inject((0x11 << 0) | (1 << 5) | (5 << 6));
    ctrlWrite.inject(1);
    ctrlWriteEdge.inject(1);
    await clk.nextPosedge;
    ctrlWriteEdge.inject(0); // the edge lasts one cycle
    await clk.nextNegedge;
    expect(dut.idelayLd.value.toInt(), 1);
    expect(dut.idelayLane.value.toInt(), 5);
    expect(dut.idelayCntValue.value.toInt(), 0x11);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(
      dut.idelayLd.value.toInt(),
      0,
      reason: 'LD must be a single-cycle pulse',
    );
    await Simulator.endSimulation();
  });

  test('reg10 latches the absolute VAR_LOAD tap value on CNTVALUEIN', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final regSel = Logic(width: 4)..inject(0);
    final wData = Logic(width: 32)..inject(0);
    final ctrlWrite = Logic()..inject(0);
    final ctrlWriteEdge = Logic()..inject(0);
    final dut = XilinxReadTrainRegs(
      clk,
      reset,
      regSel: regSel,
      wData: wData,
      ctrlWrite: ctrlWrite,
      ctrlWriteEdge: ctrlWriteEdge,
    );
    await dut.build();
    Simulator.setMaxSimTime(3000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    // reg10 VAR_LOAD: tap=0x1F (max) [4:0], LD(bit5)=1, lane=3 [9:6].
    regSel.inject(10);
    wData.inject((0x1F << 0) | (1 << 5) | (3 << 6));
    ctrlWrite.inject(1);
    ctrlWriteEdge.inject(1);
    await clk.nextPosedge;
    ctrlWriteEdge.inject(0);
    await clk.nextNegedge;
    expect(dut.idelayCntValue.value.toInt(), 0x1F);
    expect(dut.idelayLane.value.toInt(), 3);
    expect(dut.idelayLd.value.toInt(), 1);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(
      dut.idelayLd.value.toInt(),
      0,
      reason: 'LD must be a single-cycle pulse',
    );
    // The latched tap value persists after the LD pulse falls.
    expect(dut.idelayCntValue.value.toInt(), 0x1F);
    await Simulator.endSimulation();
  });

  test(
    'reg11 slip pulses BITSLIP once; a held write does not re-pulse',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1);
      final regSel = Logic(width: 4)..inject(0);
      final wData = Logic(width: 32)..inject(0);
      final ctrlWrite = Logic()..inject(0);
      final ctrlWriteEdge = Logic()..inject(0);
      final dut = XilinxReadTrainRegs(
        clk,
        reset,
        regSel: regSel,
        wData: wData,
        ctrlWrite: ctrlWrite,
        ctrlWriteEdge: ctrlWriteEdge,
      );
      await dut.build();
      Simulator.setMaxSimTime(3000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      reset.inject(0);
      // reg11: lane=3, slip(bit4)=1. The write stays asserted (ctrlWrite high)
      // but the EDGE lasts a single cycle, so only one pulse must fire.
      regSel.inject(11);
      wData.inject((3 << 0) | (1 << 4));
      ctrlWrite.inject(1);
      ctrlWriteEdge.inject(1);
      await clk.nextPosedge;
      ctrlWriteEdge.inject(0);
      await clk.nextNegedge;
      expect(dut.bitslip.value.toInt(), 1);
      expect(dut.bitslipLane.value.toInt(), 3);
      // ctrlWrite still held high, but no new edge -> no re-pulse.
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(
        dut.bitslip.value.toInt(),
        0,
        reason: 'BITSLIP must not re-pulse while a write is merely held',
      );
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(dut.bitslip.value.toInt(), 0);
      await Simulator.endSimulation();
    },
  );

  test('reg12 WINDOW is a held level, resets to windowTapReset', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final regSel = Logic(width: 4)..inject(0);
    final wData = Logic(width: 32)..inject(0);
    final ctrlWrite = Logic()..inject(0);
    final ctrlWriteEdge = Logic()..inject(0);
    final dut = XilinxReadTrainRegs(
      clk,
      reset,
      regSel: regSel,
      wData: wData,
      ctrlWrite: ctrlWrite,
      ctrlWriteEdge: ctrlWriteEdge,
      windowTapReset: 2,
    );
    await dut.build();
    Simulator.setMaxSimTime(3000);
    unawaited(Simulator.run());

    await clk.nextNegedge;
    // Under reset the window tap holds its baked default.
    expect(
      dut.windowTap.value.toInt(),
      2,
      reason: 'reset value = baked window',
    );
    await clk.nextPosedge;
    reset.inject(0);
    // reg12: window tap = 7 [3:0]. It is a held level (not a pulse), so it
    // updates on the ctrlWrite cycle and stays.
    regSel.inject(12);
    wData.inject(7);
    ctrlWrite.inject(1);
    ctrlWriteEdge.inject(1);
    await clk.nextPosedge;
    ctrlWriteEdge.inject(0);
    ctrlWrite.inject(0);
    await clk.nextNegedge;
    expect(dut.windowTap.value.toInt(), 7, reason: 'window tap latches level');
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(dut.windowTap.value.toInt(), 7, reason: 'window tap is held');
    await Simulator.endSimulation();
  });
}
