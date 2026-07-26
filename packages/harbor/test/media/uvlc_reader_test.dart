import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Append the uvlc encoding of v (MSB-first) to a growing bit list.
void _encodeUvlc(List<int> bits, int v) {
  // leadingZeros = floor(log2(v+1)). Write that many 0s, a 1, then the value.
  final x = v + 1;
  final lz = x.bitLength - 1;
  for (var i = 0; i < lz; i++) {
    bits.add(0);
  }
  bits.add(1);
  for (var i = lz - 1; i >= 0; i--) {
    bits.add((v + 1 - (1 << lz) >> i) & 1);
  }
}

// uvlc reference decode at a bit offset over a bit list.
(int, int) _uvlc(List<int> bits, int offset) {
  var lz = 0;
  var p = offset;
  while (p < bits.length && bits[p] == 0) {
    lz++;
    p++;
  }
  p++; // the terminating 1
  if (lz >= 32) return (0xFFFFFFFF, offset + 2 * lz + 1);
  var suffix = 0;
  for (var i = 0; i < lz; i++) {
    suffix = (suffix << 1) | bits[p++];
  }
  return (suffix + (1 << lz) - 1, offset + 2 * lz + 1);
}

List<int> _bitsToBytes(List<int> bits) {
  final bytes = List.filled(16, 0);
  for (var i = 0; i < bits.length && i < 128; i++) {
    if (bits[i] != 0) bytes[i >> 3] |= 1 << (7 - (i & 7));
  }
  return bytes;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUvlcReader', () {
    late HarborUvlcReader r;
    late Logic clk, bytes, offset;

    Future<void> setUpDut() async {
      r = HarborUvlcReader();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      offset = Logic(name: 'bit_offset', width: 8);
      r.input('bytes').srcConnection! <= bytes;
      r.input('bit_offset').srcConnection! <= offset;
      await r.build();
      bytes.inject(0);
      offset.inject(0);
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

    // Single uvlc value placed at a given starting offset (padded with leading
    // junk bits so we exercise non-zero offsets).
    final values = [0, 1, 2, 3, 4, 7, 8, 15, 100, 1000, 65535, 1000000];
    for (final pad in [0, 1, 5, 8, 13]) {
      for (final v in values) {
        test('uvlc $v @ offset $pad', () async {
          await setUpDut();
          final bits = <int>[for (var i = 0; i < pad; i++) (i * 7) & 1];
          _encodeUvlc(bits, v);
          final buf = _bitsToBytes(bits);
          bytes.inject(pack(buf));
          offset.inject(pad);
          await clk.nextPosedge;
          final exp = _uvlc(bits, pad);
          expect(
            r.output('value').value.toInt(),
            equals(exp.$1),
            reason: 'value',
          );
          expect(
            r.output('next_offset').value.toInt(),
            equals(exp.$2),
            reason: 'next_offset',
          );
          await Simulator.endSimulation();
        });
      }
    }

    test('chained uvlc reads (frame-size style)', () async {
      await setUpDut();
      final seq = [1919, 1079, 0, 5];
      final bits = <int>[];
      for (final v in seq) {
        _encodeUvlc(bits, v);
      }
      final buf = _bitsToBytes(bits);
      bytes.inject(pack(buf));
      var off = 0;
      for (final v in seq) {
        offset.inject(off);
        await clk.nextPosedge;
        expect(r.output('value').value.toInt(), equals(v), reason: 'v=$v');
        off = r.output('next_offset').value.toInt();
      }
      await Simulator.endSimulation();
    });
  });
}
