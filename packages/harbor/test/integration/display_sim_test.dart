import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Display sim', () {
    test('write H_ACTIVE = 640 and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // H_ACTIVE byte offset 0x20
      await tb.write(0x20, 640);
      final val = await tb.read(0x20);
      expect(val, equals(640));

      await Simulator.endSimulation();
    });

    test('write V_ACTIVE = 480 and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // V_ACTIVE byte offset 0x30
      await tb.write(0x30, 480);
      final val = await tb.read(0x30);
      expect(val, equals(480));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // CTRL byte offset 0x00, bit 0 = enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write FB_BASE and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // FB_BASE byte offset 0x10
      await tb.write(0x10, 0x40000000);
      final val = await tb.read(0x10);
      expect(val, equals(0x40000000));

      await Simulator.endSimulation();
    });

    test('write FB_STRIDE and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // FB_STRIDE byte offset 0x18
      await tb.write(0x18, 2560);
      final val = await tb.read(0x18);
      expect(val, equals(2560));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0xC000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));

      final tb = PeripheralTestBench(display);
      await tb.init();

      // INT_ENABLE byte offset 0x48
      await tb.write(0x48, 0x03);
      final val = await tb.read(0x48);
      expect(val & 0x0F, equals(0x03));

      await Simulator.endSimulation();
    });
  });
}
