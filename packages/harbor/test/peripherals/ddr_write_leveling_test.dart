import 'dart:async';

import 'package:harbor/src/peripherals/ddr.dart';
import 'package:harbor/src/peripherals/ddr_sequencer.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the JEDEC DDR3 write-leveling FSM in [DdrSequencer].
///
/// The DQSBUFM / DQS / DQ leaves have no sim model (they are X) and DQ/DQS are
/// inout pads ROHD cannot co-simulate, so the WL FEEDBACK loop itself is
/// hardware-verified (like the read path). But the WL FSM CONTROL logic: the
/// MR1 A7 enable/disable MRS commands, the per-lane delay-step counter, the
/// lane loop, the feedback-sample register, the trained-delay latch, and the
/// done/exit handshake, is plain sclk-domain fabric and IS sim-visible. This
/// test drives the sequencer directly, FORCES the WL feedback to transition
/// 0->1 at a KNOWN delay tap, and asserts the FSM latches that tap and exits
/// WL. It mirrors litex `sdram_write_leveling_scan` (liblitedram/sdram.c): the
/// trained delay is the feedback 0->1 transition (DQS aligned to CK).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, req, we, reqAddr, reqData, reqSel, wlFeedback;
  late DdrSequencer seq;

  // A small clkMhz keeps the JEDEC real-time waits (tWLMRD/tWLDQSEN) to a few
  // cycles so the sim completes quickly while the FSM walks every state.
  Future<void> bringUp({required int taps}) async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    req = Logic(name: 'req');
    we = Logic(name: 'we');
    reqAddr = Logic(name: 'req_addr', width: 32);
    reqData = Logic(name: 'req_data', width: 32);
    reqSel = Logic(name: 'req_sel', width: 4);
    wlFeedback = Logic(name: 'wl_feedback');

    seq = DdrSequencer(
      clk,
      reset,
      req,
      we,
      reqAddr,
      reqData,
      reqSel,
      wlFeedback: wlFeedback,
      config: const HarborDdrConfig.orangeCrab(),
      clkMhz: 2, // small: JEDEC us/ns waits collapse to a handful of cycles
      writeLevel: true,
      wlDelayTaps: taps,
    );

    await seq.build();
    for (final s in [req, we, reqAddr, reqData, reqSel, wlFeedback]) {
      s.inject(0);
    }
    reset.inject(1);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
  }

  int? bit(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  test('WL FSM enables MR1 A7, latches the trained tap at the feedback 0->1 '
      'transition, and exits', () async {
    await bringUp(taps: 8);

    // The DDR command for MRS is {ras_n,cas_n,we_n} = 000 (Ddr3Cmd.mrs), cs_n
    // low. We watch for an MRS to MR1 (ba == 1) while wl_en is asserted (entry,
    // A7=1) and after the sweep (exit, A7=0). We also watch wl_en, wl_strobe,
    // the per-lane wl_lane, and the trained-tap latch.
    //
    // Feedback model: hold feedback 0 until the strobe at a KNOWN tap, then
    // drive it 1 so the FSM sees the 0->1 transition there. We pick tap 3 for
    // lane 0 and tap 5 for lane 1 (the OrangeCrab x16 part has 2 byte lanes).
    const lane0Tap = 3;
    const lane1Tap = 5;

    var sawWlEn = false;
    var sawMrsWlEnter = false; // MRS to MR1 while wl_en high
    var sawStrobe = false;
    var wlEnEverDropped = false;
    var doneIdx = -1;

    // Track the per-lane strobe count so we can flip feedback at the chosen tap.
    // The FSM pulses wl_delay_inc once per tap step, count incs per lane to know
    // the current tap, and assert feedback on the strobe at the target tap.
    final incCount = <int, int>{0: 0, 1: 0};

    const maxCycles = 4000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final wlEn = bit(seq.wlEn);
      final strobe = bit(seq.wlStrobe);
      final lane = bit(seq.wlLane) ?? 0;
      final cmd = bit(seq.cmd);
      final csN = bit(seq.csN);
      final ba = bit(seq.ba);
      final rst = bit(seq.wlDelayRst);
      final inc = bit(seq.wlDelayInc);
      final done = bit(seq.wlDone);

      if (wlEn == 1) sawWlEn = true;
      if (sawWlEn && wlEn == 0) wlEnEverDropped = true;

      // MRS (cmd 000) to MR1 (ba==1) with cs_n low.
      final isMrsMr1 = csN == 0 && cmd == 0 && ba == 1;
      if (isMrsMr1 && wlEn == 1) sawMrsWlEnter = true;
      // The exit MRS is issued at scan completion. wl_en may still read high the
      // exact cycle the command is registered, so accept an MR1 MRS seen at or
      // after wl_en has been high (the EXIT one differs by A7, not observable on
      // ba). Treat any MR1 MRS after the first as the exit handshake proxy via
      // wl_done rising. We assert wl_done below as the real exit signal.

      // Reset clears the per-lane inc counter to track taps from min.
      if (rst == 1) incCount[lane] = 0;
      if (inc == 1) incCount[lane] = (incCount[lane] ?? 0) + 1;

      // Drive the feedback: assert 1 once we are at/after the target tap for the
      // current lane, on the strobe cycle, so the FSM samples a 0->1 transition
      // exactly at the target tap.
      if (strobe == 1) {
        sawStrobe = true;
        final curTap = incCount[lane] ?? 0;
        final target = lane == 0 ? lane0Tap : lane1Tap;
        wlFeedback.inject(curTap >= target ? 1 : 0);
      } else {
        // Between strobes hold feedback low (the FSM samples it at sub-step 2,
        // one cycle after the strobe, keep it asserted through the sample by
        // re-driving on the strobe and leaving it until the next strobe). Keep
        // it whatever it was so the post-strobe sample sees the strobe value.
      }

      if (done == 1 && doneIdx < 0) doneIdx = i;
      if (done == 1) break;
    }

    // The FSM ran the full WL phase.
    expect(
      sawWlEn,
      isTrue,
      reason: 'wl_en never asserted (WL phase never ran)',
    );
    expect(
      sawMrsWlEnter,
      isTrue,
      reason: 'no MRS to MR1 while wl_en high (WL entry / MR1 A7=1 missing)',
    );
    expect(
      sawStrobe,
      isTrue,
      reason: 'wl_strobe never pulsed (no WL DQS pulse)',
    );
    expect(
      doneIdx,
      greaterThanOrEqualTo(0),
      reason: 'wl_done never rose (WL FSM never exited to normal operation)',
    );
    expect(
      wlEnEverDropped,
      isTrue,
      reason:
          'wl_en never dropped (WL phase never exited / MR1 A7 not cleared)',
    );

    // The trained tap for each lane is latched into wl_trained (4 bits/lane).
    final trained = bit(seq.wlTrained);
    expect(trained, isNotNull, reason: 'wl_trained is X after WL');
    final lane0 = trained! & 0xF;
    final lane1 = (trained >> 4) & 0xF;
    expect(
      lane0,
      lane0Tap,
      reason: 'lane 0 trained tap should be the feedback 0->1 transition tap',
    );
    expect(
      lane1,
      lane1Tap,
      reason: 'lane 1 trained tap should be the feedback 0->1 transition tap',
    );

    // WITNESS bitmap: reg6-exported per-tap voted feedback for the LAST lane
    // scanned (lane 1, target tap 5). The feedback model drives 1 at taps >= 5,
    // so the map records low at taps 0..4 and high at taps 5..7 (a clean
    // 0..01..1 ramp). This is the exact evidence the FSBL reads to distinguish a
    // real WL edge (this ramp) from an RTL feedback-path fault (all-0 / all-1).
    final fbMap = bit(seq.wlFbMap);
    expect(fbMap, isNotNull, reason: 'wl_fb_map is X after WL');
    // The FSM STOPS the lane sweep the moment it latches the 0->1 edge, so the
    // witness map records taps 0..transition: bits 0..4 low, bit 5 (the
    // transition tap) high. The FSBL uses exactly this shape: a map that is
    // NON-ZERO with its highest set bit == the trained tap means the WL edge is
    // real. An ALL-ZERO map means the feedback never flipped (RTL fault).
    expect(
      fbMap! & 0x1F,
      0,
      reason: 'witness map: feedback must read low below the transition tap',
    );
    expect(
      (fbMap >> 5) & 0x1,
      0x1,
      reason:
          'witness map: feedback must read high at the transition tap (the '
          '0->1 edge the FSBL uses to confirm the WL edge exists)',
    );
    expect(
      fbMap,
      isNot(0),
      reason: 'witness map must be non-zero when a real WL edge was found',
    );

    await Simulator.endSimulation();
  });

  test('WL majority-vote converges on NOISY feedback (the determinism fix)', () async {
    // The OLD WL sampled the feedback ONCE at a single DQS edge, so a marginal
    // feedback that reads high on some ticks and low on others within the strobe
    // window would land the trained tap on whichever value the one sample caught:
    // jitter across builds. The MAJORITY VOTE accumulates the feedback over the
    // whole settled strobe window (sub-step 1) and decides by majority, so a
    // marginal-but-majority-high feedback converges DETERMINISTICALLY.
    //
    // Model: below the target tap feedback is LOW (0 votes -> maj 0). At/above the
    // target it is NOISY: high on 2 of every 3 strobe ticks (a 2/3 duty that a
    // single sample could catch as 0 or 1, but votes a clear majority high). The
    // vote must still latch the target tap. tWlo=8 here (single-clock), threshold
    // 4: a 2/3 duty over the ~9-tick window is ~6 votes >= 4, a clean majority.
    await bringUp(taps: 8);
    const lane0Tap = 3;
    const lane1Tap = 5;

    var doneIdx = -1;
    final incCount = <int, int>{0: 0, 1: 0};
    // Per-lane tick counter WITHIN the current strobe window, to shape the noise.
    final strobeTick = <int, int>{0: 0, 1: 0};

    const maxCycles = 4000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final strobe = bit(seq.wlStrobe);
      final lane = bit(seq.wlLane) ?? 0;
      final rst = bit(seq.wlDelayRst);
      final inc = bit(seq.wlDelayInc);
      final done = bit(seq.wlDone);

      if (rst == 1) incCount[lane] = 0;
      if (inc == 1) {
        incCount[lane] = (incCount[lane] ?? 0) + 1;
        strobeTick[lane] = 0; // new tap -> restart the noise phase
      }

      if (strobe == 1) {
        final curTap = incCount[lane] ?? 0;
        final target = lane == 0 ? lane0Tap : lane1Tap;
        final tick = strobeTick[lane] ?? 0;
        strobeTick[lane] = tick + 1;
        if (curTap >= target) {
          // NOISY high: drive 1 on 2 of every 3 ticks (high,high,low,...). A
          // single marginal sample could read either. The vote sees ~6/9 high.
          wlFeedback.inject((tick % 3) == 2 ? 0 : 1);
        } else {
          wlFeedback.inject(0); // below target: clean low
        }
      }

      if (done == 1 && doneIdx < 0) doneIdx = i;
      if (done == 1) break;
    }

    expect(
      doneIdx,
      greaterThanOrEqualTo(0),
      reason: 'WL FSM never exited under noisy feedback',
    );
    final trained = bit(seq.wlTrained);
    expect(trained, isNotNull, reason: 'wl_trained is X after WL');
    final lane0 = trained! & 0xF;
    final lane1 = (trained >> 4) & 0xF;
    expect(
      lane0,
      lane0Tap,
      reason:
          'lane 0 must converge to the target tap by MAJORITY despite the '
          '2/3-duty noisy feedback (the single-sample version would jitter)',
    );
    expect(
      lane1,
      lane1Tap,
      reason:
          'lane 1 must converge to the target tap by MAJORITY despite the '
          'noisy feedback',
    );

    await Simulator.endSimulation();
  });

  test('WL trains tap 1 when the CK-DQS crossing is at tap 1 (the HW case)', () async {
    // HW (fbmap=000000FE, 2026-07-10): with the WL feedback path fixed the real
    // crossing on the OrangeCrab is at TAP 1: feedback low ONLY at tap 0, high
    // at 1..7. The old edge gate `wlTap.gt(1)` rejected a tap-1 edge (earliest
    // accept was tap 2), so WL fell through to tap 0 = uncentered write. The gate
    // is now `wlTap.neq(0)`. Assert a tap-1 crossing trains tap 1 for BOTH lanes.
    await bringUp(taps: 8);
    const targetTap = 1; // both lanes cross at tap 1
    var doneIdx = -1;
    final incCount = <int, int>{0: 0, 1: 0};
    const maxCycles = 4000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final strobe = bit(seq.wlStrobe);
      final lane = bit(seq.wlLane) ?? 0;
      final rst = bit(seq.wlDelayRst);
      final inc = bit(seq.wlDelayInc);
      if (rst == 1) incCount[lane] = 0;
      if (inc == 1) incCount[lane] = (incCount[lane] ?? 0) + 1;
      if (strobe == 1) {
        final curTap = incCount[lane] ?? 0;
        wlFeedback.inject(curTap >= targetTap ? 1 : 0); // low@0, high@1+
      }
      if (bit(seq.wlDone) == 1) {
        doneIdx = i;
        break;
      }
    }
    expect(doneIdx, greaterThanOrEqualTo(0), reason: 'WL never exited');
    final trained = bit(seq.wlTrained);
    expect(trained, isNotNull, reason: 'wl_trained is X');
    expect(
      trained! & 0xF,
      targetTap,
      reason: 'lane 0 must train the tap-1 crossing (not fall through to 0)',
    );
    expect(
      (trained >> 4) & 0xF,
      targetTap,
      reason: 'lane 1 must train the tap-1 crossing (not fall through to 0)',
    );
    await Simulator.endSimulation();
  });

  test(
    'WL FSM terminates even when feedback never transitions (bounded sweep)',
    () async {
      await bringUp(taps: 4);
      // Hold feedback 0 forever: the FSM must still walk every tap of every lane
      // and exit (latching the last tap as a bounded fallback) rather than hang.
      var doneIdx = -1;
      const maxCycles = 4000;
      for (var i = 0; i < maxCycles; i++) {
        await clk.nextPosedge;
        // feedback stays 0 (never injected high).
        if (bit(seq.wlDone) == 1) {
          doneIdx = i;
          break;
        }
      }
      expect(
        doneIdx,
        greaterThanOrEqualTo(0),
        reason: 'WL FSM hung when feedback never transitioned',
      );
      await Simulator.endSimulation();
    },
  );
}
