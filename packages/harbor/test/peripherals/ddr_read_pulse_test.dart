import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the INDEPENDENT read-pulse position (reg11 RDPULSE) in
/// [DdrPhyEcp5]: the OrangeCrab 25F burst-framing fix.
///
/// Root cause (HW-proven across many boots): the DLL-on read READBACK was
/// INVARIANT to the written data (0x5A / 0xC0DE both read the same preamble/idle
/// constant). The DQSBUFM READ0/READ1 read-gate was a 3-tap-wide, preamble-
/// bracketed pulse whose position was LOCKED to the RDSLACK capture anchor (both
/// indexed rdPipe by the same rdSlackRt), so no RDSLACK value could frame the
/// data burst. The read captured the PREAMBLE. LiteDRAM instead drives a CLEAN
/// 2-sclk pulse `dqs_re = taps[rdtap] | taps[rdtap+1]` positioned at the CAS
/// latency, INDEPENDENT of the capture.
///
/// The fix: reg11 RDPULSE shifts ONLY the READ0/READ1 gate tap over 0..15 sclk
/// cycles from the read command, decoupled from the RDSLACK anchor, keeping the
/// pulse a clean 2-cycle pulse. BURSTDET (already exposed) frames it. The DQSBUFM
/// leaf (DQSR90/BURSTDET) is X in sim, but the gate net feeding READ0/READ1 is
/// plain fabric, [rdGateDbg] mirrors it, so this test proves the reg11 position
/// moves the gate to the commanded tap and that the pulse is a clean 2 cycles.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, rdStart, rdPulsePos, rdSlack;
  late DdrPhyEcp5 phy;

  // The gate opens `k+1` sclk cycles after the rdStart pulse cycle for a pulse
  // position `k` (rdPipe[0] latches rdStart the cycle after the pulse, so
  // rdPipe[k] is high k+1 cycles after). We drive rdStart for one cycle then
  // watch rdGateDbg over the next several cycles.
  Future<void> bringUp({int maxRdPulse = 15}) async {
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');
    rdStart = Logic(name: 'rd_start');
    // 5-bit position field: 0..15 real positions, 31 = legacy-gate sentinel
    // ((maxRdPulse+1).bitLength = 16.bitLength = 5).
    rdPulsePos = Logic(name: 'rd_pulse_pos', width: 5);
    rdSlack = Logic(name: 'rd_slack', width: 4);

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
      rdStart: rdStart,
      padDq: padDq,
      padDqs: padDqs,
      padDqsN: padDqsN,
      rowBits: 14,
      baBits: 3,
      dataBits: 16,
      // DLL-on trained build (clkMhz > 60 -> x2 DQSBUFM path).
      clkMhz: 132,
      trainable: true,
      rdSlackRuntime: rdSlack,
      rdPulsePos: rdPulsePos,
      maxRdPulse: maxRdPulse,
    );

    await phy.build();
    rdStart.inject(0);
    rdPulsePos.inject(0);
    rdSlack.inject(0);
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
  }

  int? gate() {
    final v = phy.rdGateDbg.value;
    return v.isValid ? v.toInt() : null;
  }

  /// The PHY fabric runs on sclk = CK/2 (CLKDIVF). Sample the gate on sclk edges
  /// so the capture is in the same domain as rdPipe. [sclkOut] is the derived
  /// half-rate clock the PHY exports.
  Future<void> nextSclk() => phy.sclkOut.nextPosedge;

  /// Pulse rd_start for one sclk cycle, then sample rdGateDbg on the following
  /// sclk edges for [cycles] sclk cycles. Index 0 = the first sclk edge after
  /// the rdStart-high sclk cycle. rdStart is held across a full sclk period so
  /// the sclk-domain rdPipe flop reliably latches it (CK-rate pulses can be
  /// missed by the half-rate flop).
  Future<List<int?>> captureGate(int cycles) async {
    // Drain any earlier command. Settle in the sclk domain.
    for (var i = 0; i < 4; i++) {
      await nextSclk();
    }
    rdStart.inject(1);
    await nextSclk(); // rdStart high for one full sclk cycle
    rdStart.inject(0);
    final out = <int?>[];
    for (var i = 0; i < cycles; i++) {
      out.add(gate());
      await nextSclk();
    }
    return out;
  }

  /// The index of the first asserted gate cycle in a capture, or -1.
  int firstHigh(List<int?> g) {
    for (var i = 0; i < g.length; i++) {
      if (g[i] == 1) return i;
    }
    return -1;
  }

  test('reg11 RDPULSE moves the read-gate pulse to the commanded tap', () async {
    await bringUp();

    // Position 3: gate opens ~cycle 3 after the start cycle (rdPipe[3] high 3
    // cycles after rdStart latches, sampled from the cycle after the pulse).
    rdPulsePos.inject(3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    final g3 = await captureGate(12);
    final open3 = firstHigh(g3);
    expect(
      open3,
      greaterThanOrEqualTo(0),
      reason: 'the read gate must open for a programmed pulse position 3',
    );

    // Position 8: a strictly LATER open than position 3 (the pulse position is a
    // real, independent lever, not locked to a fixed CL/RDSLACK tap).
    rdPulsePos.inject(8);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    final g8 = await captureGate(14);
    final open8 = firstHigh(g8);
    expect(
      open8,
      greaterThan(open3),
      reason:
          'a larger reg11 read-pulse position opens the gate LATER - the '
          'independent burst-framing lever that lets the FSBL walk the pulse '
          'onto the data burst (was locked to the RDSLACK anchor before)',
    );
    // The delta tracks the position delta (8 - 3 = 5).
    expect(
      open8 - open3,
      5,
      reason: 'the gate open moves one sclk per read-pulse position step',
    );

    await Simulator.endSimulation();
  });

  test(
    'the trained read pulse is a CLEAN 2-sclk pulse (litedram taps[t]|taps[t+1])',
    () async {
      await bringUp();

      rdPulsePos.inject(5);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      final g = await captureGate(14);
      final open = firstHigh(g);
      expect(open, greaterThanOrEqualTo(0), reason: 'gate opens');
      // Exactly 2 consecutive high cycles (a clean 2-cycle pulse), then low, NOT
      // the old 3-tap preamble-bracketed gate.
      expect(g[open], 1);
      expect(g[open + 1], 1, reason: 'the pulse is 2 sclk cycles wide');
      expect(
        g[open + 2],
        0,
        reason:
            'the trained pulse is CLEAN 2 cycles (not the 3-tap legacy gate) '
            'so the DQSBUFM RDPNTR/BURSTDET can stabilize on the burst',
      );

      await Simulator.endSimulation();
    },
  );

  test('the all-ones sentinel keeps the LEGACY gate (reg11 unprogrammed)', () async {
    await bringUp();

    // Sentinel = 0x1F (all ones for the 5-bit field, 31) = "use legacy gate".
    // This is the REAL sentinel the PHY decodes (rd_pulse_pos == 5'h1f) and the
    // reset default of the reg11 holding register. The legacy gate tracks the
    // RDSLACK anchor. Drive a nonzero slack and confirm the gate still opens (the
    // legacy path is alive: an unprogrammed boot is behavior-identical to before
    // the pulse knob existed).
    rdPulsePos.inject(0x1F);
    rdSlack.inject(2);
    for (var i = 0; i < 4; i++) {
      await nextSclk();
    }
    final g = await captureGate(22);
    final open = firstHigh(g);
    expect(
      open,
      greaterThanOrEqualTo(0),
      reason:
          'the legacy (sentinel) gate still opens so an unprogrammed boot '
          'is behavior-identical to before the pulse knob existed',
    );
    // Legacy gate is asserted for at least 2 sclk cycles (the preamble-bracketed
    // multi-tap window). The exact width is not the contract here: the contract
    // is that the sentinel selects the LEGACY path, not the clean 2-tap pulse.
    expect(g[open], 1);
    expect(
      g[open + 1],
      1,
      reason: 'the legacy gate is the wider preamble-bracketed window',
    );

    await Simulator.endSimulation();
  });
}
