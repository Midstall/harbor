import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _floorLog2(int x) => x.bitLength - 1;

// Encode value (in [0,n)) with ns(n), appending bits MSB-first.
void _encodeNs(List<int> bits, int value, int n) {
  final w = _floorLog2(n) + 1;
  final m = (1 << w) - n;
  if (value < m) {
    for (var k = w - 2; k >= 0; k--) {
      bits.add((value >> k) & 1);
    }
  } else {
    final coded = value + m;
    for (var k = w - 1; k >= 0; k--) {
      bits.add((coded >> k) & 1);
    }
  }
}

(int, int) _decodeNs(List<int> bits, int offset, int n) {
  final w = _floorLog2(n) + 1;
  final m = (1 << w) - n;
  var p = offset;
  var v = 0;
  for (var k = 0; k < w - 1; k++) {
    v = (v << 1) | bits[p++];
  }
  if (v < m) return (v, p);
  final extra = bits[p++];
  return ((v << 1) - m + extra, p);
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

  group('HarborNsReader', () {
    late HarborNsReader r;
    late Logic clk, bytes, offset, n;

    Future<void> setUpDut() async {
      r = HarborNsReader();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      offset = Logic(name: 'bit_offset', width: 8);
      n = Logic(name: 'n', width: 16);
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

    // Exhaustively check every value for several alphabet sizes, at a couple of
    // offsets (ns is offset-agnostic but this exercises threading).
    final alphabets = [1, 2, 3, 5, 6, 7, 8, 9, 13, 100];
    for (final nv in alphabets) {
      for (final pad in [0, 3, 9]) {
        for (var value = 0; value < nv; value += (nv > 16 ? 7 : 1)) {
          test('ns($nv) value $value @ $pad', () async {
            await setUpDut();
            final bits = <int>[for (var i = 0; i < pad; i++) (i * 5) & 1];
            _encodeNs(bits, value, nv);
            bytes.inject(pack(_bitsToBytes(bits)));
            offset.inject(pad);
            n.inject(nv);
            await clk.nextPosedge;
            final exp = _decodeNs(bits, pad, nv);
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
    }
  });
}
