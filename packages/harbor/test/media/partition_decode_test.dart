import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _OdEc {
  static const w = 32;
  static const mask = (1 << w) - 1;
  int dif = 0, rng = 0x8000, cnt = -15;
  final List<int> buf;
  int bptr = 0;
  _OdEc(this.buf) {
    dif = (1 << (w - 1)) - 1;
    rng = 0x8000;
    cnt = -15;
    _refill();
  }
  void _refill() {
    var s = 8 - cnt, p = 0;
    while (s >= 0 && p < 3) {
      final byte = bptr < buf.length ? buf[bptr] : 0;
      dif = (dif ^ (byte << s)) & mask;
      cnt += 8;
      s -= 8;
      p++;
      bptr++;
    }
  }

  int _ilog(int x) {
    var n = 0;
    while (x > 0) {
      n++;
      x >>= 1;
    }
    return n;
  }

  int decode(List<int> icdf, int nsyms) {
    final c = dif >> (w - 16);
    var v = rng, ret = -1, u = rng;
    do {
      u = v;
      ret++;
      v = ((rng >> 8) * (icdf[ret] >> 6)) >> 1;
      v += 4 * (nsyms - 1 - ret);
    } while (c < v);
    final r = u - v;
    dif = (dif - (v << (w - 16))) & mask;
    final d = 16 - _ilog(r);
    cnt -= d;
    dif = (((dif + 1) << d) - 1) & mask;
    rng = r << d;
    if (cnt < 0) _refill();
    return ret;
  }
}

const _half = {3: 1, 6: 2, 9: 4, 12: 8, 15: 16};
const _subsize = {
  3: [3, 2, 1, 0, 31, 31, 31, 31, 31, 31],
  6: [6, 5, 4, 3, 5, 5, 4, 4, 17, 16],
  9: [9, 8, 7, 6, 8, 8, 7, 7, 19, 18],
  12: [12, 11, 10, 9, 11, 11, 10, 10, 21, 20],
  15: [15, 14, 13, 12, 14, 14, 13, 13, 31, 31],
};
const _childData = {
  0: [
    [0, 0, 0, 0, 0],
  ],
  1: [
    [0, 0, 0, 0, 0],
    [1, 0, 0, 0, 0],
  ],
  2: [
    [0, 0, 0, 0, 0],
    [0, 0, 1, 0, 0],
  ],
  3: [
    [1, 0, 1, 0, 1],
    [1, 0, 0, 0, 1],
    [0, 0, 1, 0, 1],
    [0, 0, 0, 0, 1],
  ],
  4: [
    [0, 0, 0, 0, 1],
    [0, 0, 1, 0, 1],
    [1, 0, 0, 0, 0],
  ],
  5: [
    [0, 0, 0, 0, 0],
    [1, 0, 0, 0, 1],
    [1, 0, 1, 0, 1],
  ],
  6: [
    [0, 0, 0, 0, 1],
    [1, 0, 0, 0, 1],
    [0, 0, 1, 0, 0],
  ],
  7: [
    [0, 0, 0, 0, 0],
    [0, 0, 1, 0, 1],
    [1, 0, 1, 0, 1],
  ],
  8: [
    [0, 0, 0, 0, 0],
    [0, 1, 0, 0, 0],
    [0, 2, 0, 0, 0],
    [0, 3, 0, 0, 0],
  ],
  9: [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 1, 0],
    [0, 0, 0, 2, 0],
    [0, 0, 0, 3, 0],
  ],
};

List<int> _uniform(int n) {
  final v = [for (var i = 0; i < n; i++) 32768 - ((i + 1) * 32768 / n).round()];
  while (v.length < 16) {
    v.add(0);
  }
  return v;
}

// Reference: decode the partition tree from the stream (adapting CDF), emit
// leaves in the same order as the hardware tree.
List<(int, int, int)> _refPartition(
  List<int> buf,
  int sbSize,
  int miR,
  int miC,
) {
  final ec = _OdEc(buf);
  final cdf = _uniform(10);
  var count = 0;
  int decodePart() {
    final sym = ec.decode(cdf, 10);
    final speed = 2;
    final rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + speed;
    for (var i = 0; i < 9; i++) {
      final toward = i < sym ? 32768 : 0;
      if (cdf[i] <= toward) {
        cdf[i] += (toward - cdf[i]) >> rate;
      } else {
        cdf[i] -= (cdf[i] - toward) >> rate;
      }
    }
    if (count < 32) count++;
    return sym;
  }

  final emits = <(int, int, int)>[];
  void walk(int r, int c, int bsize) {
    if (r >= miR || c >= miC) return;
    if (bsize == 0) {
      emits.add((r, c, 0));
      return;
    }
    final part = decodePart();
    final half = _half[bsize]!;
    final quarter = half >> 1;
    final subMain = _subsize[bsize]![part];
    final subSplit = _subsize[bsize]![3];
    // SPLIT children are stored BR,BL,TR,TL (the tree pushes them reversed and
    // pops in raster order). Process them raster TL,TR,BL,BR here.
    final children = part == 3
        ? _childData[part]!.reversed.toList()
        : _childData[part]!;
    for (final ch in children) {
      final cr = r + ch[0] * half + ch[1] * quarter;
      final cc = c + ch[2] * half + ch[3] * quarter;
      final size = ch[4] == 1 ? subSplit : subMain;
      if (cr < miR && cc < miC) {
        if (part == 3) {
          walk(cr, cc, size);
        } else {
          emits.add((cr, cc, size));
        }
      }
    }
  }

  walk(0, 0, sbSize);
  return emits;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPartitionDecode', () {
    for (final seed in [29, 77, 130, 211]) {
      test('walks the partition tree from the stream (seed $seed)', () async {
        final buf = [for (var i = 0; i < 48; i++) (i * 47 + seed) & 0xFF];
        final exp = _refPartition(buf, 6, 4, 4); // 16x16 SB, 4x4 mi

        final d = HarborPartitionDecode();
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final sbR = Logic(name: 'sb_r', width: 16);
        final sbC = Logic(name: 'sb_c', width: 16);
        final sbSize = Logic(name: 'sb_size', width: 5);
        final miRows = Logic(name: 'mi_rows', width: 16);
        final miCols = Logic(name: 'mi_cols', width: 16);
        final bytesIn = Logic(name: 'bytes_in', width: 24);
        d.input('clk').srcConnection! <= clk;
        d.input('reset').srcConnection! <= reset;
        d.input('start').srcConnection! <= start;
        d.input('sb_r').srcConnection! <= sbR;
        d.input('sb_c').srcConnection! <= sbC;
        d.input('sb_size').srcConnection! <= sbSize;
        d.input('mi_rows').srcConnection! <= miRows;
        d.input('mi_cols').srcConnection! <= miCols;
        d.input('bytes_in').srcConnection! <= bytesIn;
        await d.build();

        var ptr = 0;
        int feed() =>
            ((ptr < buf.length ? buf[ptr] : 0) << 16) |
            ((ptr + 1 < buf.length ? buf[ptr + 1] : 0) << 8) |
            (ptr + 2 < buf.length ? buf[ptr + 2] : 0);

        reset.inject(1);
        start.inject(0);
        sbR.inject(0);
        sbC.inject(0);
        sbSize.inject(6);
        miRows.inject(4);
        miCols.inject(4);
        bytesIn.inject(feed());
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);

        final emits = <(int, int, int)>[];
        for (var cyc = 0; cyc < 400; cyc++) {
          bytesIn.inject(feed());
          await clk.nextNegedge;
          final pop = d.output('byte_pop').value.toInt();
          if (d.output('emit_valid').value.toInt() == 1) {
            emits.add((
              d.output('emit_r').value.toInt(),
              d.output('emit_c').value.toInt(),
              d.output('emit_bsize').value.toInt(),
            ));
          }
          final done = d.output('done').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          if (done == 1) break;
        }

        expect(emits, equals(exp), reason: 'seed $seed');
        await Simulator.endSimulation();
      });
    }
  });
}
