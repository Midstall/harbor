import 'dart:async';
import 'dart:math' as math;

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _tileLog2(int blk, int target) {
  var k = 0;
  while ((blk << k) < target) {
    k++;
  }
  return k;
}

class _TI {
  _TI({
    required this.miCols,
    required this.miRows,
    required this.use128,
    this.colInc = 0,
    this.rowInc = 0,
    this.ctxId = 0,
    this.tsbMinus1 = 0,
  });
  final int miCols, miRows, use128, colInc, rowInc, ctxId, tsbMinus1;
}

(List<int>, Map<String, int>) _build(_TI s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  final sbCols = s.use128 == 1 ? (s.miCols + 31) >> 5 : (s.miCols + 15) >> 4;
  final sbRows = s.use128 == 1 ? (s.miRows + 31) >> 5 : (s.miRows + 15) >> 4;
  final maxTileWidthSb = s.use128 == 1 ? 32 : 64;
  final maxTileAreaSb = s.use128 == 1 ? 576 : 2304;
  final minLog2TileCols = _tileLog2(maxTileWidthSb, sbCols);
  final maxLog2TileCols = _tileLog2(1, math.min(sbCols, 64));
  final maxLog2TileRows = _tileLog2(1, math.min(sbRows, 64));
  final minLog2Tiles = math.max(
    minLog2TileCols,
    _tileLog2(maxTileAreaSb, sbRows * sbCols),
  );

  f(1, 1); // uniform_tile_spacing_flag = 1
  var colLog2 = minLog2TileCols;
  var added = 0;
  while (colLog2 < maxLog2TileCols) {
    if (added < s.colInc) {
      f(1, 1);
      colLog2++;
      added++;
    } else {
      f(0, 1);
      break;
    }
  }
  final minLog2TileRows = math.max(minLog2Tiles - colLog2, 0);
  var rowLog2 = minLog2TileRows;
  added = 0;
  while (rowLog2 < maxLog2TileRows) {
    if (added < s.rowInc) {
      f(1, 1);
      rowLog2++;
      added++;
    } else {
      f(0, 1);
      break;
    }
  }
  final anyTiles = colLog2 > 0 || rowLog2 > 0;
  var ctxId = 0, tileSizeBytes = 1;
  if (anyTiles) {
    f(s.ctxId, colLog2 + rowLog2);
    f(s.tsbMinus1, 2);
    ctxId = s.ctxId;
    tileSizeBytes = s.tsbMinus1 + 1;
  }

  return (
    bits,
    {
      'uniform_tile_spacing_flag': 1,
      'tile_cols_log2': colLog2,
      'tile_rows_log2': rowLog2,
      'tile_cols': 1 << colLog2,
      'tile_rows': 1 << rowLog2,
      'context_update_tile_id': ctxId,
      'tile_size_bytes': tileSizeBytes,
      'bits_consumed': bits.length,
    },
  );
}

List<int> _bytes(List<int> bits) {
  final out = List.filled(16, 0);
  for (var i = 0; i < bits.length && i < 128; i++) {
    if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborTileInfoParser', () {
    late HarborTileInfoParser p;
    late Logic clk, bytes, miCols, miRows, use128;

    Future<void> setUpDut() async {
      p = HarborTileInfoParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      miCols = Logic(name: 'mi_cols', width: 16);
      miRows = Logic(name: 'mi_rows', width: 16);
      use128 = Logic(name: 'use_128x128_superblock', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('mi_cols').srcConnection! <= miCols;
      p.input('mi_rows').srcConnection! <= miRows;
      p.input('use_128x128_superblock').srcConnection! <= use128;
      await p.build();
      bytes.inject(0);
      miCols.inject(16);
      miRows.inject(16);
      use128.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt pack(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    // MiCols/MiRows for common sizes: Mi = 2*((dim+7)>>3).
    int mi(int dim) => 2 * ((dim + 7) >> 3);

    final cases = <(String, _TI)>[
      ('64x64 single tile', _TI(miCols: mi(64), miRows: mi(64), use128: 0)),
      ('1080p no split', _TI(miCols: mi(1920), miRows: mi(1080), use128: 0)),
      (
        '1080p 4 cols 2 rows',
        _TI(
          miCols: mi(1920),
          miRows: mi(1080),
          use128: 0,
          colInc: 2,
          rowInc: 1,
          ctxId: 3,
          tsbMinus1: 1,
        ),
      ),
      (
        '1080p max cols',
        _TI(
          miCols: mi(1920),
          miRows: mi(1080),
          use128: 0,
          colInc: 9,
          rowInc: 0,
          ctxId: 7,
          tsbMinus1: 0,
        ),
      ),
      (
        '4k 128sb split',
        _TI(
          miCols: mi(3840),
          miRows: mi(2160),
          use128: 1,
          colInc: 1,
          rowInc: 1,
          ctxId: 2,
          tsbMinus1: 3,
        ),
      ),
      (
        '720p cols only',
        _TI(
          miCols: mi(1280),
          miRows: mi(720),
          use128: 0,
          colInc: 3,
          rowInc: 0,
          ctxId: 5,
          tsbMinus1: 2,
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        miCols.inject(c.$2.miCols);
        miRows.inject(c.$2.miRows);
        use128.inject(c.$2.use128);
        await clk.nextPosedge;
        for (final key in exp.keys) {
          expect(
            p.output(key).value.toInt(),
            equals(exp[key]),
            reason: '${c.$1}: $key',
          );
        }
        await Simulator.endSimulation();
      });
    }
  });
}
