import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Repro for the dramexec copy-hang: many BACK-TO-BACK writes to DRAM through
/// the async CDC bridge. The async roundtrip test only does spaced single
/// transactions, dramexec's stub copy (and Weir's bss memset) is a sustained
/// stream, and it HANGS on hardware (DEXEC then no COPIED). This drives N
/// back-to-back writes and asserts each ACKs. If a write stalls, the guard
/// fails and the VCD at /tmp/sustained.vcd shows the stuck CDC/sequencer state.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    'sustained back-to-back writes all ACK (repro dramexec copy hang)',
    () async {
      final clk = SimpleClockGenerator(4).clk; // bus clk = ddr_clk/2
      final ddrClk = SimpleClockGenerator(2).clk;
      final reset = Logic(name: 'reset');
      final ddrReset = Logic(name: 'ddr_reset');

      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        busAddressWidth: 32,
        busDataWidth: 64, // creek RV64
        clockHz: 1000000,
        asyncClock: true,
        trainableRead: false,
        writeLevel: false,
        target: const HarborFpgaTarget.ecp5(
          device: '25f',
          package: 'CSFBGA285',
        ),
      );

      final cyc = Logic(name: 'cyc');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: ddr.input('bus_ADR').width);
      final datMosi = Logic(
        name: 'datMosi',
        width: ddr.input('bus_DAT_MOSI').width,
      );
      final sel = Logic(name: 'sel', width: ddr.input('bus_SEL').width);

      ddr.input('clk').srcConnection! <= clk;
      ddr.input('reset').srcConnection! <= reset;
      ddr.input('ddr_clk').srcConnection! <= ddrClk;
      ddr.input('ddr_reset').srcConnection! <= ddrReset;
      ddr.input('bus_CYC').srcConnection! <= cyc;
      ddr.input('bus_STB').srcConnection! <= stb;
      ddr.input('bus_WE').srcConnection! <= we;
      ddr.input('bus_ADR').srcConnection! <= adr;
      ddr.input('bus_DAT_MOSI').srcConnection! <= datMosi;
      ddr.input('bus_SEL').srcConnection! <= sel;

      await ddr.build();
      WaveDumper(ddr, outputPath: '/tmp/sustained.vcd');

      Logic ack() => ddr.output('bus_ACK');
      for (final s in [cyc, stb, we, adr, datMosi, sel]) {
        s.inject(0);
      }
      reset.inject(1);
      ddrReset.inject(1);
      Simulator.setMaxSimTime(300000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 6; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      ddrReset.inject(0);
      await clk.nextPosedge;

      // A tight Wishbone-classic write: hold the request until ACK, then drop for
      // ONE cycle (the minimum the core does between stores) and immediately
      // issue the next: the sustained back-to-back pattern.
      Future<void> write(int address, int data, int n) async {
        cyc.inject(1);
        stb.inject(1);
        we.inject(1);
        adr.inject(address);
        datMosi.inject(data);
        sel.inject(0xFF);
        var guard = 0;
        while (!ack().value.isValid || !ack().value.toBool()) {
          await clk.nextPosedge;
          if (++guard > 5000) {
            fail(
              'write #$n to 0x${address.toRadixString(16)} HUNG (no ack in '
              '5000 cycles) - the sustained-write stall reproduced. VCD: '
              '/tmp/sustained.vcd',
            );
          }
        }
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge; // one idle cycle, then next write
      }

      // 24 back-to-back sequential writes (mirrors the dramexec stub copy).
      for (var i = 0; i < 200; i++) {
        await write(0x80000000 + i * 8, 0x40DE0000 + i, i);
        print("OK $i");
      }

      await Simulator.endSimulation();
      expect(true, isTrue);
    },
  );
}
