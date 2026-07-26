import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _streamBit(List<int> bytes, int p) => (bytes[p >> 3] >> (7 - (p & 7))) & 1;

int _su(List<int> bytes, int offset, int n) {
  var v = 0;
  for (var k = 0; k < n; k++) {
    v = (v << 1) | _streamBit(bytes, offset + k);
  }
  final signMask = 1 << (n - 1);
  if (v & signMask != 0) v -= 1 << n;
  return v;
}

// Place an n-bit two's-complement field at a bit offset in a 16-byte buffer.
List<int> _placeField(int offset, int n, int rawBits) {
  final bytes = List.filled(16, 0);
  for (var k = 0; k < n; k++) {
    final bit = (rawBits >> (n - 1 - k)) & 1;
    if (bit != 0) {
      final p = offset + k;
      bytes[p >> 3] |= 1 << (7 - (p & 7));
    }
  }
  return bytes;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSuReader', () {
    late HarborSuReader r;
    late Logic clk, bytes, offset, n;

    Future<void> setUpDut() async {
      r = HarborSuReader();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      offset = Logic(name: 'bit_offset', width: 8);
      n = Logic(name: 'n', width: 6);
      r.input('bytes').srcConnection! <= bytes;
      r.input('bit_offset').srcConnection! <= offset;
      r.input('n').srcConnection! <= n;
      await r.build();
      bytes.inject(0);
      offset.inject(0);
      n.inject(1);
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

    // (offset, n, rawBits) -- rawBits is the n-bit pattern stored.
    final cases = <(int, int, int)>[
      (0, 4, 0x7), // +7
      (0, 4, 0x8), // -8
      (0, 4, 0xF), // -1
      (3, 5, 0x10), // -16
      (3, 5, 0x0F), // +15
      (7, 8, 0x80), // -128
      (7, 8, 0x7F), // +127
      (8, 1, 0x1), // -1
      (8, 1, 0x0), // 0
      (13, 12, 0xABC), // negative 12-bit
      (20, 16, 0x8000), // -32768
      (20, 16, 0x1234), // positive
    ];

    for (final c in cases) {
      test('su(${c.$2}) @ ${c.$1} raw 0x${c.$3.toRadixString(16)}', () async {
        await setUpDut();
        final buf = _placeField(c.$1, c.$2, c.$3);
        bytes.inject(pack(buf));
        offset.inject(c.$1);
        n.inject(c.$2);
        await clk.nextPosedge;
        final got = r.output('value').value.toBigInt();
        // Interpret the 32-bit output as signed.
        final signed = got >= BigInt.from(0x80000000)
            ? (got - (BigInt.one << 32)).toInt()
            : got.toInt();
        expect(signed, equals(_su(buf, c.$1, c.$2)), reason: 'value');
        expect(
          r.output('next_offset').value.toInt(),
          equals(c.$1 + c.$2),
          reason: 'next_offset',
        );
        await Simulator.endSimulation();
      });
    }
  });
}
