import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('HarborSpiController', () {
    test('creates with defaults', () {
      final spi = HarborSpiController(baseAddress: 0x10002000);
      expect(spi.bus, isNotNull);
      expect(spi.interrupt.width, equals(1));
    });

    test('creates with multiple chip selects', () {
      final spi = HarborSpiController(baseAddress: 0x10002000, csCount: 4);
      final dt = spi.dtNode;
      expect(dt.properties['num-cs'], equals(4));
    });

    test('DT node is correct', () {
      final spi = HarborSpiController(baseAddress: 0x10002000);
      final dt = spi.dtNode;
      expect(dt.compatible.first, equals('harbor,spi'));
      expect(dt.reg.start, equals(0x10002000));
    });

    test('supports both bus protocols', () {
      final wb = HarborSpiController(
        baseAddress: 0x1000,
        protocol: BusProtocol.wishbone,
      );
      final tl = HarborSpiController(
        baseAddress: 0x1000,
        protocol: BusProtocol.tilelink,
      );
      expect(wb.bus.protocol, equals(BusProtocol.wishbone));
      expect(tl.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  // Byte-address register map (see HarborSpiController): each register is in
  // its own 64-bit-aligned slot.
  const ctrl = 0x00;
  const status = 0x08;
  const data = 0x10;
  const divider = 0x18;

  group('HarborSpiController loopback (functional)', () {
    late HarborSpiController spi;
    late Logic clk, reset, cyc, stb, we, adr, mosi, miso;

    Future<void> busWrite(int addr, int value) async {
      adr.inject(addr);
      mosi.inject(value);
      we.inject(1);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final d = spi.bus.dataOut.value.toInt();
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      return d;
    }

    tearDown(() async => Simulator.reset());

    test(
      'a byte written in loopback returns intact (no bit rotation)',
      () async {
        spi = HarborSpiController(baseAddress: 0x1000);
        clk = SimpleClockGenerator(10).clk;
        reset = Logic(name: 'reset');
        cyc = Logic(name: 'cyc');
        stb = Logic(name: 'stb');
        we = Logic(name: 'we');
        adr = Logic(name: 'adr', width: spi.input('bus_ADR').width);
        mosi = Logic(name: 'mosi', width: 32);
        miso = Logic(name: 'miso');

        spi.input('clk').srcConnection! <= clk;
        spi.input('reset').srcConnection! <= reset;
        spi.input('bus_CYC').srcConnection! <= cyc;
        spi.input('bus_STB').srcConnection! <= stb;
        spi.input('bus_WE').srcConnection! <= we;
        spi.input('bus_ADR').srcConnection! <= adr;
        spi.input('bus_DAT_MOSI').srcConnection! <= mosi;
        spi.input('bus_SEL').srcConnection! <=
            Const(0xF, width: spi.input('bus_SEL').width);
        spi.input('spi_miso').srcConnection! <= miso;

        await spi.build();
        reset.inject(1);
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        miso.inject(0);
        Simulator.setMaxSimTime(1000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        // At reset STATUS must show tx_empty (bit1) set: proves the byte-address
        // decode reaches the right register (the old word-index decode read 0).
        expect(await busRead(status), equals(0x2));

        await busWrite(divider, 1);
        await busWrite(ctrl, 0x9); // enable | loopback
        await busWrite(data, 0xA5); // start a transfer

        var st = await busRead(status);
        var guard = 0;
        while (st & 0x1 != 0 && guard < 200) {
          st = await busRead(status);
          guard++;
        }
        expect(st & 0x1, equals(0), reason: 'transfer should finish');

        // Loopback feeds MOSI back to MISO: an 8-bit exchange must return the
        // exact byte. A one-bit rotation here is the "capture before the 8th
        // shift" bug.
        expect(await busRead(data) & 0xFF, equals(0xA5));

        await Simulator.endSimulation();
      },
    );
  });
}
