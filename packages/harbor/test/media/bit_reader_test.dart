import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// AV1 stream bit p: byte(p>>3) bit (7 - (p & 7)).
int _streamBit(List<int> bytes, int p) => (bytes[p >> 3] >> (7 - (p & 7))) & 1;

int _fn(List<int> bytes, int offset, int n) {
  var v = 0;
  for (var k = 0; k < n; k++) {
    v = (v << 1) | _streamBit(bytes, offset + k);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborBitReader (f(n))', () {
    late HarborBitReader r;
    late Logic clk, bytes, offset, n;

    Future<void> setUpDut() async {
      r = HarborBitReader();
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
      n.inject(0);
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

    // A fixed pseudo-random 16-byte buffer.
    final buf = [
      0xB5,
      0x1C,
      0xF0,
      0x39,
      0xA7,
      0x6E,
      0x42,
      0xDD,
      0x80,
      0x13,
      0xFF,
      0x01,
      0x5A,
      0xC3,
      0x90,
      0x2B,
    ];

    // (offset, n) reads across byte boundaries and widths.
    final reads = <(int, int)>[
      (0, 1),
      (0, 4),
      (0, 8),
      (3, 5),
      (7, 2),
      (7, 10),
      (8, 16),
      (13, 7),
      (20, 12),
      (31, 1),
      (32, 32),
      (33, 17),
      (60, 24),
      (96, 32),
      (0, 0),
      (100, 20),
    ];

    for (final rd in reads) {
      test('f(${rd.$2}) @ ${rd.$1}', () async {
        await setUpDut();
        bytes.inject(pack(buf));
        offset.inject(rd.$1);
        n.inject(rd.$2);
        await clk.nextPosedge;
        expect(
          r.output('value').value.toInt(),
          equals(_fn(buf, rd.$1, rd.$2)),
          reason: 'value',
        );
        expect(
          r.output('next_offset').value.toInt(),
          equals(rd.$1 + rd.$2),
          reason: 'next_offset',
        );
        await Simulator.endSimulation();
      });
    }

    test('chained reads parse a header prefix', () async {
      await setUpDut();
      bytes.inject(pack(buf));
      // Read f(1), f(3), f(4), f(8) in sequence, threading next_offset.
      var off = 0;
      for (final width in [1, 3, 4, 8]) {
        offset.inject(off);
        n.inject(width);
        await clk.nextPosedge;
        expect(r.output('value').value.toInt(), equals(_fn(buf, off, width)));
        off = r.output('next_offset').value.toInt();
      }
      expect(off, equals(16));
      await Simulator.endSimulation();
    });
  });
}
