import 'dart:async';

import 'package:harbor/src/peripherals/ddr.dart';
import 'package:harbor/src/peripherals/ddr_sequencer.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Digital-logic test for the sRdCal read-calibration FSM: model the PHY's
/// rd_cal_match as high only at a chosen window + a contiguous tap band, and
/// check the sweep LOCKS that window at the tap-band eye centre and asserts
/// rd_cal_done. (The real DQ/DQS capture is unsimmable; this proves the FSM
/// sweep/lock/gate logic.)
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('read-cal sweeps, locks the eye centre window/tap, asserts done', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final req = Logic();
    final we = Logic();
    final reqAddr = Logic(width: 32);
    final reqData = Logic(width: 32);
    final reqSel = Logic(width: 4);
    // orangeCrab config is x16 = 2 lanes -> 2 match bits (exercises the
    // multi-lane per-lane sweep).
    final rdCalMatch = Logic(name: 'rd_cal_match', width: 2);

    final seq = DdrSequencer(
      clk,
      reset,
      req,
      we,
      reqAddr,
      reqData,
      reqSel,
      rdCalMatch: rdCalMatch,
      config: const HarborDdrConfig.orangeCrab(),
      clkMhz: 2, // small: JEDEC us/ns waits collapse to a few cycles
      readLevel: true,
    );
    await seq.build();
    for (final s in [req, we, reqAddr, reqData, reqSel]) {
      s.inject(0);
    }
    reset.inject(1);
    rdCalMatch.inject(0);

    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);

    // The good eye: window 2, taps 12..20 -> eye centre 16.
    const goodWin = 2, tapLo = 12, tapHi = 20, eye = (tapLo + tapHi) ~/ 2;

    final active = seq.output('rd_cal_active');
    final window = seq.output('rd_cal_window');
    final tap = seq.output('rd_cal_tap');
    final lane = seq.output('rd_cal_lane');
    final done = seq.output('rd_cal_done');

    var reachedActive = false, doneSeen = false;
    for (var cyc = 0; cyc < 120000 && !doneSeen; cyc++) {
      await clk.nextPosedge;
      final act = active.value.toBool();
      if (act) reachedActive = true;
      // Model the PHY: the currently-swept lane matches only at the good window
      // over the good tap band (both lanes have the same good eye).
      final w = window.value.isValid ? window.value.toInt() : -1;
      final t = tap.value.isValid ? tap.value.toInt() : -1;
      final l = lane.value.isValid ? lane.value.toInt() : 0;
      final good = act && w == goodWin && t >= tapLo && t <= tapHi;
      rdCalMatch.inject(good ? (1 << l) : 0);
      if (done.value.toBool()) doneSeen = true;
    }

    expect(reachedActive, isTrue, reason: 'FSM never entered read-cal');
    expect(doneSeen, isTrue, reason: 'read-cal never asserted rd_cal_done');
    // At done the locked window/tap should be the eye centre of the good band.
    expect(
      window.value.toInt(),
      equals(goodWin),
      reason: 'wrong locked window',
    );
    expect(tap.value.toInt(), equals(eye), reason: 'tap not at eye centre');

    // Observability word (STATUS reg6): a normal successful cal must report
    // done + reached-sRdCal + eye-found, and NOT the watchdog abort. Layout:
    // [15]done [14]reached [13]watchdog [12]winFound [11:7]tap [6:3]window.
    final dbg = seq.rdCalDbg.value.toInt();
    expect((dbg >> 15) & 1, equals(1), reason: 'dbg: done not set');
    expect((dbg >> 14) & 1, equals(1), reason: 'dbg: reached-sRdCal not set');
    expect((dbg >> 13) & 1, equals(0), reason: 'dbg: watchdog wrongly fired');
    expect((dbg >> 12) & 1, equals(1), reason: 'dbg: eye-found not set');
    expect((dbg >> 7) & 0x1f, equals(eye), reason: 'dbg: wrong locked tap');
    expect(
      (dbg >> 3) & 0xf,
      equals(goodWin),
      reason: 'dbg: wrong locked window',
    );

    await Simulator.endSimulation();
  });

  test(
    'read-cal centres on the WIDEST contiguous run, not a first..last gap',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final req = Logic();
      final we = Logic();
      final reqAddr = Logic(width: 32);
      final reqData = Logic(width: 32);
      final reqSel = Logic(width: 4);
      final rdCalMatch = Logic(name: 'rd_cal_match', width: 2);

      final seq = DdrSequencer(
        clk,
        reset,
        req,
        we,
        reqAddr,
        reqData,
        reqSel,
        rdCalMatch: rdCalMatch,
        config: const HarborDdrConfig.orangeCrab(),
        clkMhz: 2,
        readLevel: true,
      );
      await seq.build();
      for (final s in [req, we, reqAddr, reqData, reqSel]) {
        s.inject(0);
      }
      reset.inject(1);
      rdCalMatch.inject(0);

      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);

      // Two passing ISLANDS at the good window: a narrow one (taps 2..5, width 4)
      // and a wide one (taps 18..28, width 11), with a failing gap between. The old
      // (first+last)/2 centre = (2+28)/2 = 15 lands IN THE GAP (a failing tap); the
      // widest-contiguous-run centre = (18+28)/2 = 23 lands inside the wide island.
      const goodWin = 2;
      const nLo = 2, nHi = 5, wLo = 18, wHi = 28;
      const wideEye = (wLo + wHi) ~/ 2; // 23
      const oldGapMid = (nLo + wHi) ~/ 2; // 15 (the buggy first..last midpoint)

      final active = seq.output('rd_cal_active');
      final window = seq.output('rd_cal_window');
      final tap = seq.output('rd_cal_tap');
      final lane = seq.output('rd_cal_lane');
      final done = seq.output('rd_cal_done');

      var doneSeen = false;
      for (var cyc = 0; cyc < 120000 && !doneSeen; cyc++) {
        await clk.nextPosedge;
        final act = active.value.toBool();
        final w = window.value.isValid ? window.value.toInt() : -1;
        final t = tap.value.isValid ? tap.value.toInt() : -1;
        final l = lane.value.isValid ? lane.value.toInt() : 0;
        final inIsland = (t >= nLo && t <= nHi) || (t >= wLo && t <= wHi);
        final good = act && w == goodWin && inIsland;
        rdCalMatch.inject(good ? (1 << l) : 0);
        if (done.value.toBool()) doneSeen = true;
      }

      expect(doneSeen, isTrue, reason: 'read-cal never asserted rd_cal_done');
      expect(
        window.value.toInt(),
        equals(goodWin),
        reason: 'wrong locked window',
      );
      expect(
        tap.value.toInt(),
        equals(wideEye),
        reason: 'tap not at the WIDEST-run centre',
      );
      expect(
        tap.value.toInt(),
        isNot(equals(oldGapMid)),
        reason: 'tap regressed to the first..last gap midpoint',
      );

      await Simulator.endSimulation();
    },
  );
}
