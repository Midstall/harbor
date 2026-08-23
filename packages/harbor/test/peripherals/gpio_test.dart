import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _input = 0x00;
const _output = 0x08;
const _dir = 0x10;
const _irqEn = 0x18;
const _irqStatus = 0x20;
const _irqEdge = 0x28;

void main() {
  group('HarborGpio', () {
    test('creates with default pin count', () {
      final gpio = HarborGpio(baseAddress: 0x10001000);
      expect(gpio.bus, isNotNull);
      expect(gpio.gpioOut.width, equals(32));
      expect(gpio.gpioDir.width, equals(32));
      expect(gpio.interrupt.width, equals(1));
    });

    test('creates with custom pin count', () {
      final gpio = HarborGpio(baseAddress: 0x10001000, pinCount: 16);
      expect(gpio.gpioOut.width, equals(16));
      expect(gpio.gpioDir.width, equals(16));
    });

    test('DT node is correct', () {
      final gpio = HarborGpio(baseAddress: 0x10001000, pinCount: 8);
      final dt = gpio.dtNode;
      expect(dt.compatible.first, equals('harbor,gpio'));
      expect(dt.reg.start, equals(0x10001000));
      expect(dt.properties['ngpios'], equals(8));
      expect(dt.properties['gpio-controller'], equals(true));
    });

    test('supports TileLink protocol', () {
      final gpio = HarborGpio(
        baseAddress: 0x10001000,
        protocol: BusProtocol.tilelink,
      );
      expect(gpio.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  group('HarborGpio register access', () {
    late HarborGpio gpio;
    late Logic clk, reset, stb, we, adr, mosi, pins;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (gpio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (gpio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = gpio.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({int dataWidth = 32}) async {
      gpio = HarborGpio(baseAddress: 0x10001000, busDataWidth: dataWidth);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: dataWidth);
      pins = Logic(name: 'gpio_in', width: 32);

      gpio.input('clk').srcConnection! <= clk;
      gpio.input('reset').srcConnection! <= reset;
      gpio.input('bus_CYC').srcConnection! <= stb;
      gpio.input('bus_STB').srcConnection! <= stb;
      gpio.input('bus_WE').srcConnection! <= we;
      gpio.input('bus_ADR').srcConnection! <= adr;
      gpio.input('bus_DAT_MOSI').srcConnection! <= mosi;
      gpio.input('bus_SEL').srcConnection! <=
          Const(-1, width: gpio.input('bus_SEL').width);
      gpio.input('gpio_in').srcConnection! <= pins;

      await gpio.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      pins.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    // Regression: the decode used to match a WORD INDEX (0x04 >> 2) against a
    // byte address, so only register 0 answered. Every write below landed on no
    // case at all, and every read returned zero.
    test('every register decodes at its own 8-byte slot', () async {
      await setUpDut();

      await busWrite(_output, 0xdeadbeef);
      expect(await busRead(_output), equals(0xdeadbeef));
      expect(gpio.gpioOut.value.toInt(), equals(0xdeadbeef));

      await busWrite(_dir, 0x0f0f0f0f);
      expect(await busRead(_dir), equals(0x0f0f0f0f));
      expect(gpio.gpioDir.value.toInt(), equals(0x0f0f0f0f));

      await busWrite(_irqEdge, 0x00ff00ff);
      expect(await busRead(_irqEdge), equals(0x00ff00ff));

      await busWrite(_irqEn, 0x12345678);
      expect(await busRead(_irqEn), equals(0x12345678));

      // The registers are distinct, not aliases of one another.
      expect(await busRead(_output), equals(0xdeadbeef));
      expect(await busRead(_dir), equals(0x0f0f0f0f));
      await Simulator.endSimulation();
    });

    test('INPUT reads the pins and IRQ_STATUS is write-1-to-clear', () async {
      await setUpDut();

      pins.inject(0xa5a5a5a5);
      await clk.nextPosedge;
      expect(await busRead(_input), equals(0xa5a5a5a5));

      // Level-triggered by default, so every high pin latches a status bit.
      expect(await busRead(_irqStatus), equals(0xa5a5a5a5));

      pins.inject(0);
      await clk.nextPosedge;
      await busWrite(_irqStatus, 0xffffffff);
      expect(await busRead(_irqStatus), equals(0));
      await Simulator.endSimulation();
    });

    test('the registers still land in the low word on a 64-bit bus', () async {
      await setUpDut(dataWidth: 64);

      await busWrite(_output, 0xcafef00d);
      expect(await busRead(_output), equals(0xcafef00d));
      await busWrite(_dir, 0x11223344);
      expect(await busRead(_dir), equals(0x11223344));
      expect(await busRead(_output), equals(0xcafef00d));
      await Simulator.endSimulation();
    });
  });
}
