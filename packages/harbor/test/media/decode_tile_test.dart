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

class _Ctx {
  final List<int> icdf;
  final int nsyms;
  int count = 0;
  _Ctx(this.icdf, this.nsyms);
  int decode(_OdEc ec) {
    final sym = ec.decode(icdf, nsyms);
    final speed = nsyms < 2 ? 0 : (nsyms < 4 ? 1 : 2);
    final rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + speed;
    for (var i = 0; i < nsyms - 1; i++) {
      final toward = i < sym ? 32768 : 0;
      if (icdf[i] <= toward) {
        icdf[i] += (toward - icdf[i]) >> rate;
      } else {
        icdf[i] -= (icdf[i] - toward) >> rate;
      }
    }
    if (count < 32) count++;
    return sym;
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

// (r, c, bsize, skip, y, uv, eob)
List<List<int>> _refTile(List<int> buf, int sbSize, int miR, int miC) {
  final ec = _OdEc(buf);
  final cPart = _Ctx(_uniform(10), 10);
  final cSkip = _Ctx(_uniform(2), 2);
  final cY = _Ctx(_uniform(13), 13);
  final cUv = _Ctx(_uniform(13), 13);
  final cEob = _Ctx(_uniform(16), 16);
  final cBase = _Ctx(_uniform(4), 4);
  final cSign = _Ctx(_uniform(2), 2);
  final blocks = <List<int>>[];

  void decodeBlock(int r, int c, int bsize) {
    final skip = cSkip.decode(ec);
    final y = cY.decode(ec);
    final uv = cUv.decode(ec);
    var eob = 0;
    if (skip == 0) {
      eob = cEob.decode(ec);
      for (var i = 0; i < eob; i++) {
        final base = cBase.decode(ec);
        if (base != 0) cSign.decode(ec);
      }
    }
    blocks.add([r, c, bsize, skip, y, uv, eob]);
  }

  void walk(int r, int c, int bsize) {
    if (r >= miR || c >= miC) return;
    if (bsize == 0) {
      decodeBlock(r, c, 0);
      return;
    }
    final part = cPart.decode(ec);
    final half = _half[bsize]!;
    final quarter = half >> 1;
    final subMain = _subsize[bsize]![part];
    final subSplit = _subsize[bsize]![3];
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
          decodeBlock(cr, cc, size);
        }
      }
    }
  }

  walk(0, 0, sbSize);
  return blocks;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDecodeTile', () {
    for (final seed in [29, 77, 130, 211, 251]) {
      test('decodes a tile (partition + mode + coeff) from one stream '
          '(seed $seed)', () async {
        final buf = [for (var i = 0; i < 96; i++) (i * 43 + seed) & 0xFF];
        final exp = _refTile(buf, 6, 4, 4); // 16x16 SB, 4x4 mi

        final m = HarborDecodeTile();
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final sbR = Logic(name: 'sb_r', width: 16);
        final sbC = Logic(name: 'sb_c', width: 16);
        final sbSize = Logic(name: 'sb_size', width: 5);
        final miRows = Logic(name: 'mi_rows', width: 16);
        final miCols = Logic(name: 'mi_cols', width: 16);
        final bytesIn = Logic(name: 'bytes_in', width: 24);
        final coeffAddr = Logic(name: 'coeff_addr', width: 5);
        m.input('clk').srcConnection! <= clk;
        m.input('reset').srcConnection! <= reset;
        m.input('start').srcConnection! <= start;
        m.input('sb_r').srcConnection! <= sbR;
        m.input('sb_c').srcConnection! <= sbC;
        m.input('sb_size').srcConnection! <= sbSize;
        m.input('mi_rows').srcConnection! <= miRows;
        m.input('mi_cols').srcConnection! <= miCols;
        m.input('bytes_in').srcConnection! <= bytesIn;
        m.input('coeff_addr').srcConnection! <= coeffAddr;
        await m.build();

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
        coeffAddr.inject(0);
        Simulator.setMaxSimTime(4000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);

        final got = <List<int>>[];
        for (var cyc = 0; cyc < 1200; cyc++) {
          bytesIn.inject(feed());
          await clk.nextNegedge;
          final pop = m.output('byte_pop').value.toInt();
          if (m.output('block_valid').value.toInt() == 1) {
            got.add([
              m.output('blk_r').value.toInt(),
              m.output('blk_c').value.toInt(),
              m.output('blk_bsize').value.toInt(),
              m.output('skip').value.toInt(),
              m.output('y_mode').value.toInt(),
              m.output('uv_mode').value.toInt(),
              m.output('eob').value.toInt(),
            ]);
          }
          final done = m.output('done').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          if (done == 1) break;
        }

        expect(got, equals(exp), reason: 'seed $seed');
        await Simulator.endSimulation();
      });
    }
  });
}
