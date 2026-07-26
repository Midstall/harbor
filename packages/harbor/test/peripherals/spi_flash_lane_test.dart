import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Regression for the SILENT-bundle bug: on a 64-bit RV64 bus the SPI flash
/// controller only ever read a single 32-bit flash word into the LOW 32 bits of
/// the bus word and left the HIGH 32 bits ZERO. The RV64 core issues bus-word-
/// aligned reads and selects the addressed sub-word out of the returned bus
/// word, so any byte that lived in the high half (flash offset 4,12,.. on a
/// 64-bit bus) came back 0x00. On silicon the maskrom's word-by-word `lw` copy
/// of the firmware read every odd word as 0x00000000, the SRAM firmware became
/// [instr,0,instr,0..] and the core trapped on the first zero word -> dead
/// silent. (An earlier "lane-shift" fix keyed off addr[2:0], but the core drives
/// bus-word-aligned addresses, so addr[2:0] is 0 and the shift was a no-op.)
///
/// The real fix makes the flash controller behave like every other memory slave
/// (HarborSram): on a 64-bit bus it reads a WHOLE bus word: 8 sequential flash
/// bytes, and drives all 64 bits, little-endian (byte at the lowest flash
/// address -> bits[7:0]).
///
/// This test drives 8 known bytes for one aligned 0x03 read on a 64-bit bus and
/// asserts the full little-endian 64-bit word comes back, with the HIGH 32 bits
/// (flash offsets 4..7) populated, not zero.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    '64-bit bus: an aligned read returns all 8 flash bytes, high lane != 0',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final addr = Logic(name: 'addr', width: 32);
      final miso = Logic(name: 'miso');

      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
          readCommand: 0x03,
          addressBytes: 3,
          dummyCycles: 0,
        ),
        baseAddress: 0x20000000,
        busAddressWidth: 32,
        // The bug only manifests on a bus WIDER than the 32-bit flash word.
        busDataWidth: 64,
      );

      flash.input('clk').srcConnection! <= clk;
      flash.input('reset').srcConnection! <= reset;
      flash.input('bus_CYC').srcConnection! <= stb;
      flash.input('bus_STB').srcConnection! <= stb;
      flash.input('bus_WE').srcConnection! <= Const(0);
      flash.input('bus_ADR').srcConnection! <= addr;
      flash.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 64);
      flash.input('bus_SEL').srcConnection! <=
          Const(0xFF, width: flash.input('bus_SEL').width);
      flash.input('spi_miso').srcConnection! <= miso;
      flash.input('wr_req').srcConnection! <= Const(0);
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);

      await flash.build();

      final spiClk = flash.output('spi_clk');
      final csN = flash.output('spi_cs_n');
      final ack = flash.output('bus_ACK');
      final misoOut = flash.output('bus_DAT_MISO');

      reset.inject(1);
      stb.inject(0);
      addr.inject(0);
      miso.inject(0);
      Simulator.setMaxSimTime(8000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // 8 flash bytes at offset 0, in flash-address order (byte0 first). The CPU
      // little-endian 64-bit word is therefore 0xAABBCCDD11223344: byte0(0x44) ->
      // bits[7:0], byte7(0xAA) -> bits[63:56].
      final bytes = [0x44, 0x33, 0x22, 0x11, 0xDD, 0xCC, 0xBB, 0xAA];
      // 64 data bits, MSB-first across byte0..byte7.
      final dataBits = <int>[
        for (final b in bytes)
          for (var i = 7; i >= 0; i--) (b >> i) & 1,
      ];
      const dataStart = 8 + 24; // cmd + 24-bit address, all 1-bit

      addr.inject(0);
      stb.inject(1);

      var prevClk = 0;
      var riseCount = 0;
      var prevCs = 1;
      var got = false;
      var data = BigInt.zero;
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        final cs = csN.value.toInt();
        final sc = spiClk.value.toInt();
        if (cs == 1) {
          riseCount = 0;
        } else {
          if (prevCs == 1) riseCount = 0;
          if (sc == 1 && prevClk == 0) {
            final idx = riseCount - dataStart;
            miso.inject(idx >= 0 && idx < dataBits.length ? dataBits[idx] : 0);
            riseCount++;
          }
        }
        prevClk = sc;
        prevCs = cs;

        if (ack.value.isValid && ack.value.toBool()) {
          data = misoOut.value.toBigInt();
          got = true;
          break;
        }
      }
      stb.inject(0);

      expect(got, isTrue, reason: 'controller never asserted ack');

      final mask32 = (BigInt.one << 32) - BigInt.one;
      // Full 64-bit little-endian word.
      expect(
        data,
        equals(BigInt.parse('AABBCCDD11223344', radix: 16)),
        reason: 'full 64-bit read wrong: 0x${data.toRadixString(16)}',
      );
      // Low lane (flash 0..3) = 0x11223344.
      expect(
        data & mask32,
        equals(BigInt.from(0x11223344)),
        reason: 'low lane wrong: 0x${data.toRadixString(16)}',
      );
      // High lane (flash 4..7) = 0xAABBCCDD. This is the byte range the original
      // bug zeroed and the silent-bundle regression guard.
      expect(
        (data >> 32) & mask32,
        equals(BigInt.from(0xAABBCCDD)),
        reason:
            'high lane ZERO -> the silent-bundle regression: '
            '0x${data.toRadixString(16)}',
      );

      await Simulator.endSimulation();
    },
  );
}
