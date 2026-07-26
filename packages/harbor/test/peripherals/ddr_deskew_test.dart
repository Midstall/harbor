import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the PER-BIT DQ read DESKEW gating in [DdrPhyEcp5]
/// ([perBitDeskew], reg10 {broadcastBit, dqIndex}).
///
/// A single group-wide read tap (reg0 RDTAP) cannot align every DQ bit into the
/// DQS capture eye, the residual 2nd-beat per-DQ read scramble on the OrangeCrab
/// DLL-on path needs a PER-BIT delay. This gates the shared DELAYF MOVE/LOADN so
/// firmware walks ONE DQ's delay line at a time (selected by reg10), while a
/// broadcast mode (the reset default) preserves the old group-walk semantics so
/// existing firmware is unaffected.
///
/// The DELAYF/IDDRX2DQA leaves are X in sim (DQS-strobed, no ROHD model), so the
/// eye landing is HW-only, but the per-bit MOVE GATE is plain fabric and
/// sim-visible via the [DdrPhyEcp5.dqMoveDbg] mirror (one bit per DQ). This test
/// asserts a driven MOVE reaches ALL bits in broadcast mode and ONLY the selected
/// bit when a DQ index is programmed.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, dMove, dqSel;
  late DdrPhyEcp5 phy;

  // reg10 select = {broadcastBit(MSB), dqIndex}. 16 DQ -> dqIdxW = 5, so the
  // select is 6 bits and the broadcast bit is bit 5 (1<<5 = 0x20).
  const dqIdxW = 5; // (16).bitLength
  const bcast = 1 << dqIdxW; // 0x20

  Future<void> bringUp() async {
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');
    dMove = Logic(name: 'delay_move');
    dqSel = Logic(name: 'dq_deskew_sel', width: dqIdxW + 1);

    final padDq = LogicNet(name: 'pad_dq', width: 16);
    final padDqs = LogicNet(name: 'pad_dqs', width: 2);
    final padDqsN = LogicNet(name: 'pad_dqs_n', width: 2);

    phy = DdrPhyEcp5(
      clk,
      reset,
      cke: Const(0),
      csN: Const(1),
      cmd: Const(0, width: 3),
      ba: Const(0, width: 3),
      addr: Const(0, width: 14),
      odt: Const(0),
      resetN: Const(0),
      wrStart: Const(0),
      wrData: Const(0, width: 32),
      wrMask: Const(0, width: 4),
      beatSel: Const(0, width: 2),
      rdStart: Const(0),
      padDq: padDq,
      padDqs: padDqs,
      padDqsN: padDqsN,
      rowBits: 14,
      baBits: 3,
      dataBits: 16,
      clkMhz: 144, // DLL-on trained x2 path
      trainable: true,
      delayMove: dMove,
      perBitDeskew: true,
      dqDeskewSelect: dqSel,
    );

    await phy.build();
    dMove.inject(0);
    dqSel.inject(bcast); // broadcast (reset default)
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
  }

  int? val(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  test(
    'broadcast mode fans MOVE to every DQ bit (group walk preserved)',
    () async {
      await bringUp();
      dqSel.inject(bcast);
      dMove.inject(1);
      await clk.nextPosedge;
      // All 16 DQ move together in broadcast.
      expect(
        val(phy.dqMoveDbg),
        0xFFFF,
        reason:
            'broadcast (MSB set) must step every DQ DELAYF in lockstep - the '
            'existing group-walk semantics an old reg0-only firmware relies on',
      );
      dMove.inject(0);
      await clk.nextPosedge;
      expect(val(phy.dqMoveDbg), 0, reason: 'MOVE low reaches no bit');
      await Simulator.endSimulation();
    },
  );

  test('per-bit mode routes MOVE to only the selected DQ index', () async {
    await bringUp();

    // Select DQ 5 (lane 0), broadcast off.
    dqSel.inject(5);
    dMove.inject(1);
    await clk.nextPosedge;
    expect(
      val(phy.dqMoveDbg),
      1 << 5,
      reason: 'only DQ5 steps when reg10 selects index 5 (per-bit deskew)',
    );

    // Select DQ 12 (lane 1), broadcast off.
    dqSel.inject(12);
    await clk.nextPosedge;
    expect(
      val(phy.dqMoveDbg),
      1 << 12,
      reason:
          'only DQ12 steps when reg10 selects index 12 - independent '
          'per-bit walk on the other byte lane',
    );

    // MOVE low: no bit steps regardless of select.
    dMove.inject(0);
    await clk.nextPosedge;
    expect(val(phy.dqMoveDbg), 0, reason: 'no DQ steps while MOVE is low');

    await Simulator.endSimulation();
  });
}
