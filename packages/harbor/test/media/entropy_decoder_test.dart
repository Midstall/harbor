import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference range decoder using the same integer arithmetic as the RTL.
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
    final hi = b[s];
    code -= lo;
    rng = hi - lo;
    while (rng < 0x8000) {
      rng = rng << 1;
      code = (code << 1) | _next();
    }
    return s;
  }
}

// A reference adaptive CDF context, mirroring the RTL's update_cdf.
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

BigInt _packCdf(List<int> cdf) {
  var v = BigInt.zero;
  for (var s = 0; s < 16; s++) {
    final c = s < cdf.length ? cdf[s] : 0x8000;
    v |= BigInt.from(c & 0xFFFF) << (s * 16);
  }
  return v;
}

BigInt _packStream(List<int> bits) {
  var v = BigInt.zero;
  for (var i = 0; i < 64; i++) {
    if (bits[i] != 0) v |= BigInt.one << (63 - i);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborEntropyDecoder', () {
    test('symbol and context width sizing', () {
      expect(HarborEntropyDecoder(maxSyms: 16).symWidth, equals(4));
      expect(HarborEntropyDecoder(maxSyms: 4).symWidth, equals(2));
      expect(HarborEntropyDecoder(numCtx: 8).ctxWidth, equals(3));
      expect(HarborEntropyDecoder(numCtx: 4).ctxWidth, equals(2));
    });

    test('decodes and adapts CDFs across two contexts', () async {
      final dec = HarborEntropyDecoder(numCtx: 8);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final initSig = Logic(name: 'init');
      final loadSig = Logic(name: 'load');
      final decodeSig = Logic(name: 'decode');
      final stream = Logic(name: 'stream', width: 64);
      final ctx = Logic(name: 'ctx', width: dec.ctxWidth);
      final cdfSig = Logic(name: 'cdf', width: 256);
      final numSyms = Logic(name: 'num_syms', width: 5);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('init').srcConnection! <= initSig;
      dec.input('load').srcConnection! <= loadSig;
      dec.input('decode').srcConnection! <= decodeSig;
      dec.input('stream').srcConnection! <= stream;
      dec.input('ctx').srcConnection! <= ctx;
      dec.input('cdf').srcConnection! <= cdfSig;
      dec.input('num_syms').srcConnection! <= numSyms;
      dec.input('bytes_in').srcConnection! <= Const(0, width: 16);

      await dec.build();

      const streamBytes = [0xA3, 0x5C, 0xF1, 0x08, 0x9D, 0x42, 0x7B, 0xE6];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }

      reset.inject(1);
      initSig.inject(0);
      loadSig.inject(0);
      decodeSig.inject(0);
      stream.inject(0);
      ctx.inject(0);
      cdfSig.inject(0);
      numSyms.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> load(int c, List<int> cdf, int n) async {
        ctx.inject(c);
        cdfSig.inject(_packCdf(cdf));
        numSyms.inject(n);
        loadSig.inject(1);
        await clk.nextPosedge;
        loadSig.inject(0);
        await clk.nextPosedge;
      }

      // Two contexts with different alphabets and shapes.
      final ref0 = _Ctx([8192, 16384, 24576, 32768], 4);
      final ref1 = _Ctx([16384, 32768], 2);
      await load(0, ref0.cdf, ref0.n);
      await load(1, ref1.cdf, ref1.n);

      // Initialise the range decoder with the coded stream.
      stream.inject(_packStream(bits));
      initSig.inject(1);
      await clk.nextPosedge;
      initSig.inject(0);
      await clk.nextPosedge;

      final range = _Range(bits);
      final refs = {0: ref0, 1: ref1};
      // Interleave decodes across the two contexts. Each adapts independently.
      const order = [0, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1];
      for (final c in order) {
        ctx.inject(c);
        decodeSig.inject(1);
        await clk.nextPosedge;
        decodeSig.inject(0);
        final hw = dec.output('symbol').value.toInt();
        final refCtx = refs[c]!;
        final expected = range.decode(refCtx.cdf, refCtx.n);
        refCtx.adapt(expected);
        expect(
          hw,
          equals(expected),
          reason: 'ctx $c (count ${refCtx.count}, rng ${range.rng})',
        );
      }

      await Simulator.endSimulation();
    });

    test('refills the window from the byte feed for a long stream', () async {
      final dec = HarborEntropyDecoder(numCtx: 2);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final initSig = Logic(name: 'init');
      final loadSig = Logic(name: 'load');
      final decodeSig = Logic(name: 'decode');
      final stream = Logic(name: 'stream', width: 64);
      final ctx = Logic(name: 'ctx', width: dec.ctxWidth);
      final cdfSig = Logic(name: 'cdf', width: 256);
      final numSyms = Logic(name: 'num_syms', width: 5);
      final bytesIn = Logic(name: 'bytes_in', width: 16);

      dec.input('clk').srcConnection! <= clk;
      dec.input('reset').srcConnection! <= reset;
      dec.input('init').srcConnection! <= initSig;
      dec.input('load').srcConnection! <= loadSig;
      dec.input('decode').srcConnection! <= decodeSig;
      dec.input('stream').srcConnection! <= stream;
      dec.input('ctx').srcConnection! <= ctx;
      dec.input('cdf').srcConnection! <= cdfSig;
      dec.input('num_syms').srcConnection! <= numSyms;
      dec.input('bytes_in').srcConnection! <= bytesIn;

      await dec.build();

      // A 32-byte stream: far more than the 64-bit window holds.
      final streamBytes = [for (var i = 0; i < 32; i++) (i * 37 + 19) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }
      int byteAt(int p) => p < streamBytes.length ? streamBytes[p] : 0;

      reset.inject(1);
      initSig.inject(0);
      loadSig.inject(0);
      decodeSig.inject(0);
      stream.inject(0);
      ctx.inject(0);
      cdfSig.inject(0);
      numSyms.inject(0);
      bytesIn.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Load a 4-symbol CDF and the first 8 bytes (64 bits) of the stream.
      final ref = _Ctx([8192, 16384, 24576, 32768], 4);
      ctx.inject(0);
      cdfSig.inject(_packCdf(ref.cdf));
      numSyms.inject(ref.n);
      loadSig.inject(1);
      var word0 = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        if (bits[i] != 0) word0 |= BigInt.one << (63 - i);
      }
      stream.inject(word0);
      initSig.inject(1);
      await clk.nextPosedge;
      loadSig.inject(0);
      initSig.inject(0);
      await clk.nextPosedge;

      final range = _Range(bits);
      var ptr = 8; // next stream byte to feed
      // Decode well past the initial 64-bit window to force repeated refills.
      for (var k = 0; k < 50; k++) {
        ctx.inject(0);
        bytesIn.inject((byteAt(ptr) << 8) | byteAt(ptr + 1));
        decodeSig.inject(1);
        await clk.nextNegedge;
        final pop = dec.output('byte_pop').value.toInt();
        await clk.nextPosedge;
        decodeSig.inject(0);
        final hw = dec.output('symbol').value.toInt();
        ptr += pop;
        final expected = range.decode(ref.cdf, ref.n);
        ref.adapt(expected);
        expect(hw, equals(expected), reason: 'symbol $k (ptr $ptr)');
      }

      await Simulator.endSimulation();
    });
  });
}
