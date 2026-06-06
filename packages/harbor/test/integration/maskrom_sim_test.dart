import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('MaskROM sim', () {
    test('read initial data words back correctly', () async {
      final rom = HarborMaskRom(
        baseAddress: 0x0000,
        initialData: [0x00000297, 0x02028593, 0x0005a583, 0x00058067],
      );

      final tb = PeripheralTestBench(rom);
      await tb.init();

      // The bus carries byte addresses; word i lives at i*4 (proven on
      // hardware: the fetcher issues byte-addressed reads).
      expect(await tb.read(0), equals(0x00000297));
      expect(await tb.read(4), equals(0x02028593));
      expect(await tb.read(8), equals(0x0005a583));
      expect(await tb.read(12), equals(0x00058067));

      await Simulator.endSimulation();
    });

    test('ROM is read-only (write has no effect)', () async {
      final rom = HarborMaskRom(
        baseAddress: 0x0000,
        initialData: [0xDEADBEEF, 0xCAFEBABE],
      );

      final tb = PeripheralTestBench(rom);
      await tb.init();

      // Attempt to write
      await tb.write(0, 0x12345678);

      // Read back - should still be original data
      final val = await tb.read(0);
      expect(val, equals(0xDEADBEEF));

      await Simulator.endSimulation();
    });

    test('read all words from a longer initial data array', () async {
      final data = [
        0x00000013, // nop
        0x00100093, // li x1, 1
        0x00200113, // li x2, 2
        0x00300193, // li x3, 3
        0x00400213, // li x4, 4
        0x00500293, // li x5, 5
        0x00600313, // li x6, 6
        0x00700393, // li x7, 7
      ];
      final rom = HarborMaskRom(baseAddress: 0x0000, initialData: data);

      final tb = PeripheralTestBench(rom);
      await tb.init();

      for (var i = 0; i < data.length; i++) {
        final val = await tb.read(i * 4);
        expect(val, equals(data[i]), reason: 'Mismatch at word $i');
      }

      await Simulator.endSimulation();
    });
  });
}
