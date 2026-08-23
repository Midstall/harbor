import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';

/// Functional correctness of the FIFO-based Wishbone CDC bridge: a write then a
/// read must round-trip across the two clock domains, and a continuous back-to-
/// back read burst must ACK every transaction (no wedge) across a range of clock
/// ratios and ack latencies, including the creek-like slave-slower ratios.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runXfer({required int sPeriod, required int mPeriod}) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcFifoBridge(
      addressWidth: aw,
      dataWidth: dw,
      depth: 8,
    );

    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
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

    // Fast-side model: a single 32-bit register, one-cycle combinational ACK.
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

    Simulator.setMaxSimTime(500000);
    unawaited(Simulator.run());
    for (var i = 0; i < 6; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    Future<int> doXfer({required bool we, int adr = 0x40, int data = 0}) async {
      sWe.inject(we ? 1 : 0);
      sAdr.inject(adr);
      sDatW.inject(data);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack (we=$we)');
      }
      final rd = dut.output('s_dat_r').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await sClk.nextPosedge;
      for (var i = 0; i < 6; i++) {
        await sClk.nextPosedge;
      }
      return rd;
    }

    const magic = 0xC0DE1234;
    await doXfer(we: true, adr: 0x40, data: magic);
    final rd = await doXfer(we: false, adr: 0x40);
    expect(rd, equals(magic), reason: 'read-back must match the written value');

    await Simulator.endSimulation();
  }

  test('write then read crosses domains (FIFO bridge)', () async {
    await runXfer(sPeriod: 40, mPeriod: 12); // creek-like 25:83
  });
  test('also works when master is slower than slave', () async {
    await runXfer(sPeriod: 10, mPeriod: 25);
  });
  test('near-equal asynchronous clocks', () async {
    await runXfer(sPeriod: 10, mPeriod: 11);
  });

  Future<int> hammer({
    required int sPeriod,
    required int mPeriod,
    required int ackDelay,
    required int n,
  }) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcFifoBridge(
      addressWidth: aw,
      dataWidth: dw,
      depth: 8,
    );
    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');
    final sCyc = Logic(name: 's_cyc');
    final sAdr = Logic(name: 's_adr', width: aw);

    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= Const(1);
    dut.input('s_we').srcConnection! <= Const(0);
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= Const(0, width: dw);
    dut.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    Sequential(mClk, reset: mReset, [
      If(
        mCyc & mStb,
        then: [
          If(ackCnt.lt(ackDelay), then: [ackCnt < ackCnt + 1]),
        ],
        orElse: [ackCnt < 0],
      ),
    ]);
    dut.input('m_ack').srcConnection! <= (mCyc & mStb & ackCnt.eq(ackDelay));
    dut.input('m_dat_r').srcConnection! <= Const(0xBEEF, width: dw);

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sAdr.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    sAdr.inject(0x40);
    sCyc.inject(1);
    var done = 0;
    for (var t = 0; t < n; t++) {
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000) return done;
      }
      done++;
      sAdr.inject(0x40 + (t + 1) * 4);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000) return done;
      }
    }
    await Simulator.endSimulation();
    return done;
  }

  for (final ratio in const [(s: 40, m: 12), (s: 10, m: 25), (s: 12, m: 12)]) {
    for (final ackDelay in const [1, 4]) {
      test('FIFO hammer s=${ratio.s} m=${ratio.m} ack=$ackDelay', () async {
        final done = await hammer(
          sPeriod: ratio.s,
          mPeriod: ratio.m,
          ackDelay: ackDelay,
          n: 30,
        );
        expect(done, 30, reason: 'all 30 back-to-back reads must ACK');
      });
    }
  }

  /// Streams [n] writes then reads one address back, against a master-side
  /// model that needs [ackDelay] cycles per transaction. Returns the slave
  /// clock cycles the write stream took and the value the read returned.
  Future<({int cycles, int readBack, int writes})> writeStream({
    required bool postedWrites,
    required int n,
    int sPeriod = 50,
    int mPeriod = 13,
    int ackDelay = 6,
  }) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcFifoBridge(
      addressWidth: aw,
      dataWidth: dw,
      depth: 8,
      postedWrites: postedWrites,
    );
    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final mDatR = Logic(name: 'm_dat_r', width: dw);

    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;
    dut.input('m_dat_r').srcConnection! <= mDatR;

    // Master-side model: a slow memory that takes ackDelay cycles per access.
    // This is what a crossing to a real DRAM controller looks like.
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    Sequential(mClk, reset: mReset, [
      If(
        mCyc & mStb,
        then: [
          If(ackCnt.lt(ackDelay), then: [ackCnt < ackCnt + 1]),
        ],
        orElse: [ackCnt < 0],
      ),
    ]);
    final mAck = (mCyc & mStb & ackCnt.eq(ackDelay)).named('m_ack_model');
    dut.input('m_ack').srcConnection! <= mAck;

    final mem = <int, int>{};
    var writesSeen = 0;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    mDatR.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    mClk.posedge.listen((_) {
      // Present the addressed word for a read, and commit a write on its ack.
      final adrVal = dut.output('m_adr').value;
      if (!adrVal.isValid) return;
      final adr = adrVal.toInt();
      mDatR.inject(mem[adr] ?? 0);
      if (mAck.value == LogicValue.one) {
        if (dut.output('m_we').value == LogicValue.one) {
          mem[adr] = dut.output('m_dat_w').value.toInt();
          writesSeen++;
        }
      }
    });

    for (var i = 0; i < 8; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    var cycles = 0;
    final counter = sClk.posedge.listen((_) => cycles++);

    for (var t = 0; t < n; t++) {
      sAdr.inject(0x100 + t * 4);
      sDatW.inject(0xA5000000 | t);
      sWe.inject(1);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 5000) fail('timeout on write $t');
      }
      // Drop the request for a cycle, the way a classic B4 master does.
      sCyc.inject(0);
      sStb.inject(0);
      await sClk.nextPosedge;
    }
    await counter.cancel();

    // Read one of the written words back. It must be ordered behind every
    // write already queued, posted or not.
    sAdr.inject(0x100 + (n - 1) * 4);
    sWe.inject(0);
    sCyc.inject(1);
    sStb.inject(1);
    var guard = 0;
    while (dut.output('s_ack').value != LogicValue.one) {
      await sClk.nextPosedge;
      if (++guard > 5000) fail('timeout on the read-back');
    }
    final readBack = dut.output('s_dat_r').value.toInt();
    sCyc.inject(0);
    sStb.inject(0);
    await sClk.nextPosedge;

    await Simulator.endSimulation();
    return (cycles: cycles, readBack: readBack, writes: writesSeen);
  }

  test('posted writes stream instead of paying a round trip each', () async {
    const n = 24;
    final posted = await writeStream(postedWrites: true, n: n);
    await Simulator.reset();
    final strict = await writeStream(postedWrites: false, n: n);

    expect(
      posted.writes,
      n,
      reason: 'every posted write must still reach the master side',
    );
    expect(
      posted.readBack,
      0xA5000000 | (n - 1),
      reason: 'the read must be ordered behind the posted writes',
    );
    expect(
      strict.readBack,
      0xA5000000 | (n - 1),
      reason: 'the strict path must read back the same value',
    );
    // The slave now only waits for FIFO space, not for a crossing round trip.
    expect(
      posted.cycles * 2,
      lessThan(strict.cycles),
      reason:
          'posting must more than halve the write stream: '
          'posted=${posted.cycles} strict=${strict.cycles} cycles',
    );
  });

  test('a full request FIFO still back-pressures a posted write', () async {
    // depth 8 with a much slower master: the stream cannot outrun the FIFO, so
    // every write must still land exactly once.
    final r = await writeStream(
      postedWrites: true,
      n: 40,
      sPeriod: 10,
      mPeriod: 10,
      ackDelay: 20,
    );
    expect(r.writes, 40, reason: 'no write may be dropped when the FIFO fills');
    expect(r.readBack, 0xA5000000 | 39);
  });
}
