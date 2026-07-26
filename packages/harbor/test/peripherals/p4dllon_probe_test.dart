// Period-4 launch probe (instrument-free split for the HW write bug).
// On the OrangeCrab at 96/72MHz the write LANDS the correct data on only 2 of 4
// consecutive writes (deterministic period-4). This test drives 8 consecutive
// SAME-address writes through the real async/trained/write-leveled controller and
// dumps the PHY write-LAUNCH signals (wr_chunkbeat_*, wr_oe_win, wr_chunk). In
// ROHD sim the ODDR OUTPUTS are X, but these INPUTS are defined fabric.
//   - If the launch signals repeat IDENTICALLY per write => the period-4 is in
//     the ECP5 ODDR gearbox PRIMITIVE / silicon (needs the logic analyzer).
//   - If they VARY with period 4 => a free-running counter in the RTL launch
//     logic (fixable now, no instrument).
import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'period-4 launch probe: dump PHY launch signals over 8 writes',
    () async {
      final clk = SimpleClockGenerator(4).clk; // bus clk = 2x sclk
      final ddrClk = SimpleClockGenerator(2).clk; // CK source = 2x sclk
      final reset = Logic(name: 'reset');
      final ddrReset = Logic(name: 'ddr_reset');

      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        busAddressWidth: 32,
        busDataWidth: 32,
        clockHz: 72000000,
        asyncClock: true,
        trainableRead: true,
        writeLevel: true,
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
      WaveDumper(ddr, outputPath: '/tmp/p4dllon.vcd');

      Logic ack() => ddr.output('bus_ACK');
      for (final s in [cyc, stb, we, adr, datMosi, sel]) {
        s.inject(0);
      }
      reset.inject(1);
      ddrReset.inject(1);
      Simulator.setMaxSimTime(40000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      ddrReset.inject(0);
      await clk.nextPosedge;

      Future<void> wr(int address, int data) async {
        cyc.inject(1);
        stb.inject(1);
        we.inject(1);
        adr.inject(address);
        datMosi.inject(data);
        var guard = 0;
        while (!ack().value.isValid || !ack().value.toBool()) {
          await clk.nextPosedge;
          if (++guard > 400000) {
            fail('write ack timeout');
          }
        }
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
        for (var i = 0; i < 8; i++) {
          await clk.nextPosedge;
        }
      }

      // 8 consecutive writes of the SAME data to the SAME address. The launch
      // signals MUST be identical per write unless a free-running RTL counter
      // perturbs them. The VCD at /tmp/p4dllon.vcd carries wr_chunk/wr_oe_win/
      // wr_chunkbeat_* for offline period-4 inspection.
      for (var i = 0; i < 8; i++) {
        await wr(0x80000000, 0x2AAAAAAA);
      }

      await Simulator.endSimulation();
      expect(true, isTrue); // dump is the artifact
    },
  );
}
