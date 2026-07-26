import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// Verifies the DP16KD INITVAL bit-packing math against the yosys
/// brams_map_16kd.v `init_slice` convention. The DP16KD has no INITVAL-honoring
/// sim model, so this round-trip (pack -> unpack via the documented formula) is
/// the correctness gate for the ROM contents before hardware.
void main() {
  // Unpack per init_slice: word(addr) = INITVAL[addr~/16] bits
  // [(addr%16)*20 +: 18].
  BigInt unpack(List<BigInt> initVals, int addr) {
    final slice = initVals[addr ~/ 16];
    final i = addr % 16;
    final mask18 = (BigInt.one << 18) - BigInt.one;
    return (slice >> (i * 20)) & mask18;
  }

  test('initVals round-trips 18-bit words at every address', () {
    final mask18 = (BigInt.one << 18) - BigInt.one;
    // Deterministic 18-bit pattern across the full 1024-deep block.
    final words = [
      for (var a = 0; a < 700; a++)
        (BigInt.from(a) * BigInt.from(0x2D5) + BigInt.from(0x3C7)) & mask18,
    ];
    final init = Ecp5InitRomPackTestAccess.initVals(words);
    expect(init.length, equals(64));
    for (var a = 0; a < 1024; a++) {
      final expected = a < words.length ? words[a] : BigInt.zero;
      expect(unpack(init, a), equals(expected), reason: 'addr $a');
    }
    // Each INITVAL fits in 320 bits.
    for (final v in init) {
      expect(v.bitLength <= 320, isTrue);
    }
  });

  test('initVals masks values wider than 18 bits to the low 18 bits', () {
    final init = Ecp5InitRomPackTestAccess.initVals([
      (BigInt.one << 40) - BigInt.one, // all ones, 40 bits
    ]);
    expect(unpack(init, 0), equals((BigInt.one << 18) - BigInt.one));
  });
}

/// Thin alias so the test names the public static without importing internals.
class Ecp5InitRomPackTestAccess {
  static List<BigInt> initVals(List<BigInt> words) =>
      Ecp5Dp16kd.initVals(words);
}
