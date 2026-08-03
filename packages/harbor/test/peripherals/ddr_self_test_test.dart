import 'dart:async';

import 'package:harbor/src/peripherals/ddr.dart';
import 'package:harbor/src/peripherals/ddr_sequencer.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Digital-logic tests for the sSelfTest cadence-verify FSM: after the read-cal
/// sweep locks a window/tap, the self-test re-reads the MPR pattern at varied
/// spacing and requires every read to match. Model the PHY's rd_cal_match per
/// phase (sweep vs self-test, distinguished by state_code) and check both the
/// PASS (verified -> bus opens, self_test_pass=1) and the FAIL (never matches ->
/// advances windows, then fallback-opens the bus, self_test_pass=0) paths. The
/// real DQ capture is unsimmable; this proves the FSM gate/retry/fallback logic.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const sRdCal = 15, sSelfTest = 6;
  const goodWin = 2, tapLo = 12, tapHi = 20, eye = (tapLo + tapHi) ~/ 2;

  Future<Map<String, dynamic>> run({required bool selfTestMatches}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final req = Logic();
    final we = Logic();
    final reqAddr = Logic(width: 32);
    final reqData = Logic(width: 32);
    final reqSel = Logic(width: 4);
    final rdCalMatch = Logic(name: 'rd_cal_match', width: 2); // orangeCrab x16

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
      selfTest: true,
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

    final state = seq.output('state_code');
    final window = seq.output('rd_cal_window');
    final tap = seq.output('rd_cal_tap');
    final lane = seq.output('rd_cal_lane');
    final done = seq.output('rd_cal_done');
    final pass = seq.output('self_test_pass');

    var reachedSelfTest = false, doneSeen = false;
    for (var cyc = 0; cyc < 400000 && !doneSeen; cyc++) {
      await clk.nextPosedge;
      final st = state.value.isValid ? state.value.toInt() : -1;
      final w = window.value.isValid ? window.value.toInt() : -1;
      final t = tap.value.isValid ? tap.value.toInt() : -1;
      final l = lane.value.isValid ? lane.value.toInt() : 0;
      if (st == sSelfTest) reachedSelfTest = true;
      bool good;
      if (st == sRdCal) {
        // sweep: a good eye at window2, taps 12..20.
        good = w == goodWin && t >= tapLo && t <= tapHi;
      } else if (st == sSelfTest) {
        // self-test: the modeled cadence behaviour at the locked window.
        good = selfTestMatches && w == goodWin;
      } else {
        good = false;
      }
      rdCalMatch.inject(good ? (1 << l) : 0);
      if (done.value.toBool()) doneSeen = true;
    }
    final result = {
      'reachedSelfTest': reachedSelfTest,
      'doneSeen': doneSeen,
      'pass': pass.value.isValid && pass.value.toBool(),
      'window': window.value.isValid ? window.value.toInt() : -1,
      'tap': tap.value.isValid ? tap.value.toInt() : -1,
    };
    await Simulator.endSimulation();
    return result;
  }

  test(
    'self-test PASSES: sweep locks the eye, cadence verify passes, bus opens',
    () async {
      final r = await run(selfTestMatches: true);
      expect(r['reachedSelfTest'], isTrue, reason: 'never entered self-test');
      expect(r['doneSeen'], isTrue, reason: 'bus gate never opened');
      expect(
        r['pass'],
        isTrue,
        reason: 'self_test_pass not set on a clean verify',
      );
      expect(r['window'], equals(goodWin), reason: 'locked window drifted');
      expect(r['tap'], equals(eye), reason: 'locked tap not the eye centre');
    },
  );

  test(
    'self-test FAILS: never verifies, advances windows, fallback opens bus',
    () async {
      final r = await run(selfTestMatches: false);
      expect(r['reachedSelfTest'], isTrue, reason: 'never entered self-test');
      // Never wedges: the fallback must still open the bus.
      expect(
        r['doneSeen'],
        isTrue,
        reason: 'self-test wedged (no fallback open)',
      );
      // But it must report the failure (not a false pass).
      expect(
        r['pass'],
        isFalse,
        reason: 'reported pass despite never matching',
      );
    },
  );
}
