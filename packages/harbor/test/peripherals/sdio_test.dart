import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register word indices (the bus presents a word index to the peripheral).
const _ctrl = 0;
const _clkDiv = 2;
const _cmd = 3;
const _cmdArg = 4;
const _resp0 = 5;
const _data = 9;
const _blkSize = 10;
const _intStatus = 12;
const _intEnable = 13;
const _admaAddr = 14;

/// Reference SD CRC7 (x^7 + x^3 + 1) over an MSB-first bit list, mirroring the
/// hardware. Returns 7 bits, MSB-first.
List<int> _crc7(List<int> bits) {
  var c = List<int>.filled(7, 0);
  for (final b in bits) {
    final inv = b ^ c[6];
    c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
  }
  return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]];
}

/// Reference SD data CRC16 (CCITT) over an MSB-first bit list. Returns 16 bits,
/// MSB-first.
List<int> _crc16(List<int> bits) {
  var c = List<int>.filled(16, 0);
  for (final b in bits) {
    final inv = b ^ c[15];
    c = [
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          c[4] ^ inv
        else if (i == 12)
          c[11] ^ inv
        else
          c[i - 1],
    ];
  }
  return [for (var i = 15; i >= 0; i--) c[i]];
}

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

/// A 48-bit short response frame carrying [payload] (CRC is don't-care here:
/// the controller does not verify the command-response CRC).
List<int> _resp48(int payload) => [
  0,
  0,
  ..._bitsMsb(0, 6),
  ..._bitsMsb(payload, 32),
  ..._bitsMsb(0, 7),
  1,
];

/// The 4 bytes of a 32-bit word in transmit order (byte 0, the low lane,
/// first), each MSB-first: the SD data-line bit order.
List<int> _wordBitsMsb(int word) => [
  for (var byte = 0; byte < 4; byte++)
    ..._bitsMsb((word >> (byte * 8)) & 0xFF, 8),
];

/// The 4-bit-wide DAT line groups for one 32-bit word: a start group (0), then
/// 8 data nibbles (byte 0 first, high nibble first, DAT3 = bit 7), then 16
/// per-lane CRC16 groups. Each value is the 4-bit vector on DAT[3:0].
List<int> _fourBitStream(int word) {
  final bytes = [for (var i = 0; i < 4; i++) (word >> (i * 8)) & 0xFF];
  final data = <int>[];
  for (final b in bytes) {
    data.add((b >> 4) & 0xF);
    data.add(b & 0xF);
  }
  final laneCrc = [
    for (var l = 0; l < 4; l++) _crc16([for (final g in data) (g >> l) & 1]),
  ];
  final crc = [
    for (var t = 0; t < 16; t++)
      [for (var l = 0; l < 4; l++) laneCrc[l][t] << l].reduce((a, b) => a | b),
  ];
  return [0, ...data, ...crc];
}

void main() {
  group('HarborSdioConfig', () {
    test('SD preset', () {
      const config = HarborSdioConfig.sd();
      expect(config.maxBusWidth, equals(HarborSdioBusWidth.four));
      expect(config.maxSpeed, equals(HarborSdioSpeed.highSpeed));
      expect(config.supportsIo, isFalse);
      expect(config.maxIoFunctions, equals(0));
    });

    test('WiFi preset', () {
      const config = HarborSdioConfig.wifi();
      expect(config.supportsIo, isTrue);
      expect(config.maxIoFunctions, equals(2));
    });

    test('UHS preset', () {
      const config = HarborSdioConfig.uhs();
      expect(config.maxSpeed, equals(HarborSdioSpeed.sdr104));
      expect(config.supports1v8, isTrue);
      expect(config.maxIoFunctions, equals(7));
    });

    test('eMMC preset', () {
      const config = HarborSdioConfig.emmc();
      expect(config.maxBusWidth, equals(HarborSdioBusWidth.eight));
      expect(config.supportsEmmc, isTrue);
      expect(config.maxIoFunctions, equals(0));
    });

    test('toPrettyString', () {
      const config = HarborSdioConfig.wifi();
      final pretty = config.toPrettyString();
      expect(pretty, contains('4-bit'));
      expect(pretty, contains('SDIO I/O'));
    });
  });

  group('HarborSdioController', () {
    test('creates with SD config', () {
      final sdio = HarborSdioController(baseAddress: 0x60000000);
      expect(sdio.bus, isNotNull);
      expect(sdio.interrupt.width, equals(1));
    });

    test('DT compatible for SD vs eMMC', () {
      final sd = HarborSdioController(baseAddress: 0x60000000);
      expect(sd.dtNode.compatible.first, equals('harbor,sdhci'));

      final emmc = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.emmc(),
      );
      expect(emmc.dtNode.compatible.first, equals('harbor,sdhci-emmc'));
    });

    test('bus width in DT', () {
      final sd = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig(maxBusWidth: HarborSdioBusWidth.eight),
      );
      expect(sd.dtNode.properties['bus-width'], equals(8));
    });
  });

  group('HarborSdioController CMD engine', () {
    late HarborSdioController sdio;
    late Logic clk, reset, stb, we, adr, mosi;
    late Logic cmdIn, cmdOut, cmdOe, sdClk, irq;
    late Logic datIn, datOut, datOe;
    late List<Logic> mem; // ADMA bus-master memory model (16 words)

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (sdio.output('bus_ACK').value.toInt() != 1) {
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
      while (sdio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = sdio.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({List<int> dmaMem = const []}) async {
      sdio = HarborSdioController(baseAddress: 0x60000000);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: 32);
      cmdIn = Logic(name: 'cmd_in');
      datIn = Logic(name: 'dat_in', width: 4);

      sdio.input('clk').srcConnection! <= clk;
      sdio.input('reset').srcConnection! <= reset;
      sdio.input('bus_CYC').srcConnection! <= stb;
      sdio.input('bus_STB').srcConnection! <= stb;
      sdio.input('bus_WE').srcConnection! <= we;
      sdio.input('bus_ADR').srcConnection! <= adr;
      sdio.input('bus_DAT_MOSI').srcConnection! <= mosi;
      sdio.input('bus_SEL').srcConnection! <=
          Const(0xF, width: sdio.input('bus_SEL').width);
      sdio.input('sd_cmd_in').srcConnection! <= cmdIn;
      sdio.input('sd_cd').srcConnection! <= Const(0);
      sdio.input('sd_dat_in').srcConnection! <= datIn;

      // A 16-word memory model on the ADMA master port. Reads/acks combinationally
      // (ack = stb, single-cycle), writes on the clock. Preloaded with [dmaMem].
      final initVals = [
        for (var i = 0; i < 16; i++) i < dmaMem.length ? dmaMem[i] : 0,
      ];
      mem = [for (var i = 0; i < 16; i++) Logic(name: 'mem$i', width: 32)];
      final mStb = sdio.output('dma_stb');
      final mWe = sdio.output('dma_we');
      final mAddr = sdio.output('dma_addr');
      final mWdata = sdio.output('dma_wdata');
      final mIdx = mAddr.getRange(2, 6); // word index 0..15
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
      sdio.input('dma_rdata').srcConnection! <= mRd;
      sdio.input('dma_ack').srcConnection! <= mStb;

      await sdio.build();

      cmdOut = sdio.output('sd_cmd_out');
      cmdOe = sdio.output('sd_cmd_oe');
      sdClk = sdio.output('sd_clk');
      irq = sdio.output('interrupt');
      datOut = sdio.output('sd_dat_out');
      datOe = sdio.output('sd_dat_oe');

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      cmdIn.inject(1); // CMD line idles high
      datIn.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Enable, fastest clock (toggle every cycle), unmask cmd-done + timeout.
      await busWrite(_clkDiv, 0);
      await busWrite(_intEnable, 0x11);
      await busWrite(_ctrl, 0x1);
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('serializes a command frame with a correct CRC7', () async {
      await setUpDut();

      const index = 17; // READ_SINGLE_BLOCK
      const arg = 0xDEADBEEF;
      await busWrite(_cmdArg, arg);
      await busWrite(_cmd, index); // resp type 0 (none)

      // Sample the CMD line at each SD rising edge: the host drives a bit on the
      // falling edge, the card samples it on the next rising edge.
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1) captured.add(cmdOut.value.toInt());
        prevClk = c;
      }

      // Expected 48-bit frame: start, tx, index, arg, CRC7, end.
      final content = [0, 1, ..._bitsMsb(index, 6), ..._bitsMsb(arg, 32)];
      final expected = [...content, ..._crc7(content), 1];

      // Drop the idle ones held before the start bit, take the 48-bit frame.
      final start = captured.indexOf(0);
      expect(start, greaterThanOrEqualTo(0));
      expect(captured.length, greaterThanOrEqualTo(start + 48));
      expect(captured.sublist(start, start + 48), equals(expected));

      expect(await busRead(_intStatus) & 0x01, equals(0x01)); // cmd-done
      await Simulator.endSimulation();
    });

    test('captures a short response into RESP0', () async {
      await setUpDut();

      const payload = 0x12345678;
      // 48-bit response: start(0), tx(0), index echo(6), payload(32), crc7(7),
      // end(1). RESP0 should be the 32-bit payload.
      final frame = [
        0,
        0,
        ..._bitsMsb(17, 6),
        ..._bitsMsb(payload, 32),
        ..._bitsMsb(0, 7),
        1,
      ];

      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6)); // resp type 1 (short)

      // After the host releases the line, present one response bit per SD
      // period: inject on the falling-edge posedge (sd_clk just went low) so it
      // is stable for the card-sample rising edge that follows.
      var sawDrive = false;
      var k = 0;
      for (var i = 0; i < 1200; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive &&
            !sending &&
            sdClk.value.toInt() == 0 &&
            k < frame.length) {
          cmdIn.inject(frame[k]);
          k++;
        }
        if (irq.value.toInt() == 1) break;
      }

      expect(k, equals(frame.length)); // all response bits consumed
      expect(await busRead(_intStatus) & 0x01, equals(0x01)); // cmd-done
      expect(await busRead(_resp0), equals(payload));
      await Simulator.endSimulation();
    });

    test('reports a timeout when the card never responds', () async {
      await setUpDut();

      await busWrite(_cmdArg, 0);
      cmdIn.inject(1); // line stays idle high: no start bit ever
      await busWrite(_cmd, 55 | (1 << 6)); // resp type 1 (short)

      var done = false;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        if (irq.value.toInt() == 1) {
          done = true;
          break;
        }
      }
      expect(done, isTrue);
      expect(await busRead(_intStatus) & 0x10, equals(0x10)); // timeout bit
      await Simulator.endSimulation();
    });

    test('reads a block into the data register with a good CRC16', () async {
      await setUpDut();

      const word = 0xA5A5F00F;
      await busWrite(_blkSize, 4); // 4-byte block = one word
      await busWrite(_intEnable, 0x12); // irq on data-done / timeout only
      await busWrite(_cmdArg, 0);
      // index 17, short response, data present, read direction.
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

      // Drive the command response, then the data block on DAT0. Both feed one
      // bit per SD period on the falling-edge posedge ahead of each sample.
      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final datStream = [0, ...dataBits, ..._crc16(dataBits)]; // start+data+crc
      final total = resp.length + datStream.length;

      var sawDrive = false;
      var idx = 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive && !sending && sdClk.value.toInt() == 0 && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        if (irq.value.toInt() == 1) break; // data-done
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error
      expect(await busRead(_data), equals(word));
      await Simulator.endSimulation();
    });

    test('writes a block out of DAT0 with a correct CRC16', () async {
      await setUpDut();

      const word = 0x11223344;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_data, word); // fill the holding register
      await busWrite(_cmdArg, 0);
      // index 24, short response, data present, write direction (bit 9 = 0).
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8));
      datIn.inject(1); // DAT0 idles high until the card drives the status token

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      // start + 32 data + 16 CRC (the end bit is driven with OE already low).
      final expected = [0, ...dataBits, ..._crc16(dataBits)];
      // Card CRC status token (010 = accepted), then busy-low then busy-high.
      const statusBusy = [0, 0, 1, 0, 0, 1];

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 1);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break; // data-done (after busy)
      }

      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(si, equals(statusBusy.length)); // token + busy consumed
      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x20, equals(0)); // no write error (status accepted)
      await Simulator.endSimulation();
    });

    test('reads a 4-bit-wide block with per-lane CRC16', () async {
      await setUpDut();

      const word = 0xC3A5F00F;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_ctrl, 0x01 | (1 << 4)); // enable + 4-bit width
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9));

      final resp = _resp48(0);
      final stream = _fourBitStream(word);
      final total = resp.length + stream.length;

      var sawDrive = false;
      var idx = 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive && !sending && sdClk.value.toInt() == 0 && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(stream[idx - resp.length]);
          }
          idx++;
        }
        if (irq.value.toInt() == 1) break;
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error on any lane
      expect(await busRead(_data), equals(word));
      await Simulator.endSimulation();
    });

    test('writes a 4-bit-wide block with a correct per-lane CRC16', () async {
      await setUpDut();

      const word = 0x0FF0A55A;
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_ctrl, 0x01 | (1 << 4)); // enable + 4-bit width
      await busWrite(_data, word);
      await busWrite(_cmdArg, 0);
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8)); // write
      datIn.inject(1); // DAT0 idles high until the status token

      final resp = _resp48(0);
      final expected = _fourBitStream(word); // start + data + CRC, end excluded
      const statusBusy = [0, 0, 1, 0, 0, 1]; // status token on DAT0, then busy

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 0xF);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break;
      }

      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(si, equals(statusBusy.length));
      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      await Simulator.endSimulation();
    });

    test('reads a block into memory via ADMA DMA', () async {
      const word = 0xCAFEF00D;
      // Descriptor table at word 0: [addr=0x20, len=4 bytes | end], the data
      // buffer is word 8 (byte 0x20).
      await setUpDut(dmaMem: [0x20, 0x80000004]);
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0); // descriptor table base
      await busWrite(_cmdArg, 0);
      // short resp, data present, read direction, DMA.
      await busWrite(_cmd, 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final datStream = [0, ...dataBits, ..._crc16(dataBits)];
      final total = resp.length + datStream.length;

      var sawDrive = false, idx = 0;
      for (var i = 0; i < 6000; i++) {
        await clk.nextPosedge;
        final sending = cmdOe.value.toInt() == 1;
        if (sending) sawDrive = true;
        if (sawDrive && !sending && sdClk.value.toInt() == 0 && idx < total) {
          if (idx < resp.length) {
            cmdIn.inject(resp[idx]);
          } else {
            datIn.inject(datStream[idx - resp.length]);
          }
          idx++;
        }
        if (irq.value.toInt() == 1) break;
      }

      final status = await busRead(_intStatus);
      expect(status & 0x02, equals(0x02)); // data-done
      expect(status & 0x08, equals(0)); // no CRC error
      // The engine stored the received word to the descriptor's buffer.
      expect(mem[8].value.toInt(), equals(word));
      await Simulator.endSimulation();
    });

    test('writes a block from memory via ADMA DMA', () async {
      const word = 0x12345678;
      // Data word preloaded at word 8 (byte 0x20), descriptor points at it.
      await setUpDut(dmaMem: [0x20, 0x80000004, 0, 0, 0, 0, 0, 0, word]);
      await busWrite(_blkSize, 4);
      await busWrite(_intEnable, 0x12);
      await busWrite(_admaAddr, 0);
      await busWrite(_cmdArg, 0);
      // short resp, data present, write direction, DMA.
      await busWrite(_cmd, 24 | (1 << 6) | (1 << 8) | (1 << 10));
      datIn.inject(1); // DAT0 idles high for the status token

      final resp = _resp48(0);
      final dataBits = _wordBitsMsb(word);
      final expected = [0, ...dataBits, ..._crc16(dataBits)];
      const statusBusy = [0, 0, 1, 0, 0, 1];

      var sawCmd = false, sawDat = false, ri = 0, si = 0;
      final captured = <int>[];
      var prevClk = sdClk.value.toInt();
      for (var i = 0; i < 8000; i++) {
        await clk.nextPosedge;
        final cmdSending = cmdOe.value.toInt() == 1;
        if (cmdSending) sawCmd = true;
        final datDriving = datOe.value.toInt() == 1;
        if (datDriving) sawDat = true;
        if (sawCmd &&
            !cmdSending &&
            !sawDat &&
            sdClk.value.toInt() == 0 &&
            ri < resp.length) {
          cmdIn.inject(resp[ri]);
          ri++;
        }
        final c = sdClk.value.toInt();
        if (prevClk == 0 && c == 1 && datDriving) {
          captured.add(datOut.value.toInt() & 1);
        }
        prevClk = c;
        if (sawDat &&
            !datDriving &&
            sdClk.value.toInt() == 0 &&
            si < statusBusy.length) {
          datIn.inject(statusBusy[si]);
          si++;
        }
        if (irq.value.toInt() == 1) break;
      }

      // The serialized stream came straight from memory via ADMA.
      expect(captured.length, greaterThanOrEqualTo(expected.length));
      expect(captured.sublist(0, expected.length), equals(expected));
      expect(await busRead(_intStatus) & 0x02, equals(0x02)); // data-done
      await Simulator.endSimulation();
    });
  });

  group('HarborSdioController UHS structural layer', () {
    tearDown(() async {
      await Simulator.reset();
    });

    const spartan7 = HarborFpgaTarget.spartan7(
      device: 's50',
      package: 'csga324',
    );
    const ecp5 = HarborFpgaTarget.ecp5(device: '85f', package: 'CABGA381');
    const hs400 = HarborSdioConfig(
      maxBusWidth: HarborSdioBusWidth.eight,
      maxSpeed: HarborSdioSpeed.hs400,
      supportsEmmc: true,
      supports1v8: true,
      maxFrequency: 200000000,
    );

    test('Spartan 7 UHS config conditions inputs with IDELAYE2', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.uhs(), // SDR104
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('IDELAYE2')); // input-delay tuning tap
      expect(sv, isNot(contains('DELAYG'))); // no Lattice primitive
      expect(sv, isNot(contains('IDDR'))); // SDR104 is not DDR
    });

    test('ECP5 UHS config conditions inputs with DELAYG', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.uhs(),
        target: ecp5,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('DELAYG'));
      expect(sv, isNot(contains('IDELAYE2')));
    });

    test('HS400 (DDR) adds DDR input gearing', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: hs400,
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, contains('IDELAYE2'));
      expect(sv, contains('IDDR')); // DDR capture gearing
    });

    test('non-UHS config leaves the SDR datapath untouched', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x60000000,
        config: const HarborSdioConfig.sd(), // high speed, not UHS
        target: spartan7,
      );
      await sdio.build();
      final sv = sdio.generateSynth();
      expect(sv, isNot(contains('IDELAYE2')));
      expect(sv, isNot(contains('IDDR')));
    });
  });
}
