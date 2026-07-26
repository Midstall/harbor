import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference range decoder + adaptive contexts (matching HarborEntropyDecoder).
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

const _scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
const _scan8 = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, //
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, //
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

// Neighbour-context coefficient decode (mirrors HarborCoeffCtxDecoder): decode
// base levels in reverse scan order with the 2D neighbour-template context.
List<int> _decodeCtxBlock(List<int> bits, int n) {
  final range = _Range(bits);
  List<int> base() => [16384, 24576, 30720, 32768];
  final ctxs = [
    _Ctx([for (var i = 0; i < 16; i++) (i + 1) * 2048], 16), // 0 EOB
    _Ctx(base(), 4), // 1 base-EOB
    _Ctx(base(), 4), _Ctx(base(), 4), _Ctx(base(), 4), _Ctx(base(), 4),
    _Ctx(base(), 4), // 2..6 base
    _Ctx([8192, 16384, 24576, 32768], 4), // 7 range
    _Ctx([16384, 32768], 2), // 8 sign
  ];
  int dec(int c) {
    final s = range.decode(ctxs[c].cdf, ctxs[c].n);
    ctxs[c].adapt(s);
    return s;
  }

  final scan = n == 8 ? _scan8 : _scan4;
  final numCoeffs = n * n;
  final levels = List.filled(64, 0);
  final coeffs = List.filled(64, 0);
  var eob = dec(0);
  if (eob > numCoeffs) eob = numCoeffs;
  for (var c = eob - 1; c >= 0; c--) {
    final bp = scan[c];
    final col = bp % n, rowi = bp ~/ n;
    var mag = 0;
    if (col < n - 1) mag += levels[bp + 1];
    if (rowi < n - 1) mag += levels[bp + n];
    if (col < n - 1 && rowi < n - 1) mag += levels[bp + n + 1];
    if (col < n - 2) mag += levels[bp + 2];
    if (rowi < n - 2) mag += levels[bp + 2 * n];
    var ctxSum = (mag + 1) >> 1;
    if (ctxSum > 4) ctxSum = 4;
    final baseCtx = c == eob - 1 ? 1 : 2 + ctxSum;
    final b = dec(baseCtx);
    if (b == 0) {
      levels[bp] = 0;
      coeffs[bp] = 0;
      continue;
    }
    var level = b;
    if (b == 3) {
      var brCnt = 0;
      while (true) {
        final r = dec(7);
        level += r;
        if (r < 3 || brCnt == 3) break;
        brCnt++;
      }
    }
    final sign = dec(8);
    coeffs[bp] = (sign & 1) != 0 ? -level : level;
    levels[bp] = level < 3 ? level : 3;
  }
  return coeffs;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCoeffCtxDecoder', () {
    for (final n in [4, 8]) {
      test('decodes a ${n}x$n block with neighbour-derived contexts', () async {
        final dec = HarborCoeffCtxDecoder();
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final size = Logic(name: 'size');
        final stream = Logic(name: 'stream', width: 64);
        final bytesIn = Logic(name: 'bytes_in', width: 16);
        final coeffAddr = Logic(name: 'coeff_addr', width: dec.posWidth);

        dec.input('clk').srcConnection! <= clk;
        dec.input('reset').srcConnection! <= reset;
        dec.input('start').srcConnection! <= start;
        dec.input('size').srcConnection! <= size;
        dec.input('stall').srcConnection! <= Const(0);
        dec.input('stream').srcConnection! <= stream;
        dec.input('bytes_in').srcConnection! <= bytesIn;
        dec.input('coeff_addr').srcConnection! <= coeffAddr;

        await dec.build();

        final streamBytes = [for (var i = 0; i < 48; i++) (i * 41 + 7) & 0xFF];
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
        size.inject(n == 8 ? 1 : 0);
        stream.inject(0);
        bytesIn.inject(0);
        coeffAddr.inject(0);
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        stream.inject(word0);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);

        var ptr = 8;
        var guard = 0;
        while (dec.output('done').value.toInt() != 1 && guard < 4000) {
          bytesIn.inject((byteAt(ptr) << 8) | byteAt(ptr + 1));
          await clk.nextNegedge;
          final pop = dec.output('byte_pop').value.toInt();
          await clk.nextPosedge;
          ptr += pop;
          guard++;
        }
        expect(dec.output('done').value.toInt(), equals(1), reason: 'finished');

        final expected = _decodeCtxBlock(bits, n);
        final got = <int>[];
        for (var i = 0; i < n * n; i++) {
          coeffAddr.inject(i);
          await clk.nextNegedge;
          got.add(dec.output('coeff_out').value.toInt());
        }
        expect(
          got,
          equals([for (var i = 0; i < n * n; i++) expected[i] & 0xFFFF]),
        );
        await Simulator.endSimulation();
      });
    }
  });
}
