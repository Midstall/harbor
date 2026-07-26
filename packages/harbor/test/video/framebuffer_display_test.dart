import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// End-to-end framebuffer display test on a tiny 4x2 mode: timing generator +
/// double-buffer scanout + RGB output. Fake memory returns address-as-data, so
/// during active video the pixel word must equal fbBase + y*stride + x*4. The
/// first frame after reset is unprimed. By the second frame the buffers are
/// primed, so we check pixels there.
void main() {
  // 4 active columns, 2 active rows, tiny porches so a frame is ~35 cycles.
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
  const stride = 16; // 4 words * 4 bytes
  const fbBase = 0x100;

  test('scans the framebuffer out as RGB on a primed frame', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final disp = HarborFramebufferDisplay(
      timing: timing,
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      enable: enable,
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
    );
    // Fake memory: 0-latency ack, data = requested address.
    mAck <= disp.mStb;
    mDataIn <= disp.mAddr;
    await disp.build();

    reset.inject(1);
    enable.inject(1);
    base.inject(fbBase);
    Simulator.setMaxSimTime(10000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;

    // Run one full frame so the frame-start prime happens during its vblank.
    for (var i = 0; i < hTotal * vTotal; i++) {
      await clk.nextPosedge;
    }

    // Over the next (primed) frame, every active pixel must match the buffer.
    var checked = 0;
    for (var i = 0; i < hTotal * vTotal; i++) {
      await clk.nextNegedge;
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
      await clk.nextPosedge;
    }
    expect(checked, equals(8), reason: '4x2 = 8 active pixels');

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
