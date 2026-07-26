import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_read_retry.dart';

/// Drives the read-retry filter's slave face and models a GLITCHY one-cycle
/// Wishbone register slave on the master side: the FIRST read of each
/// transaction returns garbage, every subsequent read returns the correct
/// stored word (the intermittent-but-re-reads-correct DDR read defect). The
/// filter must retry until two consecutive reads agree and return the correct
/// word. Writes must pass straight through.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('retries a glitchy read until two agree; write passes through', () async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneReadRetry(addressWidth: aw, dataWidth: dw);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final sSel = Logic(name: 's_sel', width: dw ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;

    // Glitchy master slave: one stored cell, combinational ack on the master
    // cycle. The first read since the last slave ack returns garbage, the rest
    // return the stored value. Writes store on the edge.
    final mem = Logic(name: 'mem', width: dw);
    final rdSinceAck = Logic(name: 'rd_since_ack', width: 4);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final mRead = mCyc & mStb & ~mWe;
    final mAck = mCyc & mStb;
    final glitch = mRead & rdSinceAck.eq(0);
    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_dat_r').srcConnection! <=
        mux(glitch, Const(0xDEADBEEF, width: dw), mem);
    Sequential(clk, reset: reset, [
      If(
        reset | dut.output('s_ack'),
        then: [rdSinceAck < Const(0, width: 4)],
        orElse: [
          If(mRead & mAck, then: [rdSinceAck < rdSinceAck + 1]),
        ],
      ),
      If(mCyc & mStb & mWe, then: [mem < mDatW]),
    ]);

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xf);

    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    Future<int> doXfer({required bool we, int adr = 0x80, int data = 0}) async {
      sWe.inject(we ? 1 : 0);
      sAdr.inject(adr);
      sDatW.inject(data);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await clk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack (we=$we)');
      }
      final rd = dut.output('s_dat_r').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;
      return rd;
    }

    // Write passes through to the backing.
    await doXfer(we: true, adr: 0x80, data: 0x11223344);
    expect(
      mem.value.toInt(),
      equals(0x11223344),
      reason: 'write must pass through to the master',
    );

    // Read: the first master read glitches (0xDEADBEEF), retries converge on
    // the correct stored word.
    final rd = await doXfer(we: false, adr: 0x80);
    expect(
      rd,
      equals(0x11223344),
      reason: 'read-retry must return the correct word despite the glitch',
    );

    // A second read (again first-read-glitches) still returns correct.
    final rd2 = await doXfer(we: false, adr: 0x80);
    expect(rd2, equals(0x11223344), reason: 'read-retry must be repeatable');

    await Simulator.endSimulation();
  });
}
