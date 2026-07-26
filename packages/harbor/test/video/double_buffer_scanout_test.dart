import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the double-buffer ping-pong scanout: a frameStart primes two line
/// buffers, then each lineStart swaps to the prefetched buffer while the DMA
/// fills the freed one with the next row. Fake memory returns address-as-data,
/// so row r column c reads back as fbBase + r*stride + c*4.
void main() {
  late Logic clk, reset, frameStart, lineStart, col, fbBase, stride, words;
  late HarborDoubleBufferScanout so;

  Future<void> setup() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    frameStart = Logic(name: 'frame_start');
    lineStart = Logic(name: 'line_start');
    col = Logic(name: 'col', width: 4);
    fbBase = Logic(name: 'fb_base', width: 32);
    stride = Logic(name: 'stride', width: 32);
    words = Logic(name: 'words', width: 16);

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');
    so = HarborDoubleBufferScanout(
      clk: clk,
      reset: reset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: col,
      fbBase: fbBase,
      stride: stride,
      wordsPerLine: words,
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: 4,
    );
    // Fake memory: 0-latency ack, data = requested address.
    mAck <= so.mStb;
    mDataIn <= so.mAddr;
    await so.build();

    reset.inject(1);
    frameStart.inject(0);
    lineStart.inject(0);
    col.inject(0);
    fbBase.inject(0x100);
    stride.inject(16);
    words.inject(4);
    Simulator.setMaxSimTime(5000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;
  }

  Future<void> tick(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
  }

  Future<void> pulse(Logic sig) async {
    sig.inject(1);
    await clk.nextPosedge;
    sig.inject(0);
    await clk.nextNegedge;
  }

  Future<void> expectRow(int row) async {
    for (var c = 0; c < 4; c++) {
      col.inject(c);
      await clk.nextNegedge;
      expect(
        so.pixel.value.toInt(),
        equals(0x100 + row * 16 + c * 4),
        reason: 'row $row col $c',
      );
    }
  }

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('primes two buffers and ping-pongs across rows', () async {
    await setup();

    await pulse(frameStart);
    await tick(30); // priming: fetch row0 -> buf0, row1 -> buf1
    await expectRow(0);
    expect(so.underrun.value.toInt(), equals(0));

    await pulse(lineStart);
    await tick(30); // swap to buf1 (row1); fetch row2 -> buf0
    await expectRow(1);

    await pulse(lineStart);
    await tick(30); // swap to buf0 (row2); fetch row3 -> buf1
    await expectRow(2);

    expect(so.underrun.value.toInt(), equals(0));
  });
}
