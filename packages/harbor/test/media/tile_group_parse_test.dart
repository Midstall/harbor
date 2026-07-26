import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// HarborTileGroupParse splits a tile_group OBU payload into per-tile (offset,
// size) slices. The golden is computed directly from the assembled payload (the
// test knows what it wrote), covering single-tile and the multi-tile
// tile_start_and_end_present == 0 path with 1- and 2-byte tile sizes.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const bufBytes = 256, maxTiles = 8, cw = 12;

  // Build a tile_group payload for the given tile sizes, return (bytes,
  // expectedOffsets, expectedSizes).
  (List<int>, List<int>, List<int>) build(
    Random rng,
    List<int> tileSizes,
    int tileSizeBytes,
  ) {
    final n = tileSizes.length;
    final bytes = <int>[];
    final offsets = <int>[];
    final offOut = <int>[];
    if (n > 1) {
      bytes.add(
        0x00,
      ); // tile_start_and_end_present_flag = 0 (MSB), byte-aligned
    }
    for (var i = 0; i < n; i++) {
      final last = i == n - 1;
      if (!last) {
        var v = tileSizes[i] - 1; // tile_size_minus_1, little-endian
        for (var b = 0; b < tileSizeBytes; b++) {
          bytes.add(v & 0xff);
          v >>= 8;
        }
      }
      offsets.add(bytes.length); // tile data offset
      offOut.add(bytes.length);
      for (var b = 0; b < tileSizes[i]; b++) {
        bytes.add(rng.nextInt(256));
      }
    }
    return (bytes, offOut, tileSizes);
  }

  test('HarborTileGroupParse: single + multi tile slices', () async {
    final p = HarborTileGroupParse(bufBytes: bufBytes, maxTiles: maxTiles);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final bytes = Logic(name: 'bytes', width: bufBytes * 8);
    final sz = Logic(name: 'sz', width: cw);
    final numTiles = Logic(name: 'num_tiles', width: 8);
    final tsb = Logic(name: 'tsb', width: 3);

    p.input('clk').srcConnection! <= clk;
    p.input('reset').srcConnection! <= reset;
    p.input('start').srcConnection! <= start;
    p.input('bytes').srcConnection! <= bytes;
    p.input('sz').srcConnection! <= sz;
    p.input('num_tiles').srcConnection! <= numTiles;
    p.input('tile_size_bytes').srcConnection! <= tsb;
    await p.build();

    reset.inject(1);
    start.inject(0);
    bytes.inject(0);
    sz.inject(0);
    numTiles.inject(1);
    tsb.inject(1);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;

    BigInt pack(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    int slot(String name, int i) =>
        ((p.output(name).value.toBigInt() >> (i * cw)) &
                BigInt.from((1 << cw) - 1))
            .toInt();

    final rng = Random(0x711E);
    final cases = <(List<int>, int)>[
      ([20], 1), // single tile
      ([7], 2), // single tile (tsb irrelevant)
      ([5, 9], 1), // two tiles, 1-byte sizes
      ([10, 4, 6], 1), // three tiles
      ([12, 8], 2), // two tiles, 2-byte sizes
      ([3, 5, 7, 9], 1), // four tiles
    ];

    for (var ci = 0; ci < cases.length; ci++) {
      final (tileSizes, tileSizeBytes) = cases[ci];
      final (buf, expOff, expSize) = build(rng, tileSizes, tileSizeBytes);
      expect(buf.length <= bufBytes, isTrue, reason: 'case $ci too big');

      reset.inject(1);
      bytes.inject(pack(buf));
      sz.inject(buf.length);
      numTiles.inject(tileSizes.length);
      tsb.inject(tileSizeBytes);
      await clk.nextPosedge;
      reset.inject(0);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (p.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 1000) fail('timeout case=$ci');
      }
      expect(
        p.output('unsupported').value.toInt(),
        equals(0),
        reason: 'case $ci unsupported',
      );
      expect(
        p.output('tile_count').value.toInt(),
        equals(tileSizes.length),
        reason: 'case $ci tile_count',
      );
      for (var i = 0; i < tileSizes.length; i++) {
        expect(
          slot('tile_offsets', i),
          equals(expOff[i]),
          reason: 'case $ci tile $i offset',
        );
        expect(
          slot('tile_sizes', i),
          equals(expSize[i]),
          reason: 'case $ci tile $i size',
        );
      }
    }
    await Simulator.endSimulation();
  });
}
