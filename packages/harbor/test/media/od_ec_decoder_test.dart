import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Faithful port of libaom's od_ec range decoder (aom_dsp/entdec.c) used as the
// ground-truth reference: 32-bit window, EC_PROB_SHIFT = 6, EC_MIN_PROB = 4.
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

// libaom update_cdf (adapting the inverse CDF) for one context.
class _Ctx {
  final List<int> icdf;
  final int nsyms;
  int count = 0;
  _Ctx(this.icdf, this.nsyms);

  void adapt(int sym) {
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
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborOdEcDecoder', () {
    test('matches libaom od_ec + update_cdf over adapting contexts', () async {
      const maxSyms = 16;
      final dec = HarborOdEcDecoder(maxSyms: maxSyms, numCtx: 8);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final init = Logic(name: 'init');
      final load = Logic(name: 'load');
      final decode = Logic(name: 'decode');
      final ctx = Logic(name: 'ctx', width: dec.ctxWidth);
      final cdf = Logic(name: 'cdf', width: maxSyms * 16);
      final nsyms = Logic(name: 'num_syms', width: 5);
      final bytesIn = Logic(name: 'bytes_in', width: 24);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('init').srcConnection! <= init;
      dec.input('load').srcConnection! <= load;
      dec.input('decode').srcConnection! <= decode;
      dec.input('ctx').srcConnection! <= ctx;
      dec.input('cdf').srcConnection! <= cdf;
      dec.input('num_syms').srcConnection! <= nsyms;
      dec.input('bytes_in').srcConnection! <= bytesIn;

      await dec.build();

      final buf = [for (var i = 0; i < 80; i++) (i * 67 + 29) & 0xFF];
      final icdf4 = [24576, 16384, 8192, 0, ...List.filled(12, 0)];
      final icdf2 = [16384, 0, ...List.filled(14, 0)];
      // Context 0 = 4-symbol, context 1 = 2-symbol, interleave so both adapt.
      final schedule = [for (var i = 0; i < 40; i++) (i % 3 == 0) ? 1 : 0];

      BigInt packIcdf(List<int> v) {
        var x = BigInt.zero;
        for (var i = 0; i < maxSyms; i++) {
          x |= BigInt.from(v[i] & 0xFFFF) << (i * 16);
        }
        return x;
      }

      reset.inject(1);
      init.inject(0);
      load.inject(0);
      decode.inject(0);
      ctx.inject(0);
      cdf.inject(0);
      nsyms.inject(4);
      bytesIn.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> loadCtx(int c, List<int> tbl, int n) async {
        ctx.inject(c);
        cdf.inject(packIcdf(tbl));
        nsyms.inject(n);
        load.inject(1);
        await clk.nextPosedge;
        load.inject(0);
      }

      await loadCtx(0, icdf4, 4);
      await loadCtx(1, icdf2, 2);

      var ptr = 0;
      int feed(int p) =>
          ((p < buf.length ? buf[p] : 0) << 16) |
          ((p + 1 < buf.length ? buf[p + 1] : 0) << 8) |
          (p + 2 < buf.length ? buf[p + 2] : 0);

      // Initialize the window.
      bytesIn.inject(feed(ptr));
      init.inject(1);
      await clk.nextNegedge;
      ptr += dec.output('byte_pop').value.toInt();
      await clk.nextPosedge;
      init.inject(0);

      // Reference: one window, two adapting contexts.
      final ref = _OdEc(buf);
      final ctxs = [
        _Ctx([...icdf4], 4),
        _Ctx([...icdf2], 2),
      ];

      final got = <int>[];
      final expected = <int>[];
      for (final c in schedule) {
        bytesIn.inject(feed(ptr));
        ctx.inject(c);
        decode.inject(1);
        // byte_pop is combinational on the decode cycle, the symbol is
        // registered, so it is read one cycle later.
        await clk.nextNegedge;
        ptr += dec.output('byte_pop').value.toInt();
        await clk.nextPosedge;
        decode.inject(0);
        await clk.nextNegedge;
        got.add(dec.output('symbol').value.toInt());
        await clk.nextPosedge;

        final sym = ref.decode(ctxs[c].icdf, ctxs[c].nsyms);
        ctxs[c].adapt(sym);
        expected.add(sym);
      }

      expect(got, equals(expected));
      await Simulator.endSimulation();
    });
  });
}
