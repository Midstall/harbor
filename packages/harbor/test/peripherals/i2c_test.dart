import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _status = 0x08;
const _data = 0x10;
const _addr = 0x18;
const _prescale = 0x20;
const _cmd = 0x28;

void main() {
  group('HarborI2cController', () {
    test('creates with correct ports', () {
      final i2c = HarborI2cController(baseAddress: 0x10003000);
      expect(i2c.bus, isNotNull);
      expect(i2c.interrupt.width, equals(1));
    });

    test('DT node is correct', () {
      final i2c = HarborI2cController(baseAddress: 0x10003000);
      final dt = i2c.dtNode;
      expect(dt.compatible.first, equals('harbor,i2c'));
      expect(dt.reg.start, equals(0x10003000));
    });

    test('supports TileLink', () {
      final i2c = HarborI2cController(
        baseAddress: 0x10003000,
        protocol: BusProtocol.tilelink,
      );
      expect(i2c.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  group('HarborI2cController register access', () {
    late HarborI2cController i2c;
    late Logic clk, reset, stb, we, adr, mosi;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (i2c.output('bus_ACK').value.toInt() != 1) {
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
      while (i2c.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = i2c.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({int dataWidth = 32}) async {
      i2c = HarborI2cController(
        baseAddress: 0x10003000,
        busDataWidth: dataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: dataWidth);

      i2c.input('clk').srcConnection! <= clk;
      i2c.input('reset').srcConnection! <= reset;
      i2c.input('bus_CYC').srcConnection! <= stb;
      i2c.input('bus_STB').srcConnection! <= stb;
      i2c.input('bus_WE').srcConnection! <= we;
      i2c.input('bus_ADR').srcConnection! <= adr;
      i2c.input('bus_DAT_MOSI').srcConnection! <= mosi;
      i2c.input('bus_SEL').srcConnection! <=
          Const(-1, width: i2c.input('bus_SEL').width);
      i2c.input('scl_in').srcConnection! <= Const(1);
      i2c.input('sda_in').srcConnection! <= Const(1);

      await i2c.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
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

    // Regression: the decode used to match a WORD INDEX (0, 1, 2, ...) against
    // a byte address, so only CTRL answered. PRESCALE and ADDR never took a
    // write, which left the controller clocking SCL at its reset rate and
    // addressing slave 0.
    test('every register decodes at its own 8-byte slot', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x3); // enable + irq enable
      expect(await busRead(_ctrl), equals(0x3));

      await busWrite(_prescale, 0x1234);
      expect(await busRead(_prescale), equals(0x1234));

      await busWrite(_addr, 0x50);
      expect(await busRead(_addr), equals(0x50));

      // The registers are distinct, not aliases of one another.
      expect(await busRead(_ctrl), equals(0x3));
      expect(await busRead(_prescale), equals(0x1234));
      await Simulator.endSimulation();
    });

    test('ADDR keeps 7 bits and PRESCALE keeps 16', () async {
      await setUpDut();

      await busWrite(_addr, 0xff); // only [6:0] is the slave address
      expect(await busRead(_addr), equals(0x7f));

      await busWrite(_prescale, 0xdeadbeef);
      expect(await busRead(_prescale), equals(0xbeef));
      await Simulator.endSimulation();
    });

    test('STATUS reads idle, and DATA is its own register', () async {
      await setUpDut();

      // Nothing has been commanded, so busy and the error flags are clear.
      expect(await busRead(_status), equals(0));

      // A DATA write fills TX and must not disturb the neighbouring slots.
      await busWrite(_prescale, 0x0099);
      await busWrite(_data, 0xa5);
      expect(await busRead(_prescale), equals(0x0099));
      await Simulator.endSimulation();
    });

    test('CMD start sets busy, and it is not an alias of CTRL', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x1); // enable
      await busWrite(_prescale, 0x0004);
      expect(await busRead(_status) & 0x1, equals(0)); // idle

      await busWrite(_cmd, 0x1); // START
      expect(await busRead(_status) & 0x1, equals(0x1)); // busy
      expect(await busRead(_ctrl), equals(0x1)); // CTRL untouched
      await Simulator.endSimulation();
    });

    test('the registers still land in the low word on a 64-bit bus', () async {
      await setUpDut(dataWidth: 64);

      await busWrite(_prescale, 0x4321);
      expect(await busRead(_prescale), equals(0x4321));
      await busWrite(_addr, 0x2a);
      expect(await busRead(_addr), equals(0x2a));
      expect(await busRead(_prescale), equals(0x4321));
      await Simulator.endSimulation();
    });
  });
}
