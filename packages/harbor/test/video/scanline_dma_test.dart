import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the scanline DMA's fetch core: it reads `words` sequential 32-bit
/// words over a Wishbone-style master port into a line buffer, then serves them
/// by column. The fake memory acks combinationally and returns the requested
/// address as data, so buffer[col] must equal base + col*4.
void main() {
  late Logic clk, reset, start, base, words, col;
  late HarborScanlineDma dma;

  Future<void> setup() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    start = Logic(name: 'start');
    base = Logic(name: 'base', width: 32);
    words = Logic(name: 'words', width: 16);
    col = Logic(name: 'col', width: 4);

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');
    dma = HarborScanlineDma(
      clk: clk,
      reset: reset,
      start: start,
      base: base,
      words: words,
      col: col,
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: 8,
    );
    // Fake memory: 0-latency ack, data = requested address.
    mAck <= dma.mStb;
    mDataIn <= dma.mAddr;
    await dma.build();

    reset.inject(1);
    start.inject(0);
    base.inject(0);
    words.inject(0);
    col.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;
  }

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('fetches a scanline and serves it by column', () async {
    await setup();
    expect(dma.ready.value.toInt(), equals(0));

    base.inject(0x40);
    words.inject(4);
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);

    // Let the fetch run to completion.
    var guard = 0;
    while (dma.ready.value.toInt() == 0 && guard < 50) {
      await clk.nextPosedge;
      guard++;
    }
    await clk.nextNegedge;
    expect(dma.ready.value.toInt(), equals(1), reason: 'fetch should finish');
    expect(dma.busy.value.toInt(), equals(0));

    for (var c = 0; c < 4; c++) {
      col.inject(c);
      await clk.nextNegedge;
      expect(dma.pixel.value.toInt(), equals(0x40 + c * 4), reason: 'col $c');
    }
  });

  test('a new start re-fetches a different region', () async {
    await setup();

    Future<void> fetch(int baseAddr, int n) async {
      base.inject(baseAddr);
      words.inject(n);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (dma.ready.value.toInt() == 0 && guard < 50) {
        await clk.nextPosedge;
        guard++;
      }
      await clk.nextNegedge;
    }

    await fetch(0x40, 4);
    expect(dma.ready.value.toInt(), equals(1));

    // Second fetch from a new base, ready must drop then re-assert with new data.
    await fetch(0x2000, 3);
    expect(dma.ready.value.toInt(), equals(1));
    for (var c = 0; c < 3; c++) {
      col.inject(c);
      await clk.nextNegedge;
      expect(dma.pixel.value.toInt(), equals(0x2000 + c * 4), reason: 'col $c');
    }
  });
}
