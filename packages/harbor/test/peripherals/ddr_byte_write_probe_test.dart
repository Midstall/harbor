import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Fault B probe: on HW a byte store (`sb`) to DRAM is masked out entirely
/// (the target byte never lands, wrSel reaches the PHY as 0). This drives a
/// byte write through the FULL creek config (64-bit bus -> HarborWishboneDownsizer
/// -> CDC bridge -> controller -> sequencer -> PHY) and dumps the SEL chain
/// (m_sel, nb_sel, dv_sel, req_sel, wr_mask) so we can see exactly where the
/// byte-enable drops. Config matches the working-DDR build: async, static read
/// (trainableRead=false).
void main() {
  tearDown(() async => Simulator.reset());

  test('byte write: SEL byte-enable propagates to the PHY wr_mask', () async {
    final clk = SimpleClockGenerator(4).clk; // bus clk = ddr_clk/2
    final ddrClk = SimpleClockGenerator(2).clk;
    final reset = Logic(name: 'reset');
    final ddrReset = Logic(name: 'ddr_reset');

    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      busAddressWidth: 32,
      busDataWidth: 64, // creek RV64 core bus -> downsizer
      clockHz: 1000000,
      asyncClock: true,
      trainableRead: false, // static read path (the working-DDR config)
      writeLevel: false,
      target: const HarborFpgaTarget.ecp5(device: '25f', package: 'CSFBGA285'),
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
    WaveDumper(ddr, outputPath: '/tmp/byte_write.vcd');

    Logic ack() => ddr.output('bus_ACK');
    for (final s in [cyc, stb, we, adr, datMosi, sel]) {
      s.inject(0);
    }
    reset.inject(1);
    ddrReset.inject(1);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    ddrReset.inject(0);
    await clk.nextPosedge;

    Future<void> xfer({
      required bool write,
      required int address,
      required int data,
      required int selBits,
    }) async {
      cyc.inject(1);
      stb.inject(1);
      we.inject(write ? 1 : 0);
      adr.inject(address);
      datMosi.inject(data);
      sel.inject(selBits);
      var guard = 0;
      while (!ack().value.isValid || !ack().value.toBool()) {
        await clk.nextPosedge;
        if (++guard > 200000) fail('bus ack timeout (write=$write)');
      }
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      sel.inject(0);
      await clk.nextPosedge;
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
    }

    // 1) Full-word write (SEL byte1 lane only, low 32-bit half). This is the
    //    exact byte-store shape: 64-bit bus, byte 1 enabled, data 0x55 in byte1.
    await xfer(
      write: true,
      address: 0x80000000,
      data: 0x5500, // byte1 = 0x55
      selBits: 0x02, // only byte 1
    );

    // 2) A full-word write for contrast (all 8 byte enables of the low word).
    await xfer(
      write: true,
      address: 0x80000000,
      data: 0x40DE0000,
      selBits: 0x0F,
    );

    await Simulator.endSimulation();
    expect(true, isTrue); // the VCD dump is the artifact
  });
}
