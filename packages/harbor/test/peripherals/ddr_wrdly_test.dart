import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the firmware-swept write-DQS-delay (reg7 WRDLY) write-pointer
/// stepper in [DdrPhyEcp5].
///
/// The DQSBUFM leaf has no sim model (its DQSW/DQSW270 strobes and the write
/// pointer are X), but the per-lane write-pointer STEPPER that drives WRLOADN /
/// WRMOVE is plain sclk-domain fabric and IS sim-visible. This test forces a
/// firmware WRDLY tap and toggles the apply line directly on the PHY, then
/// asserts the stepper reloads the write pointer to min (one WRLOADN pulse) and
/// issues exactly N WRMOVE pulses (N = the firmware tap). N WRMOVE pulses move
/// the DQSBUFM write pointer N steps, which shifts the DQSW/DQSW270 write strobe
/// the normal ODDRX2DQA / ODDRX2DQSB write datapath launches off, so the write
/// alignment moves with the firmware tap. The strobe DATA itself is X (DQSBUFM
/// leaf). Only the control path is checked here, the alignment is proven on
/// hardware by reading back a written pattern.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, wrDly, wrDlyApply;
  late DdrPhyEcp5 phy;

  Future<void> bringUp() async {
    // clk is the CK-rate edge clock, the PHY divides it to sclk = CK/2.
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');
    wrDly = Logic(name: 'wr_dly', width: 8); // 4 bits per lane, 2 lanes
    wrDlyApply = Logic(name: 'wr_dly_apply');

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
      wrDlyTrainable: true,
      wrDly: wrDly,
      wrDlyApply: wrDlyApply,
    );

    await phy.build();
    wrDly.inject(0);
    wrDlyApply.inject(0);
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    // sclk = CK/2, so step CK posedges to clear the sclk reset synchronizer
    // before driving any apply (otherwise a reset-window apply edge mis-steps).
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
    }
  }

  int? bit(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  // Toggle wr_dly_apply and count the lane-0 WRMOVE pulses + lane-0 WRLOADN
  // assertions until the stepper settles (a quiet window with no more moves).
  Future<({int moves, int loads})> applyAndCount(int tap) async {
    wrDly.inject(tap | (tap << 4)); // same tap to both lanes
    // Flip the apply toggle (the PHY edge-detects it).
    final cur = bit(wrDlyApply) ?? 0;
    wrDlyApply.inject(cur ^ 1);

    // The stepper holds WRMOVE high for one sclk cycle PER pointer step (the
    // DQSBUFM moves one step per clock edge WRMOVE is high, the litedram/WL
    // convention), and sclk = CK/2, so each step shows up as TWO consecutive
    // CK-rate high samples. Count CK-high samples and halve to get the step count.
    // WRLOADN (active-low) is the same: one reload = two CK-low samples.
    var moveSamples = 0;
    var loadSamples = 0;
    var quiet = 0;
    var started = false;
    // The apply toggle takes a couple dozen CK cycles to cross the sclk
    // synchronizer + edge detect before the reload/step begins, so only start
    // the quiet-window early-exit AFTER the first activity is seen.
    for (var i = 0; i < 400 && (!started || quiet < 16); i++) {
      await clk.nextPosedge;
      final mv = bit(phy.wrMoveDbg);
      final ld = bit(phy.wrLoadnDbg);
      final mv0 = mv == null ? 0 : (mv & 0x1);
      final ld0 = ld == null ? 1 : (ld & 0x1);
      if (mv0 == 1) {
        moveSamples++;
        quiet = 0;
        started = true;
      } else if (ld0 == 0) {
        loadSamples++;
        quiet = 0;
        started = true;
      } else {
        quiet++;
      }
    }
    // Halve the CK-rate samples to recover the sclk-cycle step/reload counts.
    return (moves: (moveSamples / 2).round(), loads: (loadSamples / 2).round());
  }

  test(
    'reg7 WRDLY apply reloads the write pointer and steps it N WRMOVE pulses',
    () async {
      await bringUp();

      // Tap 5: expect one WRLOADN reload then exactly 5 WRMOVE pulses.
      final r5 = await applyAndCount(5);
      expect(
        r5.loads,
        greaterThanOrEqualTo(1),
        reason: 'WRLOADN reload-to-min should pulse on a WRDLY apply',
      );
      expect(
        r5.moves,
        5,
        reason: 'WRDLY tap 5 should issue exactly 5 WRMOVE pulses',
      );

      await Simulator.endSimulation();
    },
  );

  test('a second WRDLY apply re-reloads and re-steps to the new tap', () async {
    await bringUp();

    final r3 = await applyAndCount(3);
    expect(r3.moves, 3, reason: 'first WRDLY tap 3 -> 3 WRMOVE pulses');

    // Let it settle, then apply a different tap.
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    final r7 = await applyAndCount(7);
    expect(
      r7.loads,
      greaterThanOrEqualTo(1),
      reason: 'second apply must reload to min first',
    );
    expect(r7.moves, 7, reason: 'second WRDLY tap 7 -> 7 WRMOVE pulses');

    await Simulator.endSimulation();
  });

  test('WRDLY tap 0 reloads to min with no WRMOVE steps', () async {
    await bringUp();
    final r0 = await applyAndCount(0);
    expect(
      r0.loads,
      greaterThanOrEqualTo(1),
      reason: 'tap 0 still reloads the pointer to min',
    );
    expect(r0.moves, 0, reason: 'tap 0 needs no WRMOVE steps');
    await Simulator.endSimulation();
  });

  test('WRDLY tap 15 (4-bit pointer max) steps exactly 15 - the additive '
      'target is saturated, no wrap/hang', () async {
    // Regression for the additive-WRDLY clamp: fwTarget = wlBasePos + fwTap is
    // 5-bit (can reach 30) but [pos] is a 4-bit pointer (0..15). Without the
    // saturation, a target > 15 would step pos past 15, wrapping 15->0 under the
    // 5-bit comparator and never exiting (an infinite WRMOVE loop). On this
    // wrDlyTrainable-only build wlBasePos == 0, so tap 15 lands exactly at the
    // 4-bit max: the stepper must issue EXACTLY 15 moves and then STOP (not wrap
    // to 0 and run forever). If the stepper hung, [moves] would be far > 15.
    await bringUp();
    final r15 = await applyAndCount(15);
    expect(
      r15.loads,
      greaterThanOrEqualTo(1),
      reason: 'tap 15 still reloads the pointer to min',
    );
    expect(
      r15.moves,
      15,
      reason:
          'WRDLY tap 15 must step exactly to the 4-bit pointer max (15) '
          'and exit - a higher move count means the additive target overran '
          'the 4-bit pos and wrapped (the clamp regression)',
    );
    await Simulator.endSimulation();
  });
}
