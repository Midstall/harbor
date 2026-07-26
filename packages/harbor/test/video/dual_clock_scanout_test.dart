import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the dual-clock scanout: the pixel domain drives frameStart/lineStart/
/// col. The system domain bursts lines from a fake memory into the double line
/// buffer. A req/done toggle handshake crosses the two clocks. Fake memory
/// returns address-as-data, so row r column c reads back as fbBase+r*stride+c*4.
void main() {
  test('streams rows across two clocks via the handshake', () async {
    final pixelClk = SimpleClockGenerator(14).clk; // slower pixel clock
    final sysClk = SimpleClockGenerator(6).clk; // faster system/bus clock
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final frameStart = Logic(name: 'frame_start');
    final lineStart = Logic(name: 'line_start');
    final col = Logic(name: 'col', width: 2);
    final fbBase = Logic(name: 'fb_base', width: 32);
    final stride = Logic(name: 'stride', width: 32);
    final words = Logic(name: 'words', width: 16);

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final so = HarborDualClockScanout(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
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
    // Fake memory on the system side: 0-latency ack, data = address.
    mAck <= so.mStb;
    mDataIn <= so.mAddr;
    await so.build();

    pixelReset.inject(1);
    sysReset.inject(1);
    frameStart.inject(0);
    lineStart.inject(0);
    col.inject(0);
    fbBase.inject(0x100);
    stride.inject(16);
    words.inject(4);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    Future<void> pix(int n) async {
      for (var i = 0; i < n; i++) {
        await pixelClk.nextPosedge;
      }
      await pixelClk.nextNegedge;
    }

    Future<void> pulse(Logic s) async {
      s.inject(1);
      await pixelClk.nextPosedge;
      s.inject(0);
      await pixelClk.nextNegedge;
    }

    Future<void> expectRow(int row) async {
      for (var c = 0; c < 4; c++) {
        col.inject(c);
        await pixelClk.nextNegedge;
        expect(
          so.pixel.value.toInt(),
          equals(0x100 + row * 16 + c * 4),
          reason: 'row $row col $c',
        );
      }
    }

    await pulse(frameStart);
    await pix(40); // let the system domain prime both line buffers
    await expectRow(0);

    await pulse(lineStart);
    await pix(40);
    await expectRow(1);

    await pulse(lineStart);
    await pix(40);
    await expectRow(2);

    await Simulator.endSimulation();
    Simulator.reset();
  });
}
