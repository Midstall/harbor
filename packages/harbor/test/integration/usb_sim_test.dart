import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('USB sim', () {
    test('write CTRL and read back', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0xF000,
      );
      usb.port('usb_dp_in').getsLogic(Const(0));
      usb.port('usb_dm_in').getsLogic(Const(0));

      final tb = PeripheralTestBench(usb);
      await tb.init();

      // CTRL byte offset 0x00, bit 0 = enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0xF000,
      );
      usb.port('usb_dp_in').getsLogic(Const(0));
      usb.port('usb_dm_in').getsLogic(Const(0));

      final tb = PeripheralTestBench(usb);
      await tb.init();

      // INT_ENABLE byte offset 0x20
      await tb.write(0x20, 0xA5);
      final val = await tb.read(0x20);
      expect(val, equals(0xA5));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0xF000,
      );
      usb.port('usb_dp_in').getsLogic(Const(0));
      usb.port('usb_dm_in').getsLogic(Const(0));

      final tb = PeripheralTestBench(usb);
      await tb.init();

      // STATUS byte offset 0x08
      final val = await tb.read(0x08);
      // connected should be 0 after reset
      expect(val & 0x01, equals(0));
      // speed field at bits [7:4] should be maxSpeed index (full = 1)
      expect((val >> 4) & 0x0F, equals(HarborUsbSpeed.full.index));

      await Simulator.endSimulation();
    });

    test('write device address (ADDR) and read back', () async {
      final usb = HarborUsbController(
        config: const HarborUsbConfig(),
        baseAddress: 0xF000,
      );
      usb.port('usb_dp_in').getsLogic(Const(0));
      usb.port('usb_dm_in').getsLogic(Const(0));

      final tb = PeripheralTestBench(usb);
      await tb.init();

      // ADDR byte offset 0x10
      await tb.write(0x10, 42);
      final val = await tb.read(0x10);
      expect(val & 0x7F, equals(42));

      await Simulator.endSimulation();
    });
  });
}
