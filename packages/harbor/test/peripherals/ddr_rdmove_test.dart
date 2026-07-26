import 'dart:async';

import 'package:harbor/src/peripherals/ddr_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Sim test for the WIRED read-strobe-centering knobs in [DdrPhyEcp5]:
///   - reg5 RDPCTL RDMOVE/RDLOADN/RDDIRECTION -> the DQSBUFM read pointer.
///   - reg8 per-lane DYNDELAY -> each lane's DQSBUFM DQS-strobe delay.
///
/// Before this wiring the PHY added `rd_loadn`/`rd_move`/`rd_direction` inputs
/// but discarded them and drove the DQSBUFM read pointer from fixed Const
/// values, so no firmware read knob could move the strobe (the DLL-on 144 MHz
/// read was metastable). And DYNDELAY was lane-0-only. The DQSBUFM leaf
/// (DQSR90 / RDPNTR) is X in sim, so the eye landing is only provable on
/// hardware, but the CONTROL nets feeding the leaf are plain fabric and
/// sim-visible: this test asserts a driven RDMOVE pulse / RDLOADN / RDDIRECTION
/// and a per-lane DYNDELAY value REACH the DQSBUFM (via the debug mirrors),
/// which is exactly the connection the earlier revision left dangling.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, reset, rdLoadn, rdMove, rdDir, wrTrim;
  late DdrPhyEcp5 phy;

  Future<void> bringUp() async {
    clk = SimpleClockGenerator(2).clk;
    reset = Logic(name: 'reset');
    rdLoadn = Logic(name: 'rd_loadn');
    rdMove = Logic(name: 'rd_move');
    rdDir = Logic(name: 'rd_direction');
    // 2 lanes * 8 bits = 16-bit per-lane DYNDELAY.
    wrTrim = Logic(name: 'wr_trim', width: 16);

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
      // DLL-on trained build: clkMhz > 60 selects the x2 DQSBUFM read path, and
      // trainable wires the reg5 RDPCTL read-pointer controls.
      clkMhz: 144,
      trainable: true,
      rdLoadn: rdLoadn,
      rdMove: rdMove,
      rdDirection: rdDir,
      writeTrimTrainable: true,
      wrTrim: wrTrim,
    );

    await phy.build();
    rdLoadn.inject(0);
    rdMove.inject(0);
    rdDir.inject(1);
    wrTrim.inject(0);
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
  }

  int? val(Logic l) {
    final v = l.value;
    return v.isValid ? v.toInt() : null;
  }

  test(
    'reg5 RDMOVE pulse reaches the DQSBUFM read pointer (the wired knob)',
    () async {
      await bringUp();

      // Baseline: no move.
      expect(val(phy.rdMoveDbg), 0, reason: 'RDMOVE idle before any step');
      expect(
        val(phy.rdLoadnDbg),
        0,
        reason: 'RDLOADN asserted (0) loads the DDRDEL 90-deg code',
      );
      expect(
        val(phy.rdDirectionDbg),
        1,
        reason: 'RDDIRECTION increment default',
      );

      // Drive an RDMOVE pulse and confirm it reaches the DQSBUFM read pointer.
      rdMove.inject(1);
      await clk.nextPosedge;
      expect(
        val(phy.rdMoveDbg),
        1,
        reason:
            'a driven RDMOVE must reach the DQSBUFM read pointer - the '
            'connection the earlier revision hardcoded to Const(0)',
      );
      rdMove.inject(0);
      await clk.nextPosedge;
      expect(val(phy.rdMoveDbg), 0, reason: 'RDMOVE returns low');

      // Flip RDDIRECTION and RDLOADN and confirm they too are live, not Const.
      rdDir.inject(0);
      rdLoadn.inject(1);
      await clk.nextPosedge;
      expect(
        val(phy.rdDirectionDbg),
        0,
        reason: 'RDDIRECTION is now firmware-driven, not a fixed Const(1)',
      );
      expect(
        val(phy.rdLoadnDbg),
        1,
        reason: 'RDLOADN is now firmware-driven, not a fixed Const(0)',
      );

      await Simulator.endSimulation();
    },
  );

  test('reg8 DYNDELAY is per-DQS-group (both lanes independently reach the '
      'DQSBUFM)', () async {
    await bringUp();

    // Lane 0 = 0x3A, lane 1 = 0x5C: distinct per-lane read-strobe delays.
    wrTrim.inject(0x5C3A);
    await clk.nextPosedge;
    final dd = val(phy.rdDynDelayDbg);
    expect(
      dd,
      0x5C3A,
      reason:
          'both lanes DYNDELAY reach the DQSBUFM (lane0=0x3A lane1=0x5C); '
          'previously only lane 0 was wired',
    );
    expect(dd! & 0xFF, 0x3A, reason: 'lane 0 DYNDELAY = bits [7:0]');
    expect((dd >> 8) & 0xFF, 0x5C, reason: 'lane 1 DYNDELAY = bits [15:8]');

    await Simulator.endSimulation();
  });
}
