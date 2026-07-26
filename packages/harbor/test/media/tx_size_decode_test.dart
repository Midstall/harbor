import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/tx_size_decode.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden tx_size for the SELECT path of _readTxSize, captured from the SW port
// (bsizeToTxSizeCat/MaxDepth + default txSizeCdf.decodeN + depthToTxSize),
// 60 seeded iterations per block size.
const _golden8x8 = [
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  1,
  1,
  0,
  1,
  0,
  1,
  1,
  1,
  0,
  0,
  1,
  0,
  1,
  1,
  0,
  0,
  0,
  1,
  1,
  0,
  1,
  0,
  1,
  1,
  0,
  1,
  0,
  1,
  1,
  0,
  1,
  1,
  0,
  1,
  1,
  1,
  0,
  1,
  1,
  1,
  0,
  1,
  0,
  1,
  1,
  1,
  1,
];
const _golden16x16 = [
  2,
  2,
  1,
  2,
  0,
  1,
  2,
  1,
  1,
  2,
  1,
  2,
  2,
  1,
  1,
  1,
  1,
  1,
  2,
  1,
  0,
  1,
  1,
  1,
  2,
  2,
  0,
  1,
  2,
  1,
  1,
  1,
  1,
  2,
  1,
  1,
  1,
  2,
  1,
  1,
  1,
  1,
  2,
  0,
  1,
  2,
  2,
  1,
  1,
  1,
  1,
  2,
  1,
  1,
  2,
  2,
  1,
  2,
  2,
  1,
];
const _golden32x32 = [
  3,
  3,
  3,
  1,
  1,
  1,
  3,
  1,
  3,
  3,
  3,
  3,
  3,
  1,
  3,
  3,
  3,
  1,
  3,
  1,
  1,
  1,
  3,
  3,
  1,
  1,
  1,
  3,
  3,
  1,
  3,
  1,
  3,
  3,
  3,
  1,
  3,
  3,
  3,
  1,
  2,
  1,
  3,
  1,
  3,
  3,
  3,
  1,
  1,
  1,
  3,
  1,
  1,
  3,
  1,
  3,
  3,
  1,
  3,
  3,
];
// kBlock4x4=0 maxTxRect[0]=0

// av1_tables constants embedded (SW source of truth).
const _kBlock4x4 = 0;
const _kBlock8x8 = 3;
const _kBlock16x16 = 6;
const _maxTxsizeRect4x4 = 0; // maxTxsizeRectLookup[BLOCK_4X4] == TX_4X4.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 16;

  BigInt pk(List<int> b) {
    var v = BigInt.zero;
    for (var i = 0; i < b.length; i++) {
      v |= BigInt.from(b[i] & 0xff) << (i * 8);
    }
    return v;
  }

  Future<void> runCase(int bSize, int seed, List<int> golden) async {
    final t = HarborTxSizeDecode(bSize: bSize, maxBytes: maxBytes);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final bytes = Logic(name: 'bytes', width: maxBytes * 8);
    final ctx = Logic(name: 'ctx', width: 2);
    t.input('clk').srcConnection! <= clk;
    t.input('reset').srcConnection! <= reset;
    t.input('start').srcConnection! <= start;
    t.input('bytes').srcConnection! <= bytes;
    t.input('ctx').srcConnection! <= ctx;
    await t.build();
    reset.inject(1);
    start.inject(0);
    bytes.inject(0);
    ctx.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    final rng = Random(seed);
    for (var iter = 0; iter < 60; iter++) {
      final b = [for (var i = 0; i < maxBytes; i++) rng.nextInt(256)];
      final cx = rng.nextInt(3); // ctx 0..2
      final want = golden[iter];
      bytes.inject(pk(b));
      ctx.inject(cx);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var g = 0;
      while (t.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++g > 100) fail('timeout iter=$iter');
      }
      expect(
        t.output('tx_size').value.toInt(),
        want,
        reason: 'bSize=$bSize iter=$iter ctx=$cx',
      );
      await clk.nextPosedge;
    }
    await Simulator.endSimulation();
  }

  test('HarborTxSizeDecode matches _readTxSize SELECT for BLOCK_8X8', () async {
    await runCase(_kBlock8x8, 0x7a11, _golden8x8);
  });

  test(
    'HarborTxSizeDecode matches _readTxSize SELECT for BLOCK_16X16',
    () async {
      await runCase(_kBlock16x16, 0x3c0d, _golden16x16);
    },
  );

  // BLOCK_32X32 (cat 3, the 5-symbol CDF row, maxDepth 2).
  test(
    'HarborTxSizeDecode matches _readTxSize SELECT for BLOCK_32X32',
    () async {
      await runCase(9, 0x9f22, _golden32x32);
    },
  );

  // BLOCK_4X4 (maxDepth 0): no coded symbol, const max_txsize_rect_lookup.
  test(
    'HarborTxSizeDecode emits const tx_size for non-signalling BLOCK_4X4',
    () async {
      final t = HarborTxSizeDecode(bSize: _kBlock4x4, maxBytes: maxBytes);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final ctx = Logic(name: 'ctx', width: 2);
      t.input('clk').srcConnection! <= clk;
      t.input('reset').srcConnection! <= reset;
      t.input('start').srcConnection! <= start;
      t.input('bytes').srcConnection! <= bytes;
      t.input('ctx').srcConnection! <= ctx;
      await t.build();
      reset.inject(1);
      start.inject(0);
      bytes.inject(0);
      ctx.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var g = 0;
      while (t.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++g > 100) fail('timeout');
      }
      // _readTxSize: maxTxsizeRectLookup[BLOCK_4X4] == TX_4X4 (0).
      expect(t.output('tx_size').value.toInt(), _maxTxsizeRect4x4);
      await Simulator.endSimulation();
    },
  );
}
