import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the video timing generator against VGA 640x480 timing
/// (hTotal 800, vTotal 525, negative sync). Sync windows:
///   hsync active over columns [656, 752). Vsync active over rows [490, 492).
void main() {
  late Logic clk, reset;
  late VideoTimingGenerator vtg;

  Future<void> setup() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    vtg = VideoTimingGenerator(
      timing: const HarborDisplayTiming.vga640x480(),
      clk: clk,
      reset: reset,
    );
    await vtg.build();
    reset.inject(1);
    Simulator.setMaxSimTime(100000000);
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

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('starts in the visible region at (0,0) with idle sync', () async {
    await setup();
    expect(vtg.de.value.toInt(), equals(1));
    expect(vtg.x.value.toInt(), equals(0));
    expect(vtg.y.value.toInt(), equals(0));
    // Negative polarity: idle high.
    expect(vtg.hsync.value.toInt(), equals(1));
    expect(vtg.vsync.value.toInt(), equals(1));
  });

  test('the column counter advances and tracks de', () async {
    await setup();
    await tick(10);
    expect(vtg.x.value.toInt(), equals(10));
    expect(vtg.de.value.toInt(), equals(1));

    // First blanking column.
    await tick(630); // x = 640
    expect(vtg.x.value.toInt(), equals(640));
    expect(vtg.de.value.toInt(), equals(0));
  });

  test('hsync asserts low across its window', () async {
    await setup();
    await tick(656); // start of hsync window
    expect(vtg.hsync.value.toInt(), equals(0));
    await tick(96); // x = 752, end of window
    expect(vtg.hsync.value.toInt(), equals(1));
  });

  test('a full line wraps the column and advances the row', () async {
    await setup();
    await tick(800); // one full line
    expect(vtg.x.value.toInt(), equals(0));
    expect(vtg.y.value.toInt(), equals(1));
  });
}
