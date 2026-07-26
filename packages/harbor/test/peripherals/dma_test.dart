import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register word indices (the bus presents a word index). Block 0 is global,
// block ch+1 is channel ch. Channel ch base word = 8 * (ch + 1).
const _ctrl = 0;
const _intEnable = 2;
int _chCtrl(int ch) => 8 * (ch + 1);
int _chSrc(int ch) => 8 * (ch + 1) + 2;
int _chDst(int ch) => 8 * (ch + 1) + 3;
int _chLen(int ch) => 8 * (ch + 1) + 4;

void main() {
  group('HarborDmaChannelConfig', () {
    test('defaults', () {
      const config = HarborDmaChannelConfig();
      expect(config.maxBurstLength, equals(16));
      expect(config.scatterGather, isFalse);
    });

    test('toPrettyString', () {
      const config = HarborDmaChannelConfig(scatterGather: true);
      expect(config.toPrettyString(), contains('scatter-gather'));
    });
  });

  group('HarborDmaController', () {
    test('creates with default channels', () {
      final dma = HarborDmaController(baseAddress: 0x30000000);
      expect(dma.bus, isNotNull);
      expect(dma.interrupt.width, equals(1));
      expect(dma.channels, equals(4));
    });

    test('creates with custom channel count', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, channels: 8);
      expect(dma.channels, equals(8));
    });

    test('DT node', () {
      final dma = HarborDmaController(baseAddress: 0x30000000, channels: 2);
      final dt = dma.dtNode;
      expect(dt.compatible.first, equals('harbor,dma'));
      expect(dt.properties['dma-channels'], equals(2));
    });

    test('supports TileLink', () {
      final dma = HarborDmaController(
        baseAddress: 0x30000000,
        protocol: BusProtocol.tilelink,
      );
      expect(dma.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  group('HarborDmaController transfer engine', () {
    late HarborDmaController dma;
    late Logic clk, reset, stb, we, adr, mosi, irq;
    late List<Logic> mem;

    Future<void> bw(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (dma.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    // Build the DUT with a 16-word memory model on the master port, preloaded
    // with [dmaMem].
    Future<void> setUpDut(List<int> dmaMem) async {
      dma = HarborDmaController(baseAddress: 0x30000000, channels: 2);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);

      dma.input('clk').srcConnection! <= clk;
      dma.input('reset').srcConnection! <= reset;
      dma.input('bus_CYC').srcConnection! <= stb;
      dma.input('bus_STB').srcConnection! <= stb;
      dma.input('bus_WE').srcConnection! <= we;
      dma.input('bus_ADR').srcConnection! <= adr;
      dma.input('bus_DAT_MOSI').srcConnection! <= mosi;
      dma.input('bus_SEL').srcConnection! <=
          Const(0xF, width: dma.input('bus_SEL').width);

      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = dma.output('dma_stb');
      final mWe = dma.output('dma_we');
      final mAddr = dma.output('dma_addr');
      final mWdata = dma.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6);
      Sequential(
        clk,
        reset: reset,
        resetValues: {
          for (var i = 0; i < 16; i++) mem[i]: Const(initVals[i], width: 32),
        },
        [
          If(
            mStb & mWe,
            then: [
              for (var i = 0; i < 16; i++)
                If(mIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
            ],
          ),
        ],
      );
      Logic mRd = mem[15];
      for (var i = 14; i >= 0; i--) {
        mRd = mux(mIdx.eq(Const(i, width: 4)), mem[i], mRd);
      }
      dma.input('dma_rdata').srcConnection! <= mRd;
      dma.input('dma_ack').srcConnection! <= mStb;

      await dma.build();
      irq = dma.output('interrupt');

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    Future<bool> runUntilIrq() async {
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) return true;
      }
      return false;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('mem-to-mem copies a buffer and raises the channel IRQ', () async {
      // Source words 0,1, destination words 8,9 (byte 0x20).
      await setUpDut([0xAAAA1111, 0xBBBB2222]);
      await bw(_ctrl, 1); // global enable
      await bw(_intEnable, 0x1); // channel 0 IRQ
      await bw(_chSrc(0), 0x00);
      await bw(_chDst(0), 0x20);
      await bw(_chLen(0), 8); // 2 words
      await bw(_chCtrl(0), 0x1); // enable, type memToMem -> start

      expect(await runUntilIrq(), isTrue);
      expect(mem[8].value.toInt(), equals(0xAAAA1111));
      expect(mem[9].value.toInt(), equals(0xBBBB2222));
      await Simulator.endSimulation();
    });

    test('periph-to-mem holds the source address fixed', () async {
      await setUpDut([0xC0FFEE00, 0xDEADBEEF]);
      await bw(_ctrl, 1);
      await bw(_intEnable, 0x1);
      await bw(_chSrc(0), 0x00); // fixed source = word 0
      await bw(_chDst(0), 0x20);
      await bw(_chLen(0), 8);
      // type periphToMem (2): source stays fixed, destination increments.
      await bw(_chCtrl(0), 0x1 | (2 << 4));

      expect(await runUntilIrq(), isTrue);
      // Both destination words got the same (fixed) source word.
      expect(mem[8].value.toInt(), equals(0xC0FFEE00));
      expect(mem[9].value.toInt(), equals(0xC0FFEE00));
      await Simulator.endSimulation();
    });
  });
}
