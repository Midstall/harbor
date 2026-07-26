import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// DECISIVE experiment for the creek streaming-write DROP (isolated by the
/// RiverDdrVerify probe + the layer-by-layer sim tests): does the DDR
/// SEQUENCER actually ISSUE a WRITE command for every accepted bus write when
/// the bus holds CYC continuously high (the streaming pattern), or does it ACK
/// the wishbone write without issuing it (a drop)?
///
/// Single/paced writes land perfectly on HW. A 1024-word back-to-back stream
/// reads back ~all wrong and a post-bulk read returns the STALE value, so the
/// stream writes never reached the array yet all ACK'd (no hang). Every layer
/// ABOVE the sequencer (dcache, CDC, downsizer incl. sub-word) has a passing
/// sim streaming-data test. The one remaining ambiguity: an accept bug under
/// continuous CYC vs the PHY DQ burst (unmodelable in sim).
///
/// The sequencer's wrCmdCount (reg5[15:8], base+size+0x28) counts DATA WRITE
/// commands since reset. Every accepted bus write must produce >= 1 command, so
/// wrCmdCount >= acked. If a continuous-CYC stream ACKs writes it never issues,
/// wrCmdCount < acked => the accept-drop is proven in sim (fixable). If
/// wrCmdCount >= acked for BOTH paced and continuous, the sequencer issues every
/// write and the drop is purely the PHY burst (hardware-only).
void main() {
  tearDown(() async => Simulator.reset());

  const base = 0x80000000;
  const size = 128 * 1024 * 1024; // orangeCrab config.size
  const reg5 = base + size + 0x28; // WRCTL: [15:8] = wrCmdCount

  // Build the creek-shaped controller: async DDR clock + runtime read training +
  // wide (RV64) bus so each 64b store splits through the downsizer, the real
  // path. ECP5 target so the write engine + sequencer actually SIMULATE (the
  // Xilinx ddr3Fast path is black-box primitives that only netlist).
  Future<
    ({
      HarborDdrController ddr,
      Logic clk,
      Logic cyc,
      Logic stb,
      Logic we,
      Logic adr,
      Logic dat,
      Logic sel,
    })
  >
  build() async {
    final clk = SimpleClockGenerator(4).clk;
    final ddrClk = SimpleClockGenerator(2).clk;
    final reset = Logic(name: 'reset');
    final ddrReset = Logic(name: 'ddr_reset');
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: base,
      busAddressWidth: 32,
      busDataWidth: 64,
      clockHz: 1000000,
      asyncClock: true,
      trainableRead: true,
      target: const HarborFpgaTarget.ecp5(device: '25f', package: 'CSFBGA285'),
    );
    final cyc = Logic(name: 'cyc');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final adr = Logic(name: 'adr', width: ddr.input('bus_ADR').width);
    final dat = Logic(name: 'dat', width: ddr.input('bus_DAT_MOSI').width);
    final sel = Logic(name: 'sel', width: ddr.input('bus_SEL').width);
    ddr.input('clk').srcConnection! <= clk;
    ddr.input('reset').srcConnection! <= reset;
    ddr.input('ddr_clk').srcConnection! <= ddrClk;
    ddr.input('ddr_reset').srcConnection! <= ddrReset;
    ddr.input('bus_CYC').srcConnection! <= cyc;
    ddr.input('bus_STB').srcConnection! <= stb;
    ddr.input('bus_WE').srcConnection! <= we;
    ddr.input('bus_ADR').srcConnection! <= adr;
    ddr.input('bus_DAT_MOSI').srcConnection! <= dat;
    ddr.input('bus_SEL').srcConnection! <= sel;
    await ddr.build();
    for (final s in [cyc, stb, we, adr, dat, sel]) {
      s.inject(0);
    }
    reset.inject(1);
    ddrReset.inject(1);
    Simulator.setMaxSimTime(80000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 6; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    ddrReset.inject(0);
    await clk.nextPosedge;
    return (
      ddr: ddr,
      clk: clk,
      cyc: cyc,
      stb: stb,
      we: we,
      adr: adr,
      dat: dat,
      sel: sel,
    );
  }

  /// Stream [n] sub-word (32-bit, alternating low/high half) DRAM writes. When
  /// [continuous] the bus never returns to idle between accepted writes (CYC
  /// held high, addr/data advanced the cycle after ACK: the streaming pattern).
  /// Otherwise an 8-cycle CDC drain separates each (the paced baseline). Returns
  /// how many writes ACK'd.
  Future<int> stream(
    dynamic h, {
    required bool continuous,
    required int n,
  }) async {
    final clk = h.clk as Logic;
    final cyc = h.cyc as Logic;
    final stb = h.stb as Logic;
    final we = h.we as Logic;
    final adr = h.adr as Logic;
    final dat = h.dat as Logic;
    final sel = h.sel as Logic;
    final ack = h.ddr.output('bus_ACK') as Logic;
    var acked = 0;
    for (var t = 0; t < n; t++) {
      final low = (t & 1) == 0;
      // 8-byte-aligned line address. Lane picked by sel (what the dcache does
      // for a 32-bit sw). Distinct data per word.
      final word = 0x0BAD0000 + t;
      cyc.inject(1);
      stb.inject(1);
      we.inject(1);
      adr.inject(base + (t ~/ 2) * 8);
      dat.inject(low ? word : (word << 32));
      sel.inject(low ? 0x0F : 0xF0);
      var guard = 0;
      while (!ack.value.isValid || !ack.value.toBool()) {
        await clk.nextPosedge;
        if (++guard > 200000) {
          fail('write #$t HUNG (no ack) - a stall, not a silent drop');
        }
      }
      acked++;
      if (continuous) {
        // Keep CYC asserted. Just advance to the next word next cycle.
        await clk.nextPosedge;
      } else {
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        for (var i = 0; i < 8; i++) {
          await clk.nextPosedge;
        }
      }
    }
    cyc.inject(0);
    stb.inject(0);
    we.inject(0);
    for (var i = 0; i < 12; i++) {
      await clk.nextPosedge;
    }
    return acked;
  }

  Future<int> readCmdCount(dynamic h) async {
    final clk = h.clk as Logic;
    final cyc = h.cyc as Logic;
    final stb = h.stb as Logic;
    final we = h.we as Logic;
    final adr = h.adr as Logic;
    final ack = h.ddr.output('bus_ACK') as Logic;
    final miso = h.ddr.output('bus_DAT_MISO') as Logic;
    cyc.inject(1);
    stb.inject(1);
    we.inject(0);
    adr.inject(reg5);
    var guard = 0;
    while (!ack.value.isValid || !ack.value.toBool()) {
      await clk.nextPosedge;
      if (++guard > 200000) fail('reg5 control read timed out');
    }
    final v = miso.value.isValid ? miso.value.toInt() : 0;
    cyc.inject(0);
    stb.inject(0);
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    return (v >> 8) & 0xFF; // reg5[15:8] = wrCmdCount
  }

  test('PACED sub-word stream: sequencer issues a command per write', () async {
    final h = await build();
    const n = 20;
    final acked = await stream(h, continuous: false, n: n);
    final cmd = await readCmdCount(h);
    print('PACED: acked=$acked wrCmdCount=$cmd');
    expect(acked, n, reason: 'all paced writes must ack');
    expect(
      cmd,
      greaterThanOrEqualTo(n),
      reason: 'each accepted write must issue >= 1 WRITE command',
    );
    await Simulator.endSimulation();
  });

  test('CONTINUOUS sub-word stream: sequencer issues a command per write '
      '(the creek streaming pattern)', () async {
    final h = await build();
    const n = 20;
    final acked = await stream(h, continuous: true, n: n);
    final cmd = await readCmdCount(h);
    print('CONTINUOUS: acked=$acked wrCmdCount=$cmd');
    expect(acked, n, reason: 'all streamed writes must ack (no hang)');
    // THE DECISIVE ASSERTION: if the sequencer ACKs streamed writes without
    // issuing them, wrCmdCount < acked: the creek drop reproduced in sim.
    expect(
      cmd,
      greaterThanOrEqualTo(n),
      reason:
          'STREAMING DROP: only $cmd WRITE commands issued for $acked '
          'ACKed writes - the sequencer ACKs under continuous CYC without '
          'issuing the write',
    );
    await Simulator.endSimulation();
  });
}
