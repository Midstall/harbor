import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('I2C sim', () {
    test('write prescaler and read back', () async {
      final i2c = HarborI2cController(baseAddress: 0x6000);
      i2c.port('scl_in').getsLogic(Const(1));
      i2c.port('sda_in').getsLogic(Const(1));

      final tb = PeripheralTestBench(i2c);
      await tb.init();

      // PRESCALE byte offset 0x20
      await tb.write(0x20, 200);
      final val = await tb.read(0x20);
      expect(val, equals(200));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final i2c = HarborI2cController(baseAddress: 0x6000);
      i2c.port('scl_in').getsLogic(Const(1));
      i2c.port('sda_in').getsLogic(Const(1));

      final tb = PeripheralTestBench(i2c);
      await tb.init();

      // CTRL byte offset 0x00: bit 0 = enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      final i2c = HarborI2cController(baseAddress: 0x6000);
      i2c.port('scl_in').getsLogic(Const(1));
      i2c.port('sda_in').getsLogic(Const(1));

      final tb = PeripheralTestBench(i2c);
      await tb.init();

      // STATUS byte offset 0x08
      final val = await tb.read(0x08);
      // After reset: busy=0, ack=0, arb_lost=0, rx_ready=0
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write slave address and read back', () async {
      final i2c = HarborI2cController(baseAddress: 0x6000);
      i2c.port('scl_in').getsLogic(Const(1));
      i2c.port('sda_in').getsLogic(Const(1));

      final tb = PeripheralTestBench(i2c);
      await tb.init();

      // ADDR byte offset 0x18
      await tb.write(0x18, 0x50);
      final val = await tb.read(0x18);
      expect(val & 0x7F, equals(0x50));

      await Simulator.endSimulation();
    });
  });
}
