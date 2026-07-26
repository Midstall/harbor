import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Drives an [Ecp5DelayController] and verifies it walks the tracked tap to a
/// CPU-set target with the correct number of MOVE pulses and DIRECTION, reloads
/// on LOADN, and matches the DELAYF's edge-stepping contract (one tap step per
/// MOVE rising edge).
class _Harness {
  final Logic clk;
  final Logic reset;
  final Logic targetTap;
  final Logic setStrobe;
  final Logic loadStrobe;
  final Ecp5DelayController dut;

  _Harness._(
    this.clk,
    this.reset,
    this.targetTap,
    this.setStrobe,
    this.loadStrobe,
    this.dut,
  );

  static Future<_Harness> make({int initialTap = 0, int tapWidth = 7}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final targetTap = Logic(name: 'target', width: tapWidth);
    final setStrobe = Logic(name: 'set');
    final loadStrobe = Logic(name: 'load');
    final dut = Ecp5DelayController(
      clk,
      reset,
      targetTap: targetTap,
      setStrobe: setStrobe,
      loadStrobe: loadStrobe,
      initialTap: initialTap,
      tapWidth: tapWidth,
    );
    reset.inject(1);
    targetTap.inject(0);
    setStrobe.inject(0);
    loadStrobe.inject(0);
    await dut.build();
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    return _Harness._(clk, reset, targetTap, setStrobe, loadStrobe, dut);
  }

  int get cur => dut.currentTap.value.toInt();
  bool get busy => dut.busy.value.toBool();

  /// Set a target and run until the controller is idle, count MOVE rising edges
  /// and record the DIRECTION seen during the walk. Returns (moveEdges, lastDir).
  /// move is sampled AFTER each posedge (when the FSM state has settled) and
  /// prevMove starts at the pre-strobe (idle, 0) value, so the very first MOVE
  /// edge is counted.
  Future<(int, int)> walkTo(int target, {int maxCycles = 4000}) async {
    targetTap.inject(target);
    var edges = 0;
    var lastDir = dut.direction.value.toInt();
    var prevMove = dut.move.value.toBool(); // idle: 0
    setStrobe.inject(1);
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      if (i == 0) setStrobe.inject(0); // hold the strobe for exactly one cycle
      final m = dut.move.value.toBool();
      if (m && !prevMove) {
        edges++;
        lastDir = dut.direction.value.toInt();
      }
      prevMove = m;
      if (!busy) break;
    }
    return (edges, lastDir);
  }
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('reset state: tracked tap = initialTap, idle, no move', () async {
    final h = await _Harness.make(initialTap: 8);
    expect(h.cur, 8);
    expect(h.busy, isFalse);
    expect(h.dut.move.value.toBool(), isFalse);
    expect(h.dut.loadn.value.toBool(), isTrue); // not loading
  });

  test('walk up: one MOVE edge per step, direction = up (0)', () async {
    final h = await _Harness.make(initialTap: 0);
    final (edges, dir) = await h.walkTo(20);
    expect(h.cur, 20, reason: 'tracked tap should reach target');
    expect(edges, 20, reason: 'one MOVE rising edge per tap step');
    expect(dir, 0, reason: 'increasing tap -> DIRECTION up (0)');
    expect(h.busy, isFalse);
  });

  test('walk down: correct edges, direction = down (1)', () async {
    final h = await _Harness.make(initialTap: 40);
    final (edges, dir) = await h.walkTo(25);
    expect(h.cur, 25);
    expect(edges, 15, reason: '|40-25| steps');
    expect(dir, 1, reason: 'decreasing tap -> DIRECTION down (1)');
  });

  test('target == current: no movement', () async {
    final h = await _Harness.make(initialTap: 12);
    final (edges, _) = await h.walkTo(12, maxCycles: 50);
    expect(edges, 0);
    expect(h.cur, 12);
    expect(h.busy, isFalse);
  });

  test('loadStrobe reloads tracked tap to initialTap', () async {
    final h = await _Harness.make(initialTap: 5);
    await h.walkTo(30);
    expect(h.cur, 30);
    // Now reload.
    h.loadStrobe.inject(1);
    await h.clk.nextPosedge;
    h.loadStrobe.inject(0);
    // LOADN must assert (low) for a cycle during the reload.
    var sawLoadn = false;
    for (var i = 0; i < 8; i++) {
      if (!h.dut.loadn.value.toBool()) sawLoadn = true;
      await h.clk.nextPosedge;
    }
    expect(sawLoadn, isTrue, reason: 'LOADN pulses low on reload');
    expect(h.cur, 5, reason: 'tracked tap returns to initialTap');
  });

  test('full-range walk to max tap (127)', () async {
    final h = await _Harness.make(initialTap: 0);
    final (edges, _) = await h.walkTo(127, maxCycles: 4000);
    expect(h.cur, 127);
    expect(edges, 127);
  });
}
