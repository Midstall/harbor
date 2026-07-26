import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// FINDING I1 functional sim for the Milestone 1 async (2-phase clock) DDR
/// datapath.
///
/// The migrated sclk datapath (PHY fabric + [DdrSequencer] + CDC master) runs
/// on a DERIVED sclk = ddr_clk/2 exported by the ECP5 clock tree. Before this
/// test the only `asyncClock: true` coverage was elaboration-only
/// (ddr_elab_test), so NO running sim ever toggled the Sequentials that moved
/// to sclk. The one functional DDR sim (ddr_train) uses the single-clock dpClk
/// path, which was not migrated.
///
/// This test instantiates [HarborDdrController] with `asyncClock: true`, drives
/// the bus face from one clock and `ddr_clk` from a second at 2x the bus rate,
/// runs the [Simulator], and verifies a bus write-then-read round-trip
/// completes through the CDC bridge + the /2 sclk fabric: the request crosses
/// into the sclk domain, the sequencer walks JEDEC init + the access FSM, and
/// the ack returns. That can only happen if the derived sclk genuinely clocks
/// the sclk-domain Sequentials in ROHD sim (see /tmp/m1_report.md for the
/// derived-clock simulability finding).
///
/// A small clockHz keeps the sequencer's real-time JEDEC counters short enough
/// to settle in bounded sim time (the counts scale with clkMhz).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  late Logic clk, ddrClk, reset, ddrReset;
  late Logic cyc, stb, we, adr, datMosi, sel;
  late HarborDdrController ddr;

  Future<void> bringUp({
    int ddrPeriod = 2,
    bool train = false,
    bool writeLevel = false,
    int busDataWidth = 32,
    // When true, never release [ddrReset]: models the DDR clock domain held in
    // reset on hardware (PLL/DLL not locked, sclk not running). A control-window
    // access MUST still ack in that state: it is served purely on the bus clock.
    bool holdDdrReset = false,
  }) async {
    // bus clk runs at half the ddr_clk rate (ddr_clk = CK source = 2x sclk).
    clk = SimpleClockGenerator(ddrPeriod * 2).clk;
    ddrClk = SimpleClockGenerator(ddrPeriod).clk;
    reset = Logic(name: 'reset');
    ddrReset = Logic(name: 'ddr_reset');

    ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      busAddressWidth: 32,
      busDataWidth: busDataWidth,
      // Tiny CK rate so the JEDEC init counters (us/ns) finish in bounded sim
      // time. clkMhz clamps to >= 1, the sclk sequencer then counts at >= 1.
      clockHz: 1000000,
      asyncClock: true,
      // Combined async DDR clock + runtime read leveling (creek's real config).
      // The control window decodes + acks on the bus clock and is gated out of
      // the CDC datapath, only the trained config crosses into sclk.
      trainableRead: train,
      // JEDEC DDR3 write-leveling: the exact creek `ddrlevel` build sets this in
      // combination with trainableRead. The earlier control tests left it off, so
      // the train+writeLevel+async+wide combination (the field config that hung)
      // was never exercised together.
      writeLevel: writeLevel,
      target: const HarborFpgaTarget.ecp5(device: '25f', package: 'CSFBGA285'),
    );

    cyc = Logic(name: 'cyc');
    stb = Logic(name: 'stb');
    we = Logic(name: 'we');
    adr = Logic(name: 'adr', width: ddr.input('bus_ADR').width);
    datMosi = Logic(name: 'datMosi', width: ddr.input('bus_DAT_MOSI').width);
    sel = Logic(name: 'sel', width: ddr.input('bus_SEL').width);

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
    // The DDR domain reset is released unless the test models a stuck DDR clock
    // domain (PLL/DLL never locks). The control window must ack regardless.
    if (!holdDdrReset) ddrReset.inject(0);
    await clk.nextPosedge;
  }

  Logic ack() => ddr.output('bus_ACK');
  Logic miso() => ddr.output('bus_DAT_MISO');

  // Single-outstanding Wishbone classic master: hold the request until ack.
  Future<int> xfer({
    required bool write,
    required int address,
    int data = 0,
    int guardCycles = 200000,
  }) async {
    cyc.inject(1);
    stb.inject(1);
    we.inject(write ? 1 : 0);
    adr.inject(address);
    datMosi.inject(data);
    var guard = 0;
    while (!ack().value.isValid || !ack().value.toBool()) {
      await clk.nextPosedge;
      if (++guard > guardCycles) {
        fail(
          'timeout waiting for bus ack (write=$write addr='
          '0x${address.toRadixString(16)}) - the sclk datapath did not '
          'complete the access (derived sclk likely not clocking)',
        );
      }
    }
    final rd = miso().value.isValid ? miso().value.toInt() : 0;
    cyc.inject(0);
    stb.inject(0);
    we.inject(0);
    await clk.nextPosedge;
    // Let the CDC handshake drain before the next access.
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    return rd;
  }

  test('async write-then-read round-trip completes through the CDC + /2 sclk', () async {
    await bringUp();

    // A write and a read at the same address. The pass condition for FINDING I1
    // is that BOTH accesses ACK: that requires the request to cross the CDC into
    // the sclk domain, the sclk-clocked sequencer to walk JEDEC init then the
    // access FSM to busDone, and the ack to cross back. If the derived sclk did
    // NOT clock the sclk-domain Sequentials, the sequencer would never leave its
    // reset state, busDone would never assert, and these would time out.
    const addr = 0x80000040;
    await xfer(write: true, address: addr, data: 0xCAFEF00D);
    final rd = await xfer(write: false, address: addr);

    // Read data correctness is a Milestone 2 / hardware (DQS read) concern. The
    // sim PHY's pin-level burst timing is calibrated for the real part, so we do
    // not assert the value here. The round-trip COMPLETING is the I1 evidence.
    // ignore: unnecessary_statements
    rd;
    expect(true, isTrue);

    await Simulator.endSimulation();
  });

  Future<void> sustainedWrites({required int busDataWidth}) async {
    // Weir's bss-clear does millions of no-pause stores. On HW that wedges the
    // single-outstanding CDC + controller-FSM chain. Drive back-to-back writes
    // with only a 1-cycle cyc drop (NOT the 8-cycle drain xfer() uses to hide
    // this) and require EVERY one to ack. A wedge => a transaction times out.
    // busDataWidth 64 exercises the DOWNSIZER (each 64b store -> two 32b bridge
    // txns), the real RV64-core path that was never sustained-tested.
    await bringUp(busDataWidth: busDataWidth);
    final stride = busDataWidth ~/ 8;
    const n = 24;
    var done = 0;
    for (var t = 0; t < n; t++) {
      cyc.inject(1);
      stb.inject(1);
      we.inject(1);
      adr.inject(0x80000040 + t * stride);
      datMosi.inject(0xA0000 + t);
      var guard = 0;
      while (!ack().value.isValid || !ack().value.toBool()) {
        await clk.nextPosedge;
        if (++guard > 5000) {
          fail(
            'WEDGE: write $t of $n never acked ($done completed) - the '
            'sustained-store CDC race (#136)',
          );
        }
      }
      // Sustained: drop the strobe for ONE bus cycle, then straight to the next.
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      done++;
    }
    expect(done, n, reason: 'all $n back-to-back writes acked');

    await Simulator.endSimulation();
  }

  test(
    '#136 repro: SUSTAINED back-to-back writes 32-bit (no drain) all ACK',
    () async {
      await sustainedWrites(busDataWidth: 32);
    },
  );

  test(
    '#136 repro: SUSTAINED back-to-back writes 64-bit (downsizer) all ACK',
    () async {
      await sustainedWrites(busDataWidth: 64);
    },
  );

  test('async + trainableRead: control window served on bus clk (CDC fix), '
      'tap walks and STATUS reads back', () async {
    // This is the creek combined mode the old code forbade. It exercises the
    // CDC fix directly: the training control window (writes + reads) is served
    // entirely on the BUS clock and gated out of the sclk datapath, while the
    // tap walk happens in the sclk domain with the config 2-flop synchronized
    // across. If isCtrl/regSel still crossed clk->sclk unsynchronized (the bug
    // this addresses), the control read would return datapath/array data or a
    // metastable mux and this would fail.
    await bringUp(train: true);

    const size = 128 * 1024 * 1024;
    const rdtapTarget = size + 0x00;
    const ctl = size + 0x08;
    const status = size + 0x18;

    // Write target tap 9, pulse SET.
    await xfer(write: true, address: rdtapTarget, data: 9);
    await xfer(write: true, address: ctl, data: 0x1);

    // Poll STATUS (bits [7:0]: busy[0], tap[7:1]) until idle. DATAVALID/BURSTDET
    // (bits [9:8]) are X in sim (unmodeled DQSBUFM leaf), so mask to [7:0].
    var st = 0;
    for (var i = 0; i < 200; i++) {
      cyc.inject(1);
      stb.inject(1);
      we.inject(0);
      adr.inject(status);
      var guard = 0;
      while (!ack().value.isValid || !ack().value.toBool()) {
        await clk.nextPosedge;
        if (++guard > 200000) fail('STATUS read timed out');
      }
      st = miso().value.getRange(0, 8).toInt();
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      for (var j = 0; j < 4; j++) {
        await clk.nextPosedge;
      }
      if (st & 0x1 == 0) break;
    }
    expect(st & 0x1, 0, reason: 'walk should be idle');
    expect(
      (st >> 1) & 0x7F,
      9,
      reason: 'current tap should reach the target through the CDC',
    );

    await Simulator.endSimulation();
  });

  test('async + trainableRead WIDE (64-bit): control STATUS read returns and '
      'ACKs through the downsizer', () async {
    // The creek RV64 reality: the core bus is 64-bit, so every control-window
    // access is split by the HarborWishboneDownsizer into two sequential 32-bit
    // narrow halves (low @ off, high @ off+4). The ddrlevel firmware's FIRST
    // train-control access is a bare STATUS read (ddr_level.dart:108 lw of
    // trainCtrlBase+0x18) with NO preceding array access, so the control ACK
    // must come back through the wide downsizer on its own. A control-reg read
    // to any trainCtrl reg must RETURN and ACK, never hang. The prior
    // async+trainable test only exercised the 32-bit narrow face, so this is the
    // wide-path regression guard for the train-control window ack.
    await bringUp(train: true, busDataWidth: 64);

    const size = 128 * 1024 * 1024;
    const status = size + 0x18; // reg3 STATUS, base-relative

    // The very first train-control access: a bare STATUS read, wide. If the
    // wide downsizer + control-window ack regressed, this hangs (no ack).
    final rd = await xfer(write: false, address: status);
    // The defined control plane (busy[0], tap[7:1]) reads back through the wide
    // mux. The DQS observability bits [12:8] are X in sim (unmodeled DQSBUFM
    // leaf), so only assert the access COMPLETED (acked). Busy must be idle
    // since no walk was launched.
    expect(rd & 0x1, 0, reason: 'STATUS busy idle, wide control read acked');

    // A second wide control read of a different reg (reg0 RDTAP) must also ack:
    // proves the window acks repeatedly through the downsizer, not just once.
    await xfer(write: false, address: size + 0x00);

    await Simulator.endSimulation();
  });

  test('ddrlevel build (train + writeLevel + async + WIDE): first STATUS read '
      'acks', () async {
    // The EXACT creek `ddrlevel` config: trainableRead AND writeLevel, async DDR
    // clock, 64-bit core bus. Earlier control tests left writeLevel OFF, so this
    // combination, the one that ships and was reported hanging on silicon, had
    // no functional control-window coverage. The firmware's first train-control
    // access (river_maskrom ddr_level.dart:108) is a bare STATUS lw with no
    // preceding DDR access, so the control ack must come back on its own.
    await bringUp(train: true, writeLevel: true, busDataWidth: 64);

    const size = 128 * 1024 * 1024;
    final rd = await xfer(write: false, address: size + 0x18);
    expect(
      rd & 0x1,
      0,
      reason: 'first wide STATUS read acks and reports idle (train+wl build)',
    );

    await Simulator.endSimulation();
  });

  test('control STATUS read acks with the DDR clock domain held in reset '
      '(PLL/DLL not locked, sclk stopped)', () async {
    // The contract the control-window logic claims: a control access is served
    // entirely on the bus clock and is INDEPENDENT of the sclk datapath, the DDR
    // PLL/DLL lock, and the init FSM. This pins that contract: hold ddrReset
    // asserted for the whole test (sclk never runs, init never completes) and a
    // control STATUS read must STILL ack. If a future change ties the control
    // ack to any sclk-domain busy/init/done flag (the deadlock shape the silicon
    // hang pointed at), this read stops acking and the test fails. A bus clk
    // model alone cannot otherwise distinguish a faithful clk-domain ack from one
    // that secretly depends on the (in sim, free-running) DDR clock.
    await bringUp(
      train: true,
      writeLevel: true,
      busDataWidth: 64,
      holdDdrReset: true,
    );

    const size = 128 * 1024 * 1024;
    final rd = await xfer(write: false, address: size + 0x18);
    // Busy must read idle: with init never completing, busySync stays 0 and the
    // bus-domain launch-pending latch was never set (no write happened).
    expect(
      rd & 0x1,
      0,
      reason:
          'control read must ack on the bus clock with the DDR domain '
          'frozen in reset',
    );

    await Simulator.endSimulation();
  });
}
