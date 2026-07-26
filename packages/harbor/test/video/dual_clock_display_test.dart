import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// End-to-end dual-clock display on a tiny 4x2 mode: pixel-domain timing drives
/// the dual-clock scanout, which bursts from a fake system-side memory
/// (address-as-data). After a couple of frames the buffers are primed, so every
/// active pixel must equal fbBase + y*stride + x*4.
void main() {
  const timing = HarborDisplayTiming(
    hActive: 4,
    hFrontPorch: 1,
    hSyncWidth: 1,
    hBackPorch: 1,
    vActive: 2,
    vFrontPorch: 1,
    vSyncWidth: 1,
    vBackPorch: 1,
    pixelClock: 1000000,
  );
  const hTotal = 7;
  const vTotal = 5;
  const stride = 16;
  const fbBase = 0x100;

  test('scans shared memory out as RGB across two clocks', () async {
    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final disp = HarborDualClockDisplay(
      timing: timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      shiftClk: sysClk, // gpdi not checked here, any clock suffices for shift
      shiftReset: sysReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: enable,
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
    );
    mAck <= disp.mStb;
    mDataIn <= disp.mAddr;
    await disp.build();

    pixelReset.inject(1);
    sysReset.inject(1);
    enable.inject(1);
    base.inject(fbBase);
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    // Run two full frames so frame-start priming has settled across the CDC.
    for (var i = 0; i < hTotal * vTotal * 2; i++) {
      await pixelClk.nextPosedge;
    }

    var checked = 0;
    for (var i = 0; i < hTotal * vTotal; i++) {
      await pixelClk.nextNegedge;
      if (disp.de.value.toInt() == 1) {
        final x = disp.x.value.toInt();
        final y = disp.y.value.toInt();
        expect(
          disp.pixelWord.value.toInt(),
          equals(fbBase + y * stride + x * 4),
          reason: 'active pixel ($x,$y)',
        );
        checked++;
      }
      await pixelClk.nextPosedge;
    }
    expect(checked, equals(8));

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
