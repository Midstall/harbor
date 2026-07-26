import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SRAM sim', () {
    test('write and read single word', () async {
      final sram = HarborSram(baseAddress: 0x3000, size: 32);
      final tb = PeripheralTestBench(sram);
      await tb.init();

      // Byte addr 0
      await tb.write(0, 0xDEADBEEF);
      final val = await tb.read(0);
      expect(val, equals(0xDEADBEEF));

      await Simulator.endSimulation();
    });

    test('write and read multiple words', () async {
      final sram = HarborSram(baseAddress: 0x3000, size: 32);
      final tb = PeripheralTestBench(sram);
      await tb.init();

      final addrs = [0, 4, 8, 12, 20];
      final values = [
        0x11111111,
        0x22222222,
        0x33333333,
        0x44444444,
        0x66666666,
      ];

      for (var i = 0; i < addrs.length; i++) {
        await tb.write(addrs[i], values[i]);
      }

      for (var i = 0; i < addrs.length; i++) {
        final val = await tb.read(addrs[i]);
        expect(
          val,
          equals(values[i]),
          reason: 'Mismatch at byte addr ${addrs[i]}',
        );
      }

      await Simulator.endSimulation();
    });

    test('overwrite preserves other words', () async {
      final sram = HarborSram(baseAddress: 0x3000, size: 32);
      final tb = PeripheralTestBench(sram);
      await tb.init();

      await tb.write(0, 0xAAAAAAAA);
      await tb.write(4, 0xBBBBBBBB);

      // Overwrite word 0
      await tb.write(0, 0xCCCCCCCC);

      final val0 = await tb.read(0);
      final val1 = await tb.read(4);
      expect(val0, equals(0xCCCCCCCC));
      expect(val1, equals(0xBBBBBBBB));

      await Simulator.endSimulation();
    });

    test('fill entire memory and read all back', () async {
      // 32 bytes = 8 words
      final sram = HarborSram(baseAddress: 0x3000, size: 32);
      final tb = PeripheralTestBench(sram);
      await tb.init();

      for (var i = 0; i < 8; i++) {
        await tb.write(i * 4, 0x10000000 + i);
      }

      for (var i = 0; i < 8; i++) {
        final val = await tb.read(i * 4);
        expect(val, equals(0x10000000 + i), reason: 'Mismatch at word $i');
      }

      await Simulator.endSimulation();
    });

    test(
      'sub-word byte stores honor SEL and do not clobber neighbors',
      () async {
        // Fill all 8 byte lanes of one 64-bit word via 8 separate SEL-masked
        // stores. Before the sim model honored SEL each store wrote the whole
        // word, so only the last byte survived (this is exactly what wedged the
        // maskrom banner: the message read back with one lane set). All 8 must
        // now coexist.
        final sram = HarborSram(baseAddress: 0x3000, size: 64, dataWidth: 64);
        final tb = PeripheralTestBench(sram);
        await tb.init();

        final bytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
        for (var lane = 0; lane < 8; lane++) {
          await tb.write(0, bytes[lane] << (lane * 8), sel: 1 << lane);
        }

        final val = await tb.read(0);
        expect(
          val,
          equals(0x8877665544332211),
          reason: 'byte lanes clobbered: ${val.toRadixString(16)}',
        );

        await Simulator.endSimulation();
      },
    );

    test('unwritten word reads 0', () async {
      final sram = HarborSram(baseAddress: 0x3000, size: 32);
      final tb = PeripheralTestBench(sram);
      await tb.init();

      final val = await tb.read(0);
      expect(val, equals(0));

      await Simulator.endSimulation();
    });
  });
}
