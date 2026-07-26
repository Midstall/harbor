import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Drives the opt-in DDR read-training MMIO control window and proves the
/// register block walks the read-tap delay controller and stores rdSlack. A
/// pure-logic check of the control surface: the PHY's analog delay primitives
/// are SV blackboxes (no sim model), so the tap/eye correctness is proven on
/// the OrangeCrab, not here. See project_ddr_training.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // OrangeCrab array is 128MB. The control window sits just above it.
  const size = 128 * 1024 * 1024;
  const rdtapTarget = size + 0x00;
  const ctl = size + 0x08;
  const rdslack = size + 0x10;
  const status = size + 0x18;

  late Logic clk, reset, cyc, stb, we, adr, datMosi, sel;
  late HarborDdrController ddr;

  Future<void> bringUp() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      trainableRead: true,
    );
    cyc = Logic(name: 'cyc');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: ddr.input('bus_ADR').width);
    datMosi = Logic(name: 'datMosi', width: ddr.input('bus_DAT_MOSI').width);
    sel = Logic(name: 'sel', width: ddr.input('bus_SEL').width);

    ddr.input('clk').srcConnection! <= clk;
    ddr.input('reset').srcConnection! <= reset;
    ddr.input('bus_CYC').srcConnection! <= cyc;
    ddr.input('bus_STB').srcConnection! <= stb;
    ddr.input('bus_WE').srcConnection! <= we;
    ddr.input('bus_ADR').srcConnection! <= adr;
    ddr.input('bus_DAT_MOSI').srcConnection! <= datMosi;
    ddr.input('bus_SEL').srcConnection! <= sel;

    await ddr.build();
    for (final s in [cyc, stb, we, adr, datMosi, sel]) {
      s.inject(0);
    }
    reset.inject(1);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
  }

  Logic ack() => ddr.output('bus_ACK');
  Logic miso() => ddr.output('bus_DAT_MISO');

  Future<void> wbWrite(int address, int data) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(1);
    adr.inject(address);
    datMosi.inject(data);
    var guard = 0;
    while (!ack().value.toBool() && guard++ < 100) {
      await clk.nextPosedge;
    }
    await clk.nextPosedge; // consume the ack cycle
    cyc.inject(0);
    stb.inject(0);
    we.inject(0);
    await clk.nextPosedge;
  }

  Future<int> wbRead(int address) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(0);
    adr.inject(address);
    var guard = 0;
    while (!ack().value.toBool() && guard++ < 100) {
      await clk.nextPosedge;
    }
    final v = miso().value.toInt();
    await clk.nextPosedge;
    cyc.inject(0);
    stb.inject(0);
    await clk.nextPosedge;
    return v;
  }

  // STATUS layout: busy[0], currentTap[7:1], DATAVALID[8], BURSTDET[9]. The
  // DQS read flags (bits 8/9) come straight from the DQSBUFM, an SV leaf with
  // no sim model, so they are X in simulation (hardware-only). Read only the
  // defined control-plane bits [7:0] so .toInt() does not choke on the X DQS
  // bits. The busy/tap walk is the control logic this test guards.
  Future<int> wbReadStatusLow() async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(0);
    adr.inject(status);
    var guard = 0;
    while (!ack().value.toBool() && guard++ < 100) {
      await clk.nextPosedge;
    }
    final low = miso().value.getRange(0, 8).toInt();
    await clk.nextPosedge;
    cyc.inject(0);
    stb.inject(0);
    await clk.nextPosedge;
    return low;
  }

  test(
    'MMIO SET walks the read tap to the target; STATUS reads it back',
    () async {
      await bringUp();

      // Walk to tap 12: write target, pulse CTL.SET (bit0).
      await wbWrite(rdtapTarget, 12);
      await wbWrite(ctl, 0x1);

      // Poll STATUS until not busy (bit0), then current tap is bits [7:1].
      var st = 0;
      for (var i = 0; i < 200; i++) {
        st = await wbReadStatusLow();
        if (st & 0x1 == 0) break;
      }
      expect(st & 0x1, 0, reason: 'controller should be idle after the walk');
      expect(
        (st >> 1) & 0x7F,
        12,
        reason: 'current tap should reach the target',
      );

      await Simulator.endSimulation();
    },
  );

  test('RDSLACK is writable and reads back', () async {
    await bringUp();
    await wbWrite(rdslack, 3);
    final v = await wbRead(rdslack);
    expect(v & 0x7, 3);
    await Simulator.endSimulation();
  });

  test('reg1 bit2 BURSTDET-seen CLEAR does not wedge the control plane', () async {
    // The firmware-writable BURSTDET/DATAVALID-seen clear (reg1 CTL bit2) lets the
    // FSBL use BURSTDET as a per-step read-level oracle to PIN the DQSBUFM read
    // pointer per boot. The sticky itself is fed by the DQSBUFM leaf (X in sim), so
    // this guards the CONTROL path: a reg1-bit2 write must flip the clear toggle,
    // cross to sclk as a one-cycle pulse, and NOT hang the register block. After
    // the clear, a normal SET walk + STATUS read must still complete.
    await bringUp();
    // Write reg1 with bit2 set (CLEAR), bits0/1 clear (no SET/LOAD).
    await wbWrite(ctl, 0x4);
    await wbWrite(ctl, 0x4); // a second edge -> a second clear pulse
    // The control plane is still alive: a SET walk to a tap still completes.
    await wbWrite(rdtapTarget, 8);
    await wbWrite(ctl, 0x1); // SET
    var st = 0;
    for (var i = 0; i < 200; i++) {
      st = await wbReadStatusLow();
      if (st & 0x1 == 0) break;
    }
    expect(
      st & 0x1,
      0,
      reason: 'controller idle after a clear + walk (no wedge)',
    );
    expect((st >> 1) & 0x7F, 8, reason: 'the SET walk still reaches its tap');
    await Simulator.endSimulation();
  });
}
