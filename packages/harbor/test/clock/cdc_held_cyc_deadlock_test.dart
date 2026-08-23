// Repro for the delta SD-read hang: the DRAM CDC bridge "needs cyc to drop
// between transactions" (l1_cache.dart:586). The L1 cache upholds that for the
// CPU, but the ADMA DMA path holds CYC across back-to-back transactions. This
// drives the REAL HarborWishboneCdcFifoBridge with a master that HOLDS s_cyc/
// s_stb across reads (never dropping between them) and checks it keeps
// completing, instead of wedging after the first.

import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<int> _run({
  required bool dropCyc,
  int mLatency = 3,
  int reads = 12,
}) async {
  await Simulator.reset();
  final cdc = HarborWishboneCdcFifoBridge(
    addressWidth: 32,
    dataWidth: 32,
    depth: 16,
    postedWrites: true,
  );

  final sClk = SimpleClockGenerator(10).clk;
  final mClk = SimpleClockGenerator(10).clk;
  final sReset = Logic(name: 'sreset')..inject(1);
  final mReset = Logic(name: 'mreset')..inject(1);
  final sCyc = Logic(name: 'scyc')..inject(0);
  final sStb = Logic(name: 'sstb')..inject(0);
  final sWe = Logic(name: 'swe')..inject(0);
  final sAdr = Logic(name: 'sadr', width: 32)..inject(0);
  final sDatW = Logic(name: 'sdatw', width: 32)..inject(0);
  final sSel = Logic(name: 'ssel', width: 4)..inject(0xf);
  final mAck = Logic(name: 'mack')..inject(0);
  final mDatR = Logic(name: 'mdatr', width: 32)..inject(0x5a5a5a5a);

  cdc.input('s_clk').srcConnection! <= sClk;
  cdc.input('s_reset').srcConnection! <= sReset;
  cdc.input('m_clk').srcConnection! <= mClk;
  cdc.input('m_reset').srcConnection! <= mReset;
  cdc.input('s_cyc').srcConnection! <= sCyc;
  cdc.input('s_stb').srcConnection! <= sStb;
  cdc.input('s_we').srcConnection! <= sWe;
  cdc.input('s_adr').srcConnection! <= sAdr;
  cdc.input('s_dat_w').srcConnection! <= sDatW;
  cdc.input('s_sel').srcConnection! <= sSel;
  cdc.input('m_ack').srcConnection! <= mAck;
  cdc.input('m_dat_r').srcConnection! <= mDatR;

  await cdc.build();

  // Master-side responder: after the CDC asserts m_cyc/m_stb, ack it mLatency
  // cycles later (models the burst adapter + DDR controller round trip).
  var mCnt = 0;
  final mSub = mClk.posedge.listen((_) {
    mAck.inject(0);
    final live =
        cdc.output('m_cyc').value.isValid &&
        cdc.output('m_cyc').value.toInt() == 1 &&
        cdc.output('m_stb').value.toInt() == 1;
    if (live) {
      mCnt++;
      if (mCnt >= mLatency) {
        mAck.inject(1);
        mCnt = 0;
      }
    } else {
      mCnt = 0;
    }
  });

  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await sClk.nextPosedge;
  await sClk.nextPosedge;
  sReset.inject(0);
  mReset.inject(0);
  await sClk.nextPosedge;

  var acks = 0;
  var guard = 0;
  // Issue `reads` reads. In dropCyc mode we drop cyc for one cycle after each
  // ack (the well-behaved master). In held mode we keep cyc/stb asserted the
  // whole time (the ADMA), which is what the CDC comment says deadlocks it.
  sWe.inject(0);
  sCyc.inject(1);
  sStb.inject(1);
  while (acks < reads && guard++ < 4000) {
    await sClk.nextPosedge;
    if (cdc.output('s_ack').value.toInt() == 1) {
      acks++;
      if (dropCyc) {
        sCyc.inject(0);
        sStb.inject(0);
        await sClk.nextPosedge;
        await sClk.nextPosedge;
        sCyc.inject(1);
        sStb.inject(1);
      }
    }
  }
  await mSub.cancel();
  await Simulator.endSimulation();
  return acks;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'CDC completes back-to-back reads when the master DROPS cyc (control)',
    () async {
      final acks = await _run(dropCyc: true, reads: 12);
      expect(
        acks,
        equals(12),
        reason: 'well-behaved master completes all reads',
      );
    },
  );

  test(
    'CDC does NOT wedge on HELD-cyc back-to-back reads (the ADMA pattern)',
    () async {
      final acks = await _run(dropCyc: false, reads: 12);
      expect(
        acks,
        equals(12),
        reason:
            'held-cyc reads wedged the CDC after $acks acks: this is the '
            'delta SD-read fabric deadlock (l1_cache.dart:586)',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
