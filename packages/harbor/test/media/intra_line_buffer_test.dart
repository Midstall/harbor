import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

BigInt _packPix(List<int> px) {
  var v = BigInt.zero;
  for (var i = 0; i < px.length; i++) {
    v |= BigInt.from(px[i] & 0xFF) << (i * 8);
  }
  return v;
}

List<int> _unpackPix(BigInt v, int n) => [
  for (var i = 0; i < n; i++) ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraLineBuffer', () {
    late HarborIntraLineBuffer lb;
    late Logic clk, reset, size, bwCol, store, newRow, bottom, right;
    const fill = 128;

    Future<void> setUpDut() async {
      lb = HarborIntraLineBuffer(maxBlockCols: 4);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      size = Logic(name: 'size');
      bwCol = Logic(name: 'bw_col', width: 2);
      store = Logic(name: 'store');
      newRow = Logic(name: 'new_row');
      bottom = Logic(name: 'bottom', width: 64);
      right = Logic(name: 'right', width: 64);

      lb.input('clk').srcConnection! <= clk;
      lb.input('reset').srcConnection! <= reset;
      lb.input('size').srcConnection! <= size;
      lb.input('bw_col').srcConnection! <= bwCol;
      lb.input('store').srcConnection! <= store;
      lb.input('new_row').srcConnection! <= newRow;
      lb.input('block_bottom').srcConnection! <= bottom;
      lb.input('block_right').srcConnection! <= right;

      await lb.build();
      reset.inject(1);
      size.inject(1); // 8x8
      bwCol.inject(0);
      store.inject(0);
      newRow.inject(0);
      bottom.inject(0);
      right.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    test('reset fills neighbours with the default', () async {
      await setUpDut();
      expect(
        _unpackPix(lb.output('above').value.toBigInt(), 8),
        equals(List.filled(8, fill)),
      );
      expect(
        _unpackPix(lb.output('left').value.toBigInt(), 8),
        equals(List.filled(8, fill)),
      );
      expect(lb.output('above_left').value.toInt(), equals(fill));
      await Simulator.endSimulation();
    });

    test('stores bottom rows that the row below reads as above', () async {
      await setUpDut();
      // First block row: store a distinct bottom row per block column.
      final rows = [
        for (var p = 0; p < 4; p++)
          [for (var i = 0; i < 8; i++) p * 16 + i + 1],
      ];
      final rights = [
        for (var p = 0; p < 4; p++) [for (var i = 0; i < 8; i++) p * 8 + i + 9],
      ];

      newRow.inject(1);
      await clk.nextPosedge;
      newRow.inject(0);

      for (var p = 0; p < 4; p++) {
        bwCol.inject(p);
        bottom.inject(_packPix(rows[p]));
        right.inject(_packPix(rights[p]));
        store.inject(1);
        await clk.nextPosedge;
        store.inject(0);
        await clk.nextPosedge;
      }

      // Second block row: each column's "above" is the bottom row stored above.
      newRow.inject(1);
      await clk.nextPosedge;
      newRow.inject(0);
      // After new_row, left/corner reset to fill (no left neighbour yet).
      bwCol.inject(0);
      await clk.nextPosedge;
      expect(
        _unpackPix(lb.output('above').value.toBigInt(), 8),
        equals(rows[0]),
      );
      expect(
        _unpackPix(lb.output('left').value.toBigInt(), 8),
        equals(List.filled(8, fill)),
      );
      expect(lb.output('above_left').value.toInt(), equals(fill));

      bwCol.inject(2);
      await clk.nextPosedge;
      expect(
        _unpackPix(lb.output('above').value.toBigInt(), 8),
        equals(rows[2]),
      );
      await Simulator.endSimulation();
    });

    test('corner delay feeds the next block above-left, left rotates', () async {
      await setUpDut();
      final rows = [
        for (var p = 0; p < 4; p++)
          [for (var i = 0; i < 8; i++) p * 20 + i + 3],
      ];
      final rights = [
        for (var p = 0; p < 4; p++)
          [for (var i = 0; i < 8; i++) p * 10 + i + 7],
      ];

      // Prime the slots as if a row above had been decoded.
      newRow.inject(1);
      await clk.nextPosedge;
      newRow.inject(0);
      for (var p = 0; p < 4; p++) {
        bwCol.inject(p);
        bottom.inject(_packPix(rows[p]));
        right.inject(_packPix(rights[p]));
        store.inject(1);
        await clk.nextPosedge;
        store.inject(0);
        await clk.nextPosedge;
      }

      // New row: process block 0, then block 1 should see block 0's right
      // column as its left, and the row-above block 0 bottom-right as corner.
      newRow.inject(1);
      await clk.nextPosedge;
      newRow.inject(0);

      // Store the new-row block 0 (fresh bottom/right).
      final newRow0Bottom = [for (var i = 0; i < 8; i++) 200 + i];
      final newRow0Right = [for (var i = 0; i < 8; i++) 150 + i];
      bwCol.inject(0);
      bottom.inject(_packPix(newRow0Bottom));
      right.inject(_packPix(newRow0Right));
      store.inject(1);
      await clk.nextPosedge;
      store.inject(0);
      await clk.nextPosedge;

      // Now fetch block 1: left = new-row block 0's right column, above_left =
      // the OLD (row above) block 0 bottom-right pixel, preserved by the delay.
      bwCol.inject(1);
      await clk.nextPosedge;
      expect(
        _unpackPix(lb.output('left').value.toBigInt(), 8),
        equals(newRow0Right),
      );
      expect(lb.output('above_left').value.toInt(), equals(rows[0][7]));
      // And above is still the row-above slot 1 (not yet overwritten).
      expect(
        _unpackPix(lb.output('above').value.toBigInt(), 8),
        equals(rows[1]),
      );
      await Simulator.endSimulation();
    });
  });
}
