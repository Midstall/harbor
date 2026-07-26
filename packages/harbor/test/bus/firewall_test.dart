import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('HarborBusFirewall', () {
    // Fixed compile-time whitelist: two 0x100-byte windows.
    const whitelist = [
      BusAddressRange(0x1000, 0x100),
      BusAddressRange(0x4000, 0x100),
    ];

    late Logic addr;
    late Logic len;
    late Logic valid;
    late HarborBusFirewall fw;

    setUp(() async {
      addr = Logic(name: 'addr', width: 32);
      len = Logic(name: 'len', width: 8);
      valid = Logic(name: 'valid');
      fw = HarborBusFirewall(
        addr: addr,
        len: len,
        valid: valid,
        whitelist: whitelist,
      );
      await fw.build();
    });

    /// Drive inputs, settle the combinational net, return the allow bit.
    Future<int> probe(int a, int l, {int v = 1}) async {
      addr.inject(a);
      len.inject(l);
      valid.inject(v);
      await Simulator.tick();
      return fw.allow.value.toInt();
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('single-beat addr in range -> allow=1', () async {
      expect(await probe(0x1000, 1), equals(1));
    });

    test('addr just below base (0x0FFC) -> allow=0', () async {
      expect(await probe(0x0FFC, 1), equals(0));
    });

    test('addr at last in-range word (0x10FC, len 1) -> allow=1', () async {
      // last byte = 0x10FC + 1*4 - 1 = 0x10FF == base+size-1.
      expect(await probe(0x10FC, 1), equals(1));
    });

    test('burst whose last beat exits the range -> allow=0', () async {
      // addr 0x10F8, len 4, stride 4 -> last byte 0x10F8 + 16 - 1 = 0x1107.
      expect(await probe(0x10F8, 4), equals(0));
    });

    test('addr fully outside (0x9000) -> allow=0', () async {
      expect(await probe(0x9000, 1), equals(0));
    });

    test('addr in the SECOND range -> allow=1', () async {
      expect(await probe(0x4000, 1), equals(1));
    });

    test('valid=0 forces allow=0 even in range', () async {
      expect(await probe(0x1000, 1, v: 0), equals(0));
    });

    test('burst exactly filling a range -> allow=1', () async {
      // base 0x1000, 0x100 bytes / stride 4 = 64 beats, last byte 0x10FF.
      expect(await probe(0x1000, 64), equals(1));
    });

    test('burst one beat too long -> allow=0', () async {
      expect(await probe(0x1000, 65), equals(0));
    });
  });
}
