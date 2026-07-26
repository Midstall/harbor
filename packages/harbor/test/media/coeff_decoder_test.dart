import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference range decoder + adaptive contexts (matching the RTL).
class _Range {
  int rng = 0xFFFF;
  int code = 0;
  final List<int> bits;
  int pos = 16;
  _Range(this.bits) {
    for (var i = 0; i < 16; i++) {
      code = (code << 1) | bits[i];
    }
  }
  int _next() => pos < bits.length ? bits[pos++] : 0;
  int decode(List<int> cdf, int n) {
    final b = [for (var s = 0; s < n; s++) (rng * cdf[s]) >> 15];
    var s = 0;
    while (s < n - 1 && code >= b[s]) {
      s++;
    }
    final lo = s == 0 ? 0 : b[s - 1];
    code -= lo;
    rng = b[s] - lo;
    while (rng < 0x8000) {
      rng = rng << 1;
      code = (code << 1) | _next();
    }
    return s;
  }
}

class _Ctx {
  final List<int> cdf;
  final int n;
  int count = 0;
  _Ctx(this.cdf, this.n);
  void adapt(int val) {
    final speed = n < 2 ? 0 : (n < 4 ? 1 : 2);
    final rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + speed;
    for (var i = 0; i < n - 1; i++) {
      if (i < val) {
        cdf[i] -= cdf[i] >> rate;
      } else {
        cdf[i] += (0x8000 - cdf[i]) >> rate;
      }
    }
    if (count < 32) count++;
  }
}

List<_Ctx> _freshCtxs() => [
  _Ctx([for (var i = 0; i < 16; i++) (i + 1) * 2048], 16),
  _Ctx([16384, 24576, 30720, 32768], 4),
  _Ctx([8192, 16384, 24576, 32768], 4),
  _Ctx([16384, 32768], 2),
];

// Reference coefficient-syntax decode over a persistent range + contexts (so
// successive blocks share adapting CDFs and a continuing stream window).
List<int> _decodeBlockWith(_Range range, List<_Ctx> ctxs, int numCoeffs) {
  int dec(int c) {
    final s = range.decode(ctxs[c].cdf, ctxs[c].n);
    ctxs[c].adapt(s);
    return s;
  }

  var eob = dec(0);
  if (eob > numCoeffs) eob = numCoeffs;
  final coeffs = List.filled(numCoeffs, 0);
  var pos = 0;
  while (pos < eob) {
    final base = dec(1);
    if (base == 0) {
      pos++;
      continue;
    }
    var level = base;
    if (base == 3) {
      var brCnt = 0;
      while (true) {
        final r = dec(2);
        level += r;
        if (r < 3 || brCnt == 3) break;
        brCnt++;
      }
    }
    final sign = dec(3);
    coeffs[pos] = (sign & 1) != 0 ? -level : level;
    pos++;
  }
  return coeffs;
}

// Single-block convenience wrapper.
List<int> _decodeBlock(List<int> bits, int numCoeffs) =>
    _decodeBlockWith(_Range(bits), _freshCtxs(), numCoeffs);

class _OdEc {
  static const w = 32;
  static const mask = (1 << w) - 1;
  int dif = 0, rng = 0x8000, cnt = -15;
  final List<int> buf;
  int bptr = 0;
  _OdEc(this.buf) {
    dif = (1 << (w - 1)) - 1;
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

class _ICtx {
  final List<int> icdf;
  final int nsyms;
  int count = 0;
  _ICtx(this.icdf, this.nsyms);
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

// Coefficient-syntax decode over od_ec + update_cdf (mirrors useOdEc HW).
List<int> _decodeBlockOdEc(List<int> buf, int numCoeffs) {
  final od = _OdEc(buf);
  final ctxs = [
    _ICtx([for (var i = 0; i < 16; i++) (15 - i) * 2048], 16),
    _ICtx([16384, 8192, 2048, 0], 4),
    _ICtx([24576, 16384, 8192, 0], 4),
    _ICtx([16384, 0], 2),
  ];
  int dec(int c) {
    final s = od.decode(ctxs[c].icdf, ctxs[c].nsyms);
    ctxs[c].adapt(s);
    return s;
  }

  var eob = dec(0);
  if (eob > numCoeffs) eob = numCoeffs;
  final coeffs = List.filled(numCoeffs, 0);
  var pos = 0;
  while (pos < eob) {
    final base = dec(1);
    if (base == 0) {
      pos++;
      continue;
    }
    var level = base;
    if (base == 3) {
      var brCnt = 0;
      while (true) {
        final r = dec(2);
        level += r;
        if (r < 3 || brCnt == 3) break;
        brCnt++;
      }
    }
    final sign = dec(3);
    coeffs[pos] = (sign & 1) != 0 ? -level : level;
    pos++;
  }
  return coeffs;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCoeffDecoder', () {
    test('decodes a coefficient block matching the reference', () async {
      const numCoeffs = 16;
      final dec = HarborCoeffDecoder(maxCoeffs: numCoeffs);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final nc = Logic(name: 'nc', width: dec.posWidth);
      final stream = Logic(name: 'stream', width: 64);
      final bytesIn = Logic(name: 'bytes_in', width: 16);
      final coeffAddr = Logic(name: 'coeff_addr', width: dec.posWidth);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('start').srcConnection! <= start;
      dec.input('next_blk').srcConnection! <= Const(0);
      dec.input('stall').srcConnection! <= Const(0);
      dec.input('num_coeffs').srcConnection! <= nc;
      dec.input('stream').srcConnection! <= stream;
      dec.input('bytes_in').srcConnection! <= bytesIn;
      dec.input('coeff_addr').srcConnection! <= coeffAddr;

      await dec.build();

      // A 32-byte coded stream.
      final streamBytes = [for (var i = 0; i < 32; i++) (i * 41 + 7) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }
      int byteAt(int p) => p < streamBytes.length ? streamBytes[p] : 0;
      var word0 = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        if (bits[i] != 0) word0 |= BigInt.one << (63 - i);
      }

      reset.inject(1);
      start.inject(0);
      nc.inject(numCoeffs);
      stream.inject(0);
      bytesIn.inject(0);
      coeffAddr.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Start a block decode, hold the stream window stable for the load.
      stream.inject(word0);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      // Feed stream bytes (from byte 8 onward) until the block is done.
      var ptr = 8;
      var guard = 0;
      while (dec.output('done').value.toInt() != 1 && guard < 2000) {
        bytesIn.inject((byteAt(ptr) << 8) | byteAt(ptr + 1));
        await clk.nextNegedge;
        final pop = dec.output('byte_pop').value.toInt();
        await clk.nextPosedge;
        ptr += pop;
        guard++;
      }
      expect(dec.output('done').value.toInt(), equals(1), reason: 'finished');

      final expected = _decodeBlock(bits, numCoeffs);
      final got = <int>[];
      for (var i = 0; i < numCoeffs; i++) {
        coeffAddr.inject(i);
        await clk.nextNegedge;
        got.add(dec.output('coeff_out').value.toInt());
      }
      expect(got, equals([for (final c in expected) c & 0xFFFF]));
      await Simulator.endSimulation();
    });

    test('continues into a second block reusing adapted CDFs', () async {
      const numCoeffs = 16;
      final dec = HarborCoeffDecoder(maxCoeffs: numCoeffs);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final nextBlk = Logic(name: 'next_blk');
      final nc = Logic(name: 'nc', width: dec.posWidth);
      final stream = Logic(name: 'stream', width: 64);
      final bytesIn = Logic(name: 'bytes_in', width: 16);
      final coeffAddr = Logic(name: 'coeff_addr', width: dec.posWidth);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('start').srcConnection! <= start;
      dec.input('next_blk').srcConnection! <= nextBlk;
      dec.input('stall').srcConnection! <= Const(0);
      dec.input('num_coeffs').srcConnection! <= nc;
      dec.input('stream').srcConnection! <= stream;
      dec.input('bytes_in').srcConnection! <= bytesIn;
      dec.input('coeff_addr').srcConnection! <= coeffAddr;

      await dec.build();

      // A 48-byte coded stream feeding two consecutive blocks.
      final streamBytes = [for (var i = 0; i < 48; i++) (i * 53 + 19) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }
      int byteAt(int p) => p < streamBytes.length ? streamBytes[p] : 0;
      var word0 = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        if (bits[i] != 0) word0 |= BigInt.one << (63 - i);
      }

      reset.inject(1);
      start.inject(0);
      nextBlk.inject(0);
      nc.inject(numCoeffs);
      stream.inject(0);
      bytesIn.inject(0);
      coeffAddr.inject(0);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      var ptr = 8; // beat-0 bytes 0..7 seeded the window
      Future<List<int>> feedAndRead() async {
        var guard = 0;
        while (dec.output('done').value.toInt() != 1 && guard < 4000) {
          bytesIn.inject((byteAt(ptr) << 8) | byteAt(ptr + 1));
          await clk.nextNegedge;
          final pop = dec.output('byte_pop').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          guard++;
        }
        final out = <int>[];
        for (var i = 0; i < numCoeffs; i++) {
          coeffAddr.inject(i);
          await clk.nextNegedge;
          out.add(dec.output('coeff_out').value.toInt());
        }
        return out;
      }

      // Block 0 via start.
      stream.inject(word0);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      final got0 = await feedAndRead();

      // Block 1 via next_blk: continue the stream, keep the adapted CDFs.
      nextBlk.inject(1);
      bytesIn.inject((byteAt(ptr) << 8) | byteAt(ptr + 1));
      await clk.nextPosedge;
      nextBlk.inject(0);
      final got1 = await feedAndRead();

      // Reference: one range + contexts, two blocks decoded in sequence.
      final range = _Range(bits);
      final ctxs = _freshCtxs();
      final expected0 = _decodeBlockWith(range, ctxs, numCoeffs);
      final expected1 = _decodeBlockWith(range, ctxs, numCoeffs);

      expect(got0, equals([for (final c in expected0) c & 0xFFFF]));
      expect(
        got1,
        equals([for (final c in expected1) c & 0xFFFF]),
        reason: 'second block continues with adapted CDFs',
      );
      await Simulator.endSimulation();
    });

    test('decodes a block using the real od_ec range coder', () async {
      const numCoeffs = 16;
      final dec = HarborCoeffDecoder(maxCoeffs: numCoeffs, useOdEc: true);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final nc = Logic(name: 'nc', width: dec.posWidth);
      final bytesIn = Logic(name: 'bytes_in', width: 24);
      final coeffAddr = Logic(name: 'coeff_addr', width: dec.posWidth);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('start').srcConnection! <= start;
      dec.input('next_blk').srcConnection! <= Const(0);
      dec.input('stall').srcConnection! <= Const(0);
      dec.input('num_coeffs').srcConnection! <= nc;
      dec.input('bytes_in').srcConnection! <= bytesIn;
      dec.input('coeff_addr').srcConnection! <= coeffAddr;

      await dec.build();

      final buf = [for (var i = 0; i < 48; i++) (i * 43 + 17) & 0xFF];
      int feed(int p) =>
          ((p < buf.length ? buf[p] : 0) << 16) |
          ((p + 1 < buf.length ? buf[p + 1] : 0) << 8) |
          (p + 2 < buf.length ? buf[p + 2] : 0);

      reset.inject(1);
      start.inject(0);
      nc.inject(numCoeffs);
      bytesIn.inject(0);
      coeffAddr.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      var ptr = 0;
      bytesIn.inject(feed(ptr));
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      var guard = 0;
      while (dec.output('done').value.toInt() != 1 && guard < 4000) {
        bytesIn.inject(feed(ptr));
        await clk.nextNegedge;
        final pop = dec.output('byte_pop').value.toInt();
        await clk.nextPosedge;
        ptr += pop;
        guard++;
      }
      expect(dec.output('done').value.toInt(), equals(1), reason: 'finished');

      final expected = _decodeBlockOdEc(buf, numCoeffs);
      final got = <int>[];
      for (var i = 0; i < numCoeffs; i++) {
        coeffAddr.inject(i);
        await clk.nextNegedge;
        got.add(dec.output('coeff_out').value.toInt());
      }
      expect(got, equals([for (final c in expected) c & 0xFFFF]));
      await Simulator.endSimulation();
    });
  });
}
