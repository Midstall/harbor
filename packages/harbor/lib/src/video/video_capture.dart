import 'dart:async';

import 'package:rohd/rohd.dart';

import '../soc/target.dart';

import '../peripherals/display.dart';
import 'framebuffer_display.dart';

/// A captured video frame: [width] x [height] pixels as 0xAARRGGBB words.
class CapturedFrame {
  final int width;
  final int height;
  final List<int> argb;

  const CapturedFrame({
    required this.width,
    required this.height,
    required this.argb,
  });
}

/// Capture top: a [HarborFramebufferDisplay] driven by a ROM holding the
/// framebuffer, single clock. Exposes the video signals for sampling.
class _CaptureTop extends Module {
  Logic get de => output('de');
  Logic get x => output('x');
  Logic get y => output('y');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  _CaptureTop(
    Logic clk,
    Logic reset,
    HarborDisplayTiming timing,
    List<int> framebuffer,
  ) : super(definitionName: 'VideoCaptureTop') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;
    addOutput('de');
    addOutput('x', width: hbits);
    addOutput('y', width: vbits);
    addOutput('red', width: 8);
    addOutput('green', width: 8);
    addOutput('blue', width: 8);

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');
    final disp = HarborFramebufferDisplay(
      // A capture helper only ever runs in a simulation.
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      enable: Const(1),
      fbBase: Const(0, width: 32),
      mDataIn: mDataIn,
      mAck: mAck,
    );

    // Combinational ROM: address-as-index into the framebuffer words.
    final words = framebuffer.length;
    final idxW = (words - 1).bitLength < 1 ? 1 : (words - 1).bitLength;
    final wIdx = disp.mAddr.getRange(2, 2 + idxW);
    Logic d = Const(0, width: 32);
    for (var i = 0; i < words; i++) {
      d = mux(wIdx.eq(i), Const(framebuffer[i], width: 32), d);
    }
    mAck <= disp.mStb;
    mDataIn <= d;

    output('de') <= disp.de;
    output('x') <= disp.x;
    output('y') <= disp.y;
    output('red') <= disp.red;
    output('green') <= disp.green;
    output('blue') <= disp.blue;
  }
}

/// Runs the framebuffer display in simulation and returns one rendered frame.
///
/// This is the pure-Dart bridge a Flutter app uses to show the video generator:
/// no hardware, just the ROHD simulator scanning the [framebuffer] out through
/// the real display datapath. The first frame after reset is unprimed, so the
/// second frame is captured.
Future<CapturedFrame> captureFramebufferFrame({
  required HarborDisplayTiming timing,
  required List<int> framebuffer,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final top = _CaptureTop(clk, reset, timing, framebuffer);
  await top.build();

  final w = timing.hActive;
  final h = timing.vActive;
  final argb = List<int>.filled(w * h, 0xFF000000);

  reset.inject(1);
  Simulator.setMaxSimTime(1 << 30);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextNegedge;

  final frameCycles = timing.hTotal * timing.vTotal;
  // Skip the first (unprimed) frame.
  for (var i = 0; i < frameCycles; i++) {
    await clk.nextPosedge;
  }
  // Capture the second frame's active pixels.
  for (var i = 0; i < frameCycles; i++) {
    await clk.nextNegedge;
    if (top.de.value.toInt() == 1) {
      final px = top.x.value.toInt();
      final py = top.y.value.toInt();
      if (px < w && py < h) {
        final r = top.red.value.toInt();
        final g = top.green.value.toInt();
        final b = top.blue.value.toInt();
        argb[py * w + px] = 0xFF000000 | (r << 16) | (g << 8) | b;
      }
    }
    await clk.nextPosedge;
  }

  await Simulator.endSimulation();
  Simulator.reset();

  return CapturedFrame(width: w, height: h, argb: argb);
}
