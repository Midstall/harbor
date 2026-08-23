import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

/// A minimal Wishbone slave that single-cycle-acks every write and records the
/// last address, last data, an OR of all data words, and a write count. Used to
/// stand in for memory on the SPI controller's DMA master interface.
class _DmaCaptureSlave extends BridgeModule {
  _DmaCaptureSlave(WishboneConfig cfg)
    : super('DmaCaptureSlave', name: 'capslave') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final ref = addInterface(
      WishboneInterface(cfg),
      name: 'bus',
      role: PairRole.consumer,
    );
    final wb = ref.internalInterface!;

    final ack = Logic(name: 'ack');
    final lastAddr = Logic(name: 'last_addr_r', width: cfg.addressWidth);
    final lastData = Logic(name: 'last_data_r', width: cfg.dataWidth);
    final count = Logic(name: 'count_r', width: 32);
    final dataOr = Logic(name: 'data_or_r', width: cfg.dataWidth);

    wb.ack <= ack;
    wb.datMiso <= Const(0, width: cfg.dataWidth);
    addOutput('o_last_addr', width: cfg.addressWidth) <= lastAddr;
    addOutput('o_last_data', width: cfg.dataWidth) <= lastData;
    addOutput('o_count', width: 32) <= count;
    addOutput('o_data_or', width: cfg.dataWidth) <= dataOr;

    Sequential(input('clk'), [
      If(
        input('reset'),
        then: [
          ack < Const(0),
          lastAddr < Const(0, width: cfg.addressWidth),
          lastData < Const(0, width: cfg.dataWidth),
          count < Const(0, width: 32),
          dataOr < Const(0, width: cfg.dataWidth),
        ],
        orElse: [
          If(
            wb.cyc & wb.stb & ~ack,
            then: [
              ack < Const(1),
              If(
                wb.we,
                then: [
                  lastAddr < wb.adr,
                  lastData < wb.datMosi,
                  dataOr < (dataOr | wb.datMosi),
                  count < (count + Const(1, width: 32)),
                ],
              ),
            ],
            orElse: [ack < Const(0)],
          ),
        ],
      ),
    ]);
  }
}

/// Test bench that programs the SPI controller over its slave bus and captures
/// the DMA master's writes with a [_DmaCaptureSlave]. Mirrors
/// [PeripheralTestBench] but also wires the `dma` master interface.
class _DmaSpiBench extends BridgeModule {
  final HarborSpiController spi;
  late final WishboneMasterTestDriver master;
  late final _DmaCaptureSlave slave;
  late final Logic clk;
  late final int _selWidth;
  int get _fullSel => (1 << _selWidth) - 1;

  Logic get ack => master.output('m_ack');
  Logic get datIn => master.output('m_dat_in');

  _DmaSpiBench(this.spi) : super('DmaSpiBench', name: 'dtb') {
    final clkGen = SimpleClockGenerator(10);
    clk = clkGen.clk;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final wb = spi.interface('bus').internalInterface! as WishboneInterface;
    _selWidth = wb.config.effectiveSelWidth;
    final dmaWb = spi.interface('dma').internalInterface! as WishboneInterface;

    master = WishboneMasterTestDriver(config: wb.config);
    slave = _DmaCaptureSlave(dmaWb.config);
    addSubModule(master);
    addSubModule(spi);
    addSubModule(slave);

    connectPorts(port('clk'), master.port('clk'));
    connectPorts(port('clk'), spi.port('clk'));
    connectPorts(port('reset'), spi.port('reset'));
    connectPorts(port('clk'), slave.port('clk'));
    connectPorts(port('reset'), slave.port('reset'));
    connectInterfaces(master.interface('bus'), spi.interface('bus'));
    connectInterfaces(spi.interface('dma'), slave.interface('bus'));

    pullUpPort(master.port('m_cyc'), newPortName: 'cyc');
    pullUpPort(master.port('m_stb'), newPortName: 'stb');
    pullUpPort(master.port('m_we'), newPortName: 'we');
    pullUpPort(master.port('m_adr'), newPortName: 'adr');
    pullUpPort(master.port('m_dat_out'), newPortName: 'dat_out');
    pullUpPort(master.port('m_sel'), newPortName: 'sel');
  }

  Future<void> init({int maxSimTime = 200000}) async {
    port('clk').getsLogic(clk);
    final resetSig = Logic(name: 'tb_reset');
    port('reset').getsLogic(resetSig);
    await build();

    resetSig.inject(1);
    input('cyc').inject(0);
    input('stb').inject(0);
    input('we').inject(0);
    input('adr').inject(0);
    input('dat_out').inject(0);
    input('sel').inject(_fullSel);

    Simulator.setMaxSimTime(maxSimTime);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    await clk.nextPosedge;
    resetSig.put(0);
    await clk.nextPosedge;
  }

  Future<void> write(int address, int data) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(1);
    input('adr').put(address);
    input('dat_out').put(data);
    input('sel').put(_fullSel);
    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) break;
    }
    input('cyc').put(0);
    input('stb').put(0);
    input('we').put(0);
    await clk.nextPosedge;
  }

  Future<int> read(int address) async {
    input('cyc').put(1);
    input('stb').put(1);
    input('we').put(0);
    input('adr').put(address);
    var data = 0;
    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
      if (ack.value.isValid && ack.value.toInt() == 1) {
        data = datIn.value.isValid ? datIn.value.toInt() : 0;
        break;
      }
    }
    input('cyc').put(0);
    input('stb').put(0);
    await clk.nextPosedge;
    return data;
  }

  Future<void> waitCycles(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  int slaveOut(String name) {
    final v = slave.output(name).value;
    return v.isValid ? v.toInt() : -1;
  }
}

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

      // CTRL byte addr 0x00, bit 0 = enable. Registers sit 8 bytes apart, so
      // the bench drives byte addresses (matching the controller's decode).
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS not busy', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // STATUS byte addr 0x08
      final val = await tb.read(0x08);
      // bit 0 = busy, should be 0 after reset
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write clock divider and read back', () async {
      final spi = HarborSpiController(baseAddress: 0x5000);
      spi.port('spi_miso').getsLogic(Const(0));

      final tb = PeripheralTestBench(spi);
      await tb.init();

      // DIVIDER byte addr 0x18
      await tb.write(0x18, 42);
      final val = await tb.read(0x18);
      expect(val, equals(42));

      await Simulator.endSimulation();
    });

    test('DMA read packs SPI bytes into memory words (32-bit fabric)', () async {
      // dma:true adds the Wishbone master engine. Drive MISO high so every
      // clocked-in byte is 0xFF; the capture slave acks and records each beat.
      // 8 bytes over a 32-bit fabric = two 0xFFFFFFFF words at 0x100/0x104.
      final spi = HarborSpiController(baseAddress: 0x5000, dma: true);
      spi.port('spi_miso').getsLogic(Const(1));

      final tb = _DmaSpiBench(spi);
      await tb.init();

      await tb.write(0x00, 0x01); // CTRL: enable
      await tb.write(0x18, 1); // DIVIDER: fast
      await tb.write(0x28, 0x100); // DMA_ADDR
      await tb.write(0x30, 8); // DMA_LEN: 8 bytes
      await tb.write(0x38, 0x01); // DMA_CTRL: START, DIR=0

      await tb.waitCycles(800);

      expect(tb.slaveOut('o_count'), equals(2), reason: '2 word writes');
      expect(tb.slaveOut('o_last_addr'), equals(0x104));
      expect(tb.slaveOut('o_last_data'), equals(0xFFFFFFFF));
      expect(
        tb.slaveOut('o_data_or'),
        equals(0xFFFFFFFF),
        reason: 'every packed byte was 0xFF',
      );

      await Simulator.endSimulation();
    });

    test(
      'DMA handles back-to-back transfers (GPT/FAT sequential reads)',
      () async {
        // GPT/FAT parsing issues many separate block reads. Verify the FSM
        // re-initialises cleanly between transfers: run two DMAs and confirm the
        // second lands the right words at the right address with DMA_DONE re-set.
        final spi = HarborSpiController(baseAddress: 0x5000, dma: true);
        spi.port('spi_miso').getsLogic(Const(1));

        final tb = _DmaSpiBench(spi);
        await tb.init();

        await tb.write(0x00, 0x01); // CTRL enable
        await tb.write(0x18, 1); // DIVIDER fast

        // Transfer 1: 8 bytes to 0x100 -> two words.
        await tb.write(0x28, 0x100);
        await tb.write(0x30, 8);
        await tb.write(0x38, 0x01); // START
        await tb.waitCycles(800);
        expect(tb.slaveOut('o_count'), equals(2), reason: 'first transfer');
        expect(tb.slaveOut('o_last_addr'), equals(0x104));

        // Transfer 2: 8 bytes to a fresh 0x200 -> two more words, no leftover
        // state from transfer 1 (address/byte-index/word all re-init on START).
        await tb.write(0x28, 0x200);
        await tb.write(0x30, 8);
        await tb.write(0x38, 0x01); // START
        await tb.waitCycles(800);
        expect(tb.slaveOut('o_count'), equals(4), reason: 'both transfers');
        expect(tb.slaveOut('o_last_addr'), equals(0x204));
        expect(tb.slaveOut('o_last_data'), equals(0xFFFFFFFF));

        // DMA_DONE is latched again after the second transfer.
        final status = await tb.read(0x08);
        expect((status >> 4) & 0x1, equals(1), reason: 'DMA_DONE re-set');

        await Simulator.endSimulation();
      },
    );

    test('DMA_DONE is write-1-to-clear through STATUS (W1C ack)', () async {
      // STATUS (0x08) is read-only except DMA_DONE (bit 4), which a driver
      // acknowledges by writing a 1 to it. Before this was wired the STATUS
      // write was a no-op, so DMA_DONE stayed set and a driver polling it read a
      // stale done from an earlier transfer (the bug that corrupted back-to-back
      // reads). Confirm one DMA sets DONE, a non-bit-4 write leaves it, and a
      // bit-4 write clears it.
      final spi = HarborSpiController(baseAddress: 0x5000, dma: true);
      spi.port('spi_miso').getsLogic(Const(1));

      final tb = _DmaSpiBench(spi);
      await tb.init();

      await tb.write(0x00, 0x01); // CTRL enable
      await tb.write(0x18, 1); // DIVIDER fast
      await tb.write(0x28, 0x100); // DMA_ADDR
      await tb.write(0x30, 8); // DMA_LEN
      await tb.write(0x38, 0x01); // START
      await tb.waitCycles(800);

      var status = await tb.read(0x08);
      expect(
        (status >> 4) & 0x1,
        equals(1),
        reason: 'DMA_DONE set after transfer',
      );

      // A STATUS write without bit 4 must not disturb DMA_DONE.
      await tb.write(0x08, 0x01);
      status = await tb.read(0x08);
      expect(
        (status >> 4) & 0x1,
        equals(1),
        reason: 'non-bit-4 write leaves DMA_DONE',
      );

      // Writing a 1 to bit 4 clears DMA_DONE.
      await tb.write(0x08, 0x10);
      status = await tb.read(0x08);
      expect((status >> 4) & 0x1, equals(0), reason: 'DMA_DONE cleared by W1C');

      await Simulator.endSimulation();
    });

    test('DMA read packs a full 64-bit beat (RV64 fabric)', () async {
      // On the real delta SoC the fabric is 64-bit, so the engine must pack 8
      // bytes per aligned beat (sel all-ones). 16 bytes = two 64-bit words.
      final spi = HarborSpiController(
        baseAddress: 0x5000,
        busDataWidth: 64,
        dma: true,
      );
      spi.port('spi_miso').getsLogic(Const(1));

      final tb = _DmaSpiBench(spi);
      await tb.init();

      await tb.write(0x00, 0x01); // CTRL: enable
      await tb.write(0x18, 1); // DIVIDER: fast
      await tb.write(0x28, 0x200); // DMA_ADDR
      await tb.write(0x30, 16); // DMA_LEN: 16 bytes
      await tb.write(0x38, 0x01); // DMA_CTRL: START, DIR=0

      await tb.waitCycles(1600);

      expect(tb.slaveOut('o_count'), equals(2), reason: '16B = two 64b beats');
      expect(tb.slaveOut('o_last_addr'), equals(0x208));
      expect(tb.slaveOut('o_last_data'), equals(-1 & 0xFFFFFFFFFFFFFFFF));
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
