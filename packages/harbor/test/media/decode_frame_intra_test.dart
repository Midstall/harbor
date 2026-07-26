import 'dart:async';
import 'dart:math';

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

List<int> _uniform(int n) {
  final v = [for (var i = 0; i < n; i++) 32768 - ((i + 1) * 32768 / n).round()];
  while (v.length < 16) {
    v.add(0);
  }
  return v;
}

List<List<int>> _dctMatrix(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        ((k == 0 ? sqrt(1 / n) : sqrt(2 / n)) *
                cos((2 * i + 1) * k * pi / (2 * n)) *
                4096)
            .round(),
    ],
];

List<int> _invDct4(List<int> c) {
  final m = _dctMatrix(4);
  int rs(int x) => (x + 2048) >> 12;
  List<int> inv1d(List<int> inp) => [
    for (var i = 0; i < 4; i++)
      rs(
        [for (var k = 0; k < 4; k++) m[k][i] * inp[k]].reduce((a, b) => a + b),
      ),
  ];
  final tmp = [for (var r = 0; r < 4; r++) List.filled(4, 0)];
  for (var col = 0; col < 4; col++) {
    final o = inv1d([for (var r = 0; r < 4; r++) c[r * 4 + col]]);
    for (var r = 0; r < 4; r++) {
      tmp[r][col] = o[r];
    }
  }
  final out = List.filled(16, 0);
  for (var r = 0; r < 4; r++) {
    final o = inv1d([for (var col = 0; col < 4; col++) tmp[r][col]]);
    for (var col = 0; col < 4; col++) {
      out[r * 4 + col] = o[col];
    }
  }
  return out;
}

const _smW4 = [255, 149, 85, 64];
int _clamp(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

int _absd(int a, int b) => (a - b).abs();
int _paeth(int a, int l, int c) {
  final pa = _absd(l, c), pl = _absd(a, c), pal = _absd(a + l, 2 * c);
  if (pa <= pl && pa <= pal) return a;
  if (pl <= pal) return l;
  return c;
}

int _pred(int mode, int r, int c, List<int> above8, List<int> left4, int al) {
  final aboveRight = above8[3], belowLeft = left4[3];
  final wv = _smW4[r], wh = _smW4[c];
  final vsum = wv * above8[c] + (256 - wv) * belowLeft;
  final hsum = wh * left4[r] + (256 - wh) * aboveRight;
  switch (mode) {
    case 1:
      return above8[c];
    case 2:
      return left4[r];
    case 3:
      return _paeth(above8[c], left4[r], al);
    case 4:
      return (vsum + hsum + 256) >> 9;
    case 5:
      return (vsum + 128) >> 8;
    case 6:
      return (hsum + 128) >> 8;
    case 7:
      return above8[(r + c + 1) > 7 ? 7 : (r + c + 1)];
    default:
      final s =
          above8.take(4).reduce((a, b) => a + b) +
          left4.reduce((a, b) => a + b);
      return (s + 4) >> 3;
  }
}

List<List<int>> _refFrame(
  List<int> buf,
  int gridW,
  int gridH,
  int dcQ,
  int acQ,
) {
  final ec = _OdEc(buf);
  final cSkip = _Ctx(_uniform(2), 2);
  final cY = _Ctx(_uniform(13), 13);
  final cUv = _Ctx(_uniform(13), 13);
  final cEob = _Ctx(_uniform(16), 16);
  final cBase = _Ctx(_uniform(4), 4);
  final cSign = _Ctx(_uniform(2), 2);
  final fw = gridW * 4, fh = gridH * 4;
  final frame = [for (var y = 0; y < fh; y++) List.filled(fw, 0)];
  var aboveRow = List.filled(fw, 128);

  for (var gr = 0; gr < gridH; gr++) {
    var leftCol = [128, 128, 128, 128];
    final botRow = List.filled(fw, 0);
    for (var gc = 0; gc < gridW; gc++) {
      final skip = cSkip.decode(ec);
      final y = cY.decode(ec);
      cUv.decode(ec);
      final coeffs = List.filled(16, 0);
      if (skip == 0) {
        final eob = cEob.decode(ec);
        for (var i = 0; i < eob; i++) {
          final base = cBase.decode(ec);
          if (base != 0) {
            final sign = cSign.decode(ec);
            coeffs[i] = sign == 1 ? -base : base;
          }
        }
      }
      final deq = [
        for (var i = 0; i < 16; i++) coeffs[i] * (i == 0 ? dcQ : acQ),
      ];
      final residual = _invDct4(deq);
      final mode = y & 7;
      final above8 = [
        for (var i = 0; i < 8; i++)
          (gr > 0 && gc * 4 + i < fw) ? aboveRow[gc * 4 + i] : 128,
      ];
      final left4 = [for (var r = 0; r < 4; r++) gc > 0 ? leftCol[r] : 128];
      final al = (gr > 0 && gc > 0) ? aboveRow[gc * 4 - 1] : 128;
      final recon = [for (var r = 0; r < 4; r++) List.filled(4, 0)];
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          recon[r][c] = _clamp(
            _pred(mode, r, c, above8, left4, al) + residual[r * 4 + c],
          );
          frame[gr * 4 + r][gc * 4 + c] = recon[r][c];
        }
      }
      leftCol = [for (var r = 0; r < 4; r++) recon[r][3]];
      for (var c = 0; c < 4; c++) {
        botRow[gc * 4 + c] = recon[3][c];
      }
    }
    aboveRow = botRow;
  }
  return frame;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDecodeFrameIntra (bitstream -> 2D picture)', () {
    for (final seed in [29, 130, 201]) {
      test('decodes a 3x3 frame of 4x4 blocks (seed $seed)', () async {
        const gridW = 3, gridH = 3, dcQ = 16, acQ = 12;
        final buf = [for (var i = 0; i < 128; i++) (i * 53 + seed) & 0xFF];
        final exp = _refFrame(buf, gridW, gridH, dcQ, acQ);

        final m = HarborDecodeFrameIntra(gridW: gridW, gridH: gridH);
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final bytesIn = Logic(name: 'bytes_in', width: 24);
        final dcq = Logic(name: 'dc_q', width: 8);
        final acq = Logic(name: 'ac_q', width: 8);
        m.input('clk').srcConnection! <= clk;
        m.input('reset').srcConnection! <= reset;
        m.input('start').srcConnection! <= start;
        m.input('bytes_in').srcConnection! <= bytesIn;
        m.input('dc_q').srcConnection! <= dcq;
        m.input('ac_q').srcConnection! <= acq;
        await m.build();

        var ptr = 0;
        int feed() =>
            ((ptr < buf.length ? buf[ptr] : 0) << 16) |
            ((ptr + 1 < buf.length ? buf[ptr + 1] : 0) << 8) |
            (ptr + 2 < buf.length ? buf[ptr + 2] : 0);

        reset.inject(1);
        start.inject(0);
        bytesIn.inject(feed());
        dcq.inject(dcQ);
        acq.inject(acQ);
        Simulator.setMaxSimTime(8000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);

        for (var cyc = 0; cyc < 2000; cyc++) {
          bytesIn.inject(feed());
          await clk.nextNegedge;
          final pop = m.output('byte_pop').value.toInt();
          final done = m.output('done').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          if (done == 1) break;
        }

        final v = m.output('frame').value.toBigInt();
        final fw = gridW * 4, fh = gridH * 4;
        for (var y = 0; y < fh; y++) {
          for (var x = 0; x < fw; x++) {
            final got = ((v >> ((y * fw + x) * 8)) & BigInt.from(0xFF)).toInt();
            expect(got, equals(exp[y][x]), reason: 'seed $seed ($y,$x)');
          }
        }
        await Simulator.endSimulation();
      });
    }
  });
}
