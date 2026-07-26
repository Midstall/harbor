import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the on-chip write-control diagnostics (scope substitutes) in
/// [DdrPhyEcp5]: the saturating OE / DM / DAT counters over a write burst.
///
/// The DQ/DQS pads and the DQSBUFM strobes are X in sim (no leaf model), but
/// the write CONTROL path these counters observe is plain sclk-domain fabric:
///   - wrOeCount  <- oeWindow  (= wrEn[cwlSys+1] | wrEn[cwlSys+2], off wrStart,
///                              the launch window slid +1 tap by the write-cal
///                              OPTION A rotation fix)
///   - wrDatCount <- wrData2   (the same two taps, the ODDR data-launch window)
///   - wrDmCount  <- any DM bit low (an unmasked byte lane is presented)
/// All three derive from the wrStart-fed wrEn delay line and the latched
/// wrMask, none of which touch the DQSBUFM leaf, so they are sim-visible. This
/// proves, off-hardware, that a write burst makes the counters advance. The
/// actual pin timing is still verified on the OrangeCrab by readback.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, wrStart, wrData, wrMask, beatSel;
  late DdrPhyEcp5 phy;

  Future<void> bringUp() async {
    // clk is the CK-rate edge clock. The PHY divides it to sclk = CK/2.
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');
    wrStart = Logic(name: 'wr_start');
    wrData = Logic(name: 'wr_data', width: 32);
    wrMask = Logic(name: 'wr_mask', width: 4);
    beatSel = Logic(name: 'beat_sel', width: 2);

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
      wrStart: wrStart,
      wrData: wrData,
      wrMask: wrMask,
      beatSel: beatSel,
      rdStart: Const(0),
      padDq: padDq,
      padDqs: padDqs,
      padDqsN: padDqsN,
      rowBits: 14,
      baBits: 3,
      dataBits: 16,
    );

    await phy.build();
    wrStart.inject(0);
    wrData.inject(0xA5A5A5A5);
    // All four byte lanes enabled (DM will be driven low for the selected pair).
    wrMask.inject(0xF);
    beatSel.inject(0);
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    // sclk = CK/2. Clear the sclk reset synchronizer before driving anything.
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    // The PHY's DDRDEL-load init FSM (litedram ECP5DDRPHYInit) bounces the ECLK
    // domain (asserts eclkStop), which FREEZES the divided sclk in the sim clock
    // model for several steps. Wait for that timeline to complete and sclk to
    // resume a clean CK/2 toggle before issuing any write, or the wrStart pulse
    // lands while sclk is stalled and never shifts through the launch pipe.
    for (var i = 0; i < 400; i++) {
      await clk.nextPosedge;
    }
  }

  int? ctr(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  // Pulse wr_start for one sclk cycle (two CK posedges), then let the write
  // launch pipe drain so the OE/DM/DAT windows pass through.
  Future<void> issueWriteBurst() async {
    // Hold wr_start for two sclk cycles (4 CK posedges) so it shifts into the
    // wrEn launch pipe, then drain so the OE/DM/DAT windows pass through.
    wrStart.inject(1);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    wrStart.inject(0);
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
    }
  }

  test(
    'a write burst advances the OE / DAT / DM diagnostic counters',
    () async {
      await bringUp();

      final oe0 = ctr(phy.wrOeCount);
      final dm0 = ctr(phy.wrDmCount);
      final dat0 = ctr(phy.wrDatCount);
      expect(oe0, isNotNull, reason: 'OE counter is defined fabric (not X)');
      expect(dm0, isNotNull, reason: 'DM counter is defined fabric (not X)');
      expect(dat0, isNotNull, reason: 'DAT counter is defined fabric (not X)');
      expect(oe0, 0);
      expect(dat0, 0);

      await issueWriteBurst();

      final oe1 = ctr(phy.wrOeCount)!;
      final dat1 = ctr(phy.wrDatCount)!;
      final dm1 = ctr(phy.wrDmCount)!;
      // The OE / data-launch window is two sclk cycles wide per burst, so both
      // counters must have advanced past their reset value.
      expect(
        oe1,
        greaterThan(oe0!),
        reason: 'oeWindow must assert during a write burst (OE > 0)',
      );
      expect(
        dat1,
        greaterThan(dat0!),
        reason: 'wrData2 launch window must assert during a write burst',
      );
      // The selected beat-pair is unmasked (wrMask=0xF, beatSel=0), so DM goes
      // low on at least one cycle of the burst.
      expect(
        dm1,
        greaterThan(dm0!),
        reason: 'DM must go low for the unmasked selected beat-pair',
      );

      await Simulator.endSimulation();
    },
  );

  test('the counters saturate at 0xFF and never wrap', () async {
    await bringUp();
    // Hammer many write bursts. The OE/DAT counters add 2 per burst, so far more
    // than 0xFF bursts would be needed to overflow, but assert the clamp holds
    // by driving a long continuous wr_start (every sclk cycle is an OE/DAT tap).
    wrStart.inject(1);
    for (var i = 0; i < 700; i++) {
      await clk.nextPosedge;
    }
    wrStart.inject(0);
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    expect(
      ctr(phy.wrOeCount),
      0xFF,
      reason: 'OE counter saturates at 0xFF, no wrap',
    );
    expect(
      ctr(phy.wrDatCount),
      0xFF,
      reason: 'DAT counter saturates at 0xFF, no wrap',
    );
    await Simulator.endSimulation();
  });
}
