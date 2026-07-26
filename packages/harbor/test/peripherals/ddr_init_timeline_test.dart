import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the ECP5 DDR PHY DDRDEL-load init FSM (litedram ECP5DDRPHYInit,
/// ecp5ddrphy.py lines 54-111).
///
/// The DDRDLLA and DQSBUFM leaves have no sim model (they are X), but the init
/// FSM's CONTROL logic - the step counter, the FREEZE / ECLK-STOP / ECLK-reset
/// bounce, the single UDDCNTLN low pulse inside the DQSBUFM PAUSE window, and
/// the initDone latch - is plain sclk-domain fabric and IS sim-visible. The
/// clock tree's behavioral model drives DDRDLLA LOCK high a few sclk cycles
/// after reset release (a stand-in for "the DLL eventually locks"), so the FSM
/// triggers on the modelled rising edge of LOCK exactly as it will on the real
/// leaf. This is the one part of the DQS read path that can be sim-verified, so
/// we assert the litedram waveform here.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset;
  late DdrPhyEcp5 phy;

  Future<void> bringUp() async {
    // clk is the CK-rate edge-clock source, the PHY divides it to sclk = CK/2.
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');

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
    );

    await phy.build();
    reset.inject(1);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    // Hold reset a few CK edges, then release.
    for (var i = 0; i < 6; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
  }

  int? bit(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  test('init FSM drives the litedram DDRDEL-load waveform on lock', () async {
    await bringUp();

    // Sample the init handshake signals every CK edge while the timeline runs.
    // Record: did FREEZE ever assert, did STOP ever assert, did the ECLK reset
    // ever pulse, the UDDCNTLN trace (it must idle HIGH and dip LOW exactly
    // once), whether every UDDCNTLN-low cycle is inside PAUSE-high, whether the
    // last FREEZE-high cycle precedes the first UDDCNTLN-low cycle, and when
    // initDone rises.
    var sawFreeze = false;
    var sawStop = false;
    var sawEclkReset = false;
    var uddLowCycles = 0;
    var uddLowTransitions = 0; // count of high->low edges (must be exactly 1)
    var prevUdd = 1;
    var lastFreezeIdx = -1;
    var firstUddLowIdx = -1;
    var allUddLowInsidePause = true;
    var initDoneIdx = -1;

    const maxCycles = 2000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final udd = bit(phy.initUddcntlnOut);
      final frz = bit(phy.initFreezeOut);
      final stop = bit(phy.initEclkStopOut);
      final erst = bit(phy.initEclkResetOut);
      final pause = bit(phy.initPauseOut);
      final done = bit(phy.initDoneOut);

      if (frz == 1) {
        sawFreeze = true;
        lastFreezeIdx = i;
      }
      if (stop == 1) sawStop = true;
      if (erst == 1) sawEclkReset = true;
      if (udd == 0) {
        uddLowCycles++;
        firstUddLowIdx = firstUddLowIdx < 0 ? i : firstUddLowIdx;
        if (pause != 1) allUddLowInsidePause = false;
      }
      if (udd == 0 && prevUdd == 1) uddLowTransitions++;
      if (udd != null) prevUdd = udd;
      if (done == 1 && initDoneIdx < 0) initDoneIdx = i;

      if (done == 1) break;
    }

    // initDone must eventually assert (the timeline completed).
    expect(
      initDoneIdx,
      greaterThanOrEqualTo(0),
      reason: 'init FSM never completed (initDone never rose)',
    );
    // The full bounce happened: FREEZE, ECLK STOP, ECLK reset all asserted.
    expect(sawFreeze, isTrue, reason: 'FREEZE never asserted');
    expect(sawStop, isTrue, reason: 'ECLKSYNCB STOP never asserted');
    expect(sawEclkReset, isTrue, reason: 'ECLK-domain reset never pulsed');
    // UDDCNTLN is active-low: it idles HIGH and dips LOW for exactly one pulse
    // (litedram update=1 at step 8, update=0 at step 9).
    expect(
      uddLowTransitions,
      1,
      reason:
          'UDDCNTLN must have exactly ONE high->low pulse, got '
          '$uddLowTransitions',
    );
    expect(
      uddLowCycles,
      greaterThan(0),
      reason: 'UDDCNTLN never went low (DDRDEL was never latched)',
    );
    // The whole UDDCNTLN-low pulse sits inside the DQSBUFM PAUSE-high window
    // (litedram pause=1 at step 7, pause=0 at step 10, update inside).
    expect(
      allUddLowInsidePause,
      isTrue,
      reason: 'UDDCNTLN went low outside the PAUSE window',
    );
    // FREEZE is asserted+released (steps 1,6) strictly BEFORE the update pulse
    // (step 8): the last FREEZE-high cycle precedes the first UDDCNTLN-low.
    expect(
      lastFreezeIdx,
      lessThan(firstUddLowIdx),
      reason: 'FREEZE must be released before the UDDCNTLN update pulse',
    );

    await Simulator.endSimulation();
  });

  test('ALIGNWD pulses AFTER ECLK resumes (never overlaps STOP)', () async {
    // The CLKDIVF only samples ALIGNWD on an ECLK posedge, and the ECLKSYNCB
    // freezes ECLK while STOP=1, so an ALIGNWD pulse inside the STOP window is a
    // NO-OP. The word-align pulse MUST land while STOP=0 (eclk running). Assert
    // ALIGNWD asserts at least once, and EVERY ALIGNWD-high cycle has STOP=0.
    await bringUp();

    var sawAlignwd = false;
    var allAlignwdWithEclkRunning = true;
    var done = false;
    const maxCycles = 2000;
    for (var i = 0; i < maxCycles && !done; i++) {
      await clk.nextPosedge;
      final align = bit(phy.initAlignwdOut);
      final stop = bit(phy.initEclkStopOut);
      if (align == 1) {
        sawAlignwd = true;
        // The load-bearing constraint: alignwd high => eclk NOT stopped.
        if (stop != 0) allAlignwdWithEclkRunning = false;
      }
      done = bit(phy.initDoneOut) == 1;
    }

    expect(sawAlignwd, isTrue, reason: 'ALIGNWD never asserted');
    expect(
      allAlignwdWithEclkRunning,
      isTrue,
      reason:
          'ALIGNWD overlapped ECLK STOP - the CLKDIVF would never sample '
          'it (ALIGNWD must pulse only while eclkStop==0)',
    );

    await Simulator.endSimulation();
  });

  test('RDPNTR-ALIGN: rd_reset held through the bounce, released once inside '
      'PAUSE-high AFTER the DDRDEL update and BEFORE pause-release', () async {
    // The RDPNTR-align fix: the DQSBUFM + IDDRX2DQA read-block reset
    // (init_rd_reset) is held asserted from power-up through the whole
    // stop/reset/ALIGNWD/DDRDEL bounce, then released ONCE, after the UDDCNTLN
    // (DDRDEL calibration) pulse, while PAUSE is still HIGH, and strictly BEFORE
    // pause-release. That single clean out-of-reset edge on the aligned +
    // calibrated gearbox is what pins the read-FIFO pointer to a deterministic
    // beat-0 phase each cold boot.
    await bringUp();

    // rd_reset must idle HIGH before the timeline runs (held from power-up).
    await clk.nextPosedge;
    expect(
      bit(phy.initRdResetOut),
      1,
      reason:
          'init_rd_reset must idle HIGH (read block held in reset from '
          'power-up until the aligned gearbox is ready)',
    );

    var rdResetHighToLow =
        0; // number of 1->0 release edges (must be exactly 1)
    var prevRdReset = 1;
    var rdResetLowIdx = -1; // first cycle rd_reset is low (the release)
    var pauseAtReleaseHigh = false; // PAUSE high on the release cycle
    var releasedOutsidePause = false;
    var lastUddLowIdx = -1;
    var pauseDropIdx = -1; // first cycle PAUSE drops back to 0 after asserting
    var sawPauseHigh = false;
    var initDoneIdx = -1;

    const maxCycles = 3000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final rd = bit(phy.initRdResetOut);
      final pause = bit(phy.initPauseOut);
      final udd = bit(phy.initUddcntlnOut);
      final done = bit(phy.initDoneOut);

      if (rd == 0 && prevRdReset == 1) {
        rdResetHighToLow++;
        if (rdResetLowIdx < 0) {
          rdResetLowIdx = i;
          pauseAtReleaseHigh = pause == 1;
          if (pause != 1) releasedOutsidePause = true;
        }
      }
      if (rd != null) prevRdReset = rd;

      if (pause == 1) sawPauseHigh = true;
      if (sawPauseHigh && pause == 0 && pauseDropIdx < 0) pauseDropIdx = i;

      if (udd == 0) lastUddLowIdx = i;

      if (done == 1 && initDoneIdx < 0) initDoneIdx = i;
      if (done == 1) break;
    }

    // Exactly one release edge (a clean single out-of-reset transition).
    expect(
      rdResetHighToLow,
      1,
      reason:
          'init_rd_reset must have EXACTLY ONE high->low release edge, '
          'got $rdResetHighToLow',
    );
    expect(
      rdResetLowIdx,
      greaterThanOrEqualTo(0),
      reason: 'init_rd_reset never released',
    );
    // The release happens with PAUSE still HIGH (inside the DQSBUFM PAUSE
    // bracket).
    expect(
      pauseAtReleaseHigh,
      isTrue,
      reason: 'init_rd_reset must release while PAUSE is HIGH',
    );
    expect(
      releasedOutsidePause,
      isFalse,
      reason: 'init_rd_reset released outside the PAUSE-high window',
    );
    // The release is AFTER the DDRDEL update pulse (last UDDCNTLN-low cycle).
    expect(lastUddLowIdx, greaterThanOrEqualTo(0));
    expect(
      rdResetLowIdx,
      greaterThan(lastUddLowIdx),
      reason:
          'init_rd_reset must release AFTER the DDRDEL update (UDDCNTLN '
          'pulse), so DQSR90 is calibrated when the read block leaves reset',
    );
    // The release is BEFORE pause-release (PAUSE drops last).
    expect(
      pauseDropIdx,
      greaterThan(rdResetLowIdx),
      reason:
          'PAUSE must drop AFTER init_rd_reset releases (pause released '
          'LAST)',
    );
    // initDone latches AFTER the read block is out of reset.
    expect(
      initDoneIdx,
      greaterThan(rdResetLowIdx),
      reason: 'initDone must latch after the read block leaves reset',
    );

    await Simulator.endSimulation();
  });

  test(
    'UDDCNTLN idles HIGH before the timeline and stays HIGH after',
    () async {
      await bringUp();

      // Right after reset release, before LOCK rises, UDDCNTLN idles HIGH (no
      // update in progress).
      await clk.nextPosedge;
      expect(
        bit(phy.initUddcntlnOut),
        1,
        reason: 'UDDCNTLN must idle HIGH before the load handshake',
      );

      // Run until initDone, then confirm UDDCNTLN settled back HIGH and PAUSE
      // dropped (the load pulse ended cleanly).
      var done = false;
      for (var i = 0; i < 2000 && !done; i++) {
        await clk.nextPosedge;
        done = bit(phy.initDoneOut) == 1;
      }
      expect(done, isTrue);
      // A few cycles after completion everything is back to idle.
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      expect(
        bit(phy.initUddcntlnOut),
        1,
        reason: 'UDDCNTLN must return HIGH after the load pulse',
      );
      expect(
        bit(phy.initPauseOut),
        0,
        reason: 'PAUSE must drop after the load pulse',
      );
      expect(bit(phy.initFreezeOut), 0, reason: 'FREEZE must be released');

      await Simulator.endSimulation();
    },
  );
}
