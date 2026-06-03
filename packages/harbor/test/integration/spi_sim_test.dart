import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SPI sim', () {
    test('write CTRL enable and read back', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // CTRL word addr 0, bit 0 = enable
      await tb.write(0, 0x01);
      final val = await tb.read(0);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS not busy', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // STATUS word addr 1
      final val = await tb.read(1);
      // bit 0 = busy, should be 0 after reset
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write clock divider and read back', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // DIVIDER word addr 3
      await tb.write(3, 42);
      final val = await tb.read(3);
      expect(val, equals(42));

      await Simulator.endSimulation();
    });

    test('CS initial state is deasserted (high)', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      await tb.waitCycles(2);
      // spi_cs_n is ~csReg. csReg resets to 0, so cs_n should be high (1)
      expect(spi.output('spi_cs_n').value.toInt(), equals(1));

      await Simulator.endSimulation();
    });
  });
}
