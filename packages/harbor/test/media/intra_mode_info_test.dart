import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Faithful libaom od_ec range decoder (ground truth).
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

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraModeInfo', () {
    Future<(int, int, int)> decodeHw(List<int> buf) async {
      final m = HarborIntraModeInfo();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytesIn = Logic(name: 'bytes_in', width: 24);
      m.input('clk').srcConnection! <= clk;
      m.input('reset').srcConnection! <= reset;
      m.input('start').srcConnection! <= start;
      m.input('bytes_in').srcConnection! <= bytesIn;
      await m.build();

      int feed(int p) =>
          ((p < buf.length ? buf[p] : 0) << 16) |
          ((p + 1 < buf.length ? buf[p + 1] : 0) << 8) |
          (p + 2 < buf.length ? buf[p + 2] : 0);

      reset.inject(1);
      start.inject(0);
      bytesIn.inject(feed(0));
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      var ptr = 0;
      for (var cyc = 0; cyc < 200; cyc++) {
        bytesIn.inject(feed(ptr));
        await clk.nextNegedge;
        final pop = m.output('byte_pop').value.toInt();
        final done = m.output('done').value.toInt();
        await clk.nextPosedge;
        ptr += pop;
        if (done == 1) break;
      }
      final r = (
        m.output('skip').value.toInt(),
        m.output('y_mode').value.toInt(),
        m.output('uv_mode').value.toInt(),
      );
      await Simulator.endSimulation();
      return r;
    }

    for (final seed in [29, 113, 200]) {
      test('matches od_ec reference (seed $seed)', () async {
        final buf = [for (var i = 0; i < 40; i++) (i * 67 + seed) & 0xFF];
        final ref = _OdEc(buf);
        final expSkip = ref.decode(_uniform(2), 2);
        final expY = ref.decode(_uniform(13), 13);
        final expUv = ref.decode(_uniform(13), 13);
        final got = await decodeHw(buf);
        expect(got, equals((expSkip, expY, expUv)), reason: 'seed $seed');
      });
    }
  });
}
