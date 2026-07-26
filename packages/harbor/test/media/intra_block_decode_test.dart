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
    var s = 8 - cnt;
    var p = 0;
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

List<int> _uniform(int n) {
  final v = [for (var i = 0; i < n; i++) 32768 - ((i + 1) * 32768 / n).round()];
  while (v.length < 16) {
    v.add(0);
  }
  return v;
}

// libaom update_cdf, matching the od_ec's internal adaptation.
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

class _Blk {
  int skip = 0, y = 0, uv = 0, eob = 0;
  final coeffs = List.filled(16, 0);
}

// Decode `n` blocks from one continuing stream with persistent adapting CDFs.
List<_Blk> _refBlocks(List<int> buf, int n) {
  final ec = _OdEc(buf);
  final cSkip = _Ctx(_uniform(2), 2);
  final cY = _Ctx(_uniform(13), 13);
  final cUv = _Ctx(_uniform(13), 13);
  final cEob = _Ctx(_uniform(16), 16);
  final cBase = _Ctx(_uniform(4), 4);
  final cSign = _Ctx(_uniform(2), 2);
  final out = <_Blk>[];
  for (var b = 0; b < n; b++) {
    final blk = _Blk();
    blk.skip = cSkip.decode(ec);
    blk.y = cY.decode(ec);
    blk.uv = cUv.decode(ec);
    if (blk.skip == 0) {
      blk.eob = cEob.decode(ec);
      for (var i = 0; i < blk.eob; i++) {
        final base = cBase.decode(ec);
        if (base != 0) {
          final sign = cSign.decode(ec);
          blk.coeffs[i] = sign == 1 ? -base : base;
        }
      }
    }
    out.add(blk);
  }
  return out;
}

class _Ref extends _Blk {
  _Ref(List<int> buf) {
    final b = _refBlocks(buf, 1)[0];
    skip = b.skip;
    y = b.y;
    uv = b.uv;
    eob = b.eob;
    for (var i = 0; i < 16; i++) {
      coeffs[i] = b.coeffs[i];
    }
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraBlockDecode', () {
    for (final seed in [29, 77, 113, 200, 251]) {
      test('mode + coeffs match od_ec reference (seed $seed)', () async {
        final buf = [for (var i = 0; i < 48; i++) (i * 53 + seed) & 0xFF];
        final ref = _Ref(buf);

        final m = HarborIntraBlockDecode();
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final nextBlk = Logic(name: 'next_blk');
        final bytesIn = Logic(name: 'bytes_in', width: 24);
        final coeffAddr = Logic(name: 'coeff_addr', width: 5);
        m.input('clk').srcConnection! <= clk;
        m.input('reset').srcConnection! <= reset;
        m.input('start').srcConnection! <= start;
        m.input('next_blk').srcConnection! <= nextBlk;
        m.input('bytes_in').srcConnection! <= bytesIn;
        m.input('coeff_addr').srcConnection! <= coeffAddr;
        await m.build();

        int feed(int p) =>
            ((p < buf.length ? buf[p] : 0) << 16) |
            ((p + 1 < buf.length ? buf[p + 1] : 0) << 8) |
            (p + 2 < buf.length ? buf[p + 2] : 0);

        reset.inject(1);
        start.inject(0);
        nextBlk.inject(0);
        bytesIn.inject(feed(0));
        coeffAddr.inject(0);
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);

        var ptr = 0;
        for (var cyc = 0; cyc < 400; cyc++) {
          bytesIn.inject(feed(ptr));
          await clk.nextNegedge;
          final pop = m.output('byte_pop').value.toInt();
          final done = m.output('done').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          if (done == 1) break;
        }

        expect(
          m.output('skip').value.toInt(),
          equals(ref.skip),
          reason: 'skip',
        );
        expect(m.output('y_mode').value.toInt(), equals(ref.y), reason: 'y');
        expect(m.output('uv_mode').value.toInt(), equals(ref.uv), reason: 'uv');
        expect(m.output('eob').value.toInt(), equals(ref.eob), reason: 'eob');
        for (var i = 0; i < ref.eob; i++) {
          coeffAddr.inject(i);
          await clk.nextNegedge;
          final raw = m.output('coeff_out').value.toInt();
          final signed = raw >= 128 ? raw - 256 : raw;
          expect(signed, equals(ref.coeffs[i]), reason: 'coeff $i');
        }
        await Simulator.endSimulation();
      });
    }

    test(
      'decodes 3 blocks from one continuing stream (persistent CDFs)',
      () async {
        final buf = [for (var i = 0; i < 96; i++) (i * 41 + 91) & 0xFF];
        final ref = _refBlocks(buf, 3);

        final m = HarborIntraBlockDecode();
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final nextBlk = Logic(name: 'next_blk');
        final bytesIn = Logic(name: 'bytes_in', width: 24);
        final coeffAddr = Logic(name: 'coeff_addr', width: 5);
        m.input('clk').srcConnection! <= clk;
        m.input('reset').srcConnection! <= reset;
        m.input('start').srcConnection! <= start;
        m.input('next_blk').srcConnection! <= nextBlk;
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
        nextBlk.inject(0);
        bytesIn.inject(feed());
        coeffAddr.inject(0);
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        for (var b = 0; b < 3; b++) {
          // Kick: start for the first block, next_blk for the rest.
          start.inject(b == 0 ? 1 : 0);
          nextBlk.inject(b == 0 ? 0 : 1);
          await clk.nextPosedge;
          start.inject(0);
          nextBlk.inject(0);

          for (var cyc = 0; cyc < 400; cyc++) {
            bytesIn.inject(feed());
            await clk.nextNegedge;
            final pop = m.output('byte_pop').value.toInt();
            final done = m.output('done').value.toInt();
            await clk.nextPosedge;
            ptr += pop;
            if (done == 1) break;
          }

          expect(
            m.output('skip').value.toInt(),
            equals(ref[b].skip),
            reason: 'blk $b skip',
          );
          expect(
            m.output('y_mode').value.toInt(),
            equals(ref[b].y),
            reason: 'blk $b y',
          );
          expect(
            m.output('uv_mode').value.toInt(),
            equals(ref[b].uv),
            reason: 'blk $b uv',
          );
          expect(
            m.output('eob').value.toInt(),
            equals(ref[b].eob),
            reason: 'blk $b eob',
          );
          for (var i = 0; i < ref[b].eob; i++) {
            coeffAddr.inject(i);
            await clk.nextNegedge;
            final raw = m.output('coeff_out').value.toInt();
            final signed = raw >= 128 ? raw - 256 : raw;
            expect(signed, equals(ref[b].coeffs[i]), reason: 'blk $b coeff $i');
          }
        }
        await Simulator.endSimulation();
      },
    );
  });
}
