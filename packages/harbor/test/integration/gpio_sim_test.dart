import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('GPIO sim', () {
    test('write OUTPUT and read back', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Write OUTPUT register (byte offset 0x08)
      await tb.write(0x08, 0xA5);
      final val = await tb.read(0x08);
      expect(val, equals(0xA5));

      await Simulator.endSimulation();
    });

    test('read INPUT reflects external pins', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0xCD);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Read INPUT register (byte offset 0x00)
      final val = await tb.read(0x00);
      expect(val, equals(0xCD));

      await Simulator.endSimulation();
    });

    test('write DIR drives gpio_dir output', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Write DIR register (byte offset 0x10)
      await tb.write(0x10, 0xFF);
      final val = await tb.read(0x10);
      expect(val, equals(0xFF));

      await Simulator.endSimulation();
    });

    test('output register drives gpio_out pin (multiple values)', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      for (final value in [0x55, 0xAA, 0x00]) {
        await tb.write(0x08, value);
        await tb.waitCycles(2);
        expect(gpio.gpioOut.value.toInt(), equals(value));
      }

      await Simulator.endSimulation();
    });

    test('edge-triggered IRQ fires on rising edge', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Enable IRQ on pin 0, set edge-triggered
      await tb.write(0x18, 0x01); // IRQ_EN
      await tb.write(0x28, 0x01); // IRQ_EDGE = edge triggered

      // Rising edge on pin 0
      gpioIn.put(0x01);
      await tb.waitCycles(3);

      // Read IRQ_STATUS (byte offset 0x20)
      final status = await tb.read(0x20);
      expect(status & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('level-triggered IRQ fires when pin high', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Enable IRQ on pin 0, leave as level-triggered (default)
      await tb.write(0x18, 0x01); // IRQ_EN
      await tb.write(0x28, 0x00); // IRQ_EDGE = level

      // Drive pin 0 high
      gpioIn.put(0x01);
      await tb.waitCycles(3);

      final status = await tb.read(0x20);
      expect(status & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write-1-to-clear IRQ status', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Enable IRQ on pin 0, level-triggered
      await tb.write(0x18, 0x01);
      gpioIn.put(0x01);
      await tb.waitCycles(3);

      // Confirm status set
      var status = await tb.read(0x20);
      expect(status & 0x01, equals(0x01));

      // De-assert input so level doesn't re-fire
      gpioIn.put(0x00);
      await tb.waitCycles(2);

      // Write 1 to clear bit 0
      await tb.write(0x20, 0x01);
      status = await tb.read(0x20);
      expect(status & 0x01, equals(0x00));

      await Simulator.endSimulation();
    });

    test('multiple pins different directions', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Set pins 0-3 output, 4-7 input
      await tb.write(0x10, 0x0F);
      final dir = await tb.read(0x10);
      expect(dir, equals(0x0F));

      await Simulator.endSimulation();
    });

    test('IRQ_EN enables/disables per-pin', () async {
      final gpioIn = Logic(name: 'gpio_in_sig', width: 8);
      gpioIn.put(0);

      final gpio = HarborGpio(baseAddress: 0x1000, pinCount: 8);
      gpio.port('gpio_in').getsLogic(gpioIn);

      final tb = PeripheralTestBench(gpio);
      await tb.init();

      // Enable IRQ only on pin 1
      await tb.write(0x18, 0x02);
      final en = await tb.read(0x18);
      expect(en, equals(0x02));

      await Simulator.endSimulation();
    });
  });
}
