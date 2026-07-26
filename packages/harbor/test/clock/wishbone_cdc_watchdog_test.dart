import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// The creek Ferrite wedge: a marginal DDR clock tree momentarily freezes the
/// bridge's master (sclk) domain, so its gray done-counter never crosses back to
/// the slave and the outstanding load never ACKs: the whole core deadlocks.
///
/// This models that by gating the master clock off mid-transaction. Without the
/// slave-side completionTimeout backstop the slave waits forever. With it, the
/// request force-completes so the fabric keeps running (the read-retry re-reads,
/// so a transient freeze self-heals). A dormant watchdog (timeout far above the
/// completion latency) is verified by the rest of the CDC suite, which still
/// passes unchanged.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'watchdog force-completes when the master clock freezes (no hang)',
    () async {
      const aw = 32;
      const dw = 32;
      // Small budget so the test is short.
      final dut = HarborWishboneCdcBridge(
        addressWidth: aw,
        dataWidth: dw,
        completionTimeout: 8,
      );

      final sClk = SimpleClockGenerator(10).clk;
      // Gated master clock: while m_enable is high it toggles. Drop it and the
      // clock is stuck low (no edges): the master domain is frozen.
      final mEnable = Logic(name: 'm_enable');
      final mClk = (SimpleClockGenerator(10).clk & mEnable).named(
        'm_clk_gated',
      );
      final sReset = Logic(name: 's_reset');
      final mReset = Logic(name: 'm_reset');

      final sCyc = Logic(name: 's_cyc');
      final sStb = Logic(name: 's_stb');
      final sWe = Logic(name: 's_we');
      final sAdr = Logic(name: 's_adr', width: aw);
      final sDatW = Logic(name: 's_dat_w', width: dw);
      final sSel = Logic(name: 's_sel', width: dw ~/ 8);

      dut.input('s_clk').srcConnection! <= sClk;
      dut.input('s_reset').srcConnection! <= sReset;
      dut.input('s_cyc').srcConnection! <= sCyc;
      dut.input('s_stb').srcConnection! <= sStb;
      dut.input('s_we').srcConnection! <= sWe;
      dut.input('s_adr').srcConnection! <= sAdr;
      dut.input('s_dat_w').srcConnection! <= sDatW;
      dut.input('s_sel').srcConnection! <= sSel;
      dut.input('m_clk').srcConnection! <= mClk;
      dut.input('m_reset').srcConnection! <= mReset;

      // Master model: acks on the master cycle. Only ever advances while the
      // master clock runs, so once frozen the completion can never cross back.
      final mCyc = dut.output('m_cyc');
      final mStb = dut.output('m_stb');
      dut.input('m_ack').srcConnection! <= (mCyc & mStb);
      dut.input('m_dat_r').srcConnection! <= Const(0xBEEF, width: dw);

      mEnable.inject(1);
      sReset.inject(1);
      mReset.inject(1);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      sAdr.inject(0);
      sDatW.inject(0);
      sSel.inject(0xf);

      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());

      for (var i = 0; i < 4; i++) {
        await sClk.nextPosedge;
      }
      sReset.inject(0);
      mReset.inject(0);
      await sClk.nextPosedge;

      // Freeze the master domain, then issue a read. The master can never pick up
      // the request or return a completion.
      mEnable.inject(0);
      await sClk.nextPosedge;
      sWe.inject(0);
      sAdr.inject(0x40);
      sCyc.inject(1);
      sStb.inject(1);

      var acked = false;
      for (var guard = 0; guard < 64; guard++) {
        await sClk.nextPosedge;
        if (dut.output('s_ack').value == LogicValue.one) {
          acked = true;
          break;
        }
      }
      expect(
        acked,
        isTrue,
        reason:
            'watchdog must force-complete a read that the frozen master '
            'never acks (no permanent hang)',
      );

      await Simulator.endSimulation();
    },
  );

  test(
    'watchdog stays dormant while the master runs (normal completion)',
    () async {
      const aw = 32;
      const dw = 32;
      final dut = HarborWishboneCdcBridge(
        addressWidth: aw,
        dataWidth: dw,
        completionTimeout: 8,
      );

      final sClk = SimpleClockGenerator(10).clk;
      final mClk = SimpleClockGenerator(10).clk;
      final sReset = Logic(name: 's_reset');
      final mReset = Logic(name: 'm_reset');

      final sCyc = Logic(name: 's_cyc');
      final sStb = Logic(name: 's_stb');
      final sWe = Logic(name: 's_we');
      final sAdr = Logic(name: 's_adr', width: aw);
      final sDatW = Logic(name: 's_dat_w', width: dw);
      final sSel = Logic(name: 's_sel', width: dw ~/ 8);

      dut.input('s_clk').srcConnection! <= sClk;
      dut.input('s_reset').srcConnection! <= sReset;
      dut.input('s_cyc').srcConnection! <= sCyc;
      dut.input('s_stb').srcConnection! <= sStb;
      dut.input('s_we').srcConnection! <= sWe;
      dut.input('s_adr').srcConnection! <= sAdr;
      dut.input('s_dat_w').srcConnection! <= sDatW;
      dut.input('s_sel').srcConnection! <= sSel;
      dut.input('m_clk').srcConnection! <= mClk;
      dut.input('m_reset').srcConnection! <= mReset;

      final mem = Logic(name: 'mem', width: dw);
      final mCyc = dut.output('m_cyc');
      final mStb = dut.output('m_stb');
      final mWe = dut.output('m_we');
      final mDatW = dut.output('m_dat_w');
      dut.input('m_ack').srcConnection! <= (mCyc & mStb);
      dut.input('m_dat_r').srcConnection! <= mem;
      Sequential(mClk, reset: mReset, [
        If(mCyc & mStb & mWe, then: [mem < mDatW]),
      ]);

      sReset.inject(1);
      mReset.inject(1);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      sAdr.inject(0);
      sDatW.inject(0);
      sSel.inject(0xf);

      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());

      for (var i = 0; i < 4; i++) {
        await sClk.nextPosedge;
      }
      sReset.inject(0);
      mReset.inject(0);
      await sClk.nextPosedge;

      // A normal write then read must round-trip the real data. The watchdog
      // must not fire and poison it.
      Future<int> doXfer({required bool we, int data = 0}) async {
        sWe.inject(we ? 1 : 0);
        sAdr.inject(0x40);
        sDatW.inject(data);
        sCyc.inject(1);
        sStb.inject(1);
        var guard = 0;
        while (dut.output('s_ack').value != LogicValue.one) {
          await sClk.nextPosedge;
          if (++guard > 200) fail('timeout waiting for s_ack');
        }
        final rd = dut.output('s_dat_r').value.toInt();
        sCyc.inject(0);
        sStb.inject(0);
        for (var i = 0; i < 6; i++) {
          await sClk.nextPosedge;
        }
        return rd;
      }

      const magic = 0xC0DE1234;
      await doXfer(we: true, data: magic);
      final rd = await doXfer(we: false);
      expect(
        rd,
        equals(magic),
        reason:
            'normal completion must return real data, not a watchdog poison',
      );

      await Simulator.endSimulation();
    },
  );
}
