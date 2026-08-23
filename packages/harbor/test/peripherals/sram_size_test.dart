import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// A memory must be the size it was asked for, or say so.
///
/// The generic model builds a register and a mux leg per word, so it cannot
/// reach far. Quietly building a smaller memory is the dangerous outcome:
/// every access above the cut vanishes (writes dropped, reads zero) while the
/// device tree still advertises the full size, so the failure appears far from
/// its cause.
void main() {
  test('a memory too large for the generic model is refused', () {
    expect(
      () => HarborSram(baseAddress: 0, size: 16 * 1024, busAddressWidth: 32),
      throwsArgumentError,
    );
    // Just inside the limit still builds.
    expect(
      HarborSram(baseAddress: 0, size: 4 * 1024, busAddressWidth: 32),
      isA<HarborSram>(),
    );
  });

  test('a Verilator target gets a behavioral array at full size', () async {
    const target = HarborSimTarget(topCell: 'soc', frequency: 25000000);
    final sram = HarborSram(
      baseAddress: 0,
      size: 64 * 1024,
      busAddressWidth: 32,
      target: target,
    );
    await sram.build();

    final array = sram.subModules.whereType<HarborSramArray>().single;
    expect(array.words, equals(16384), reason: '64KiB of 32-bit words');
    final rtl = array.simRtl;
    expect(rtl, contains('module ${array.definitionName} ('));
    expect(rtl, contains('mem [0:16383]'));
    // The protocol has to match the generic model, or a design behaves
    // differently depending on which path built its memory.
    expect(rtl, contains('if (stb && !ack)'));
    expect(rtl, contains('ack <= 1\'b1;'));
    expect(rtl, contains('if (sel[b])'), reason: 'per-lane write enables');
  });

  test('two different memories get different definition names', () {
    // One emitted file per definition: a collision would clobber a body.
    final small = HarborSramArray(words: 1024, dataWidth: 32, addrWidth: 10);
    final big = HarborSramArray(words: 16384, dataWidth: 32, addrWidth: 14);
    expect(small.definitionName, isNot(equals(big.definitionName)));
  });
}
