@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Increment 1: CONTINUOUS multi-superblock tile walk.
//
// Decodes a 2-SB VERTICAL pair (SB0 at sb_row 0, SB1 at sb_row 1, same column)
// where each SB is an 8x8 root that SPLITs into four 4x4 leaves, on ONE
// continuous od_ec window with persistent adapting CDFs. This exercises:
//  (a) the continuous od_ec window + persistent adapted CDF banks spanning the
//      SB boundary (NO window re-init, NO CDF reload at SB1),
//  (b) the above-context arrays (abovePartCtx/aboveSkip/aboveYMode/aboveEC)
//      carrying SB0's bottom edge into SB1's top edge,
//  (c) SB1's tile-relative TOP-edge availability (above_open) so SB1's top
//      leaves read the preserved above-* arrays (Increment 0 availability).
//
// The crux assertion is SB1's emitted leaf/coeff stream + above-ctx outputs
// being bit-exact vs a self-contained software golden that decodes BOTH SBs on
// ONE OdEc with ONE set of (persistent) CDF contexts. SB1 only matches when the
// hardware kept the window + CDFs continuous AND propagated SB0's above-ctx.
//
// The golden VALUES below were captured from the reference software od_ec decode
// (golden2sb) for the 6 qualifying seeded streams (Random(0x2517), both roots
// SPLIT-to-4x4), preserving the exact generation order.

typedef _Sb = ({
  int leafCount,
  int chk,
  List<int> above,
  List<int> aboveSkip,
  List<int> aboveYm,
});

typedef _Stream = ({List<int> b, int dcv, int acv, _Sb sb0, _Sb sb1});

const _streams = <_Stream>[
  (
    b: [
      250,
      81,
      222,
      247,
      108,
      230,
      210,
      223,
      229,
      201,
      126,
      10,
      50,
      248,
      137,
      214,
      115,
      9,
      89,
      212,
      42,
      166,
      150,
      162,
      53,
      65,
      116,
      7,
      87,
      197,
      179,
      70,
      170,
      93,
      152,
      241,
      127,
      81,
      29,
      183,
      193,
      69,
      23,
      114,
      234,
      192,
      220,
      203,
    ],
    dcv: 72,
    acv: 85,
    sb0: (
      leafCount: 4,
      chk: 2674642114,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 0],
    ),
    sb1: (
      leafCount: 4,
      chk: 868610998,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 0],
    ),
  ),
  (
    b: [
      248,
      189,
      19,
      172,
      237,
      93,
      174,
      53,
      189,
      105,
      25,
      250,
      103,
      99,
      152,
      106,
      22,
      212,
      26,
      117,
      107,
      232,
      36,
      29,
      188,
      163,
      139,
      254,
      30,
      222,
      95,
      174,
      191,
      45,
      8,
      82,
      205,
      255,
      140,
      25,
      131,
      120,
      49,
      151,
      76,
      49,
      196,
      68,
    ],
    dcv: 76,
    acv: 90,
    sb0: (
      leafCount: 4,
      chk: 109034003,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 1],
    ),
    sb1: (
      leafCount: 4,
      chk: 3573117168,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [4, 9],
    ),
  ),
  (
    b: [
      255,
      147,
      219,
      165,
      8,
      187,
      16,
      176,
      190,
      0,
      191,
      68,
      122,
      236,
      203,
      48,
      172,
      106,
      108,
      175,
      222,
      228,
      141,
      49,
      140,
      110,
      111,
      165,
      56,
      114,
      11,
      187,
      64,
      77,
      4,
      20,
      127,
      250,
      184,
      230,
      162,
      3,
      99,
      52,
      65,
      7,
      118,
      243,
    ],
    dcv: 67,
    acv: 79,
    sb0: (
      leafCount: 4,
      chk: 3090555712,
      above: [31, 31],
      aboveSkip: [1, 1],
      aboveYm: [0, 0],
    ),
    sb1: (
      leafCount: 4,
      chk: 3543947399,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [9, 0],
    ),
  ),
  (
    b: [
      237,
      204,
      54,
      171,
      134,
      143,
      218,
      227,
      131,
      219,
      18,
      32,
      255,
      222,
      228,
      176,
      93,
      176,
      13,
      206,
      82,
      75,
      8,
      57,
      220,
      16,
      86,
      213,
      213,
      14,
      198,
      3,
      244,
      229,
      144,
      122,
      90,
      243,
      127,
      244,
      96,
      147,
      16,
      209,
      158,
      223,
      212,
      92,
    ],
    dcv: 40,
    acv: 46,
    sb0: (
      leafCount: 4,
      chk: 3416256864,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 7],
    ),
    sb1: (
      leafCount: 4,
      chk: 3211779106,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [6, 11],
    ),
  ),
  (
    b: [
      248,
      112,
      161,
      41,
      70,
      139,
      25,
      101,
      106,
      121,
      218,
      186,
      41,
      54,
      111,
      250,
      84,
      191,
      254,
      32,
      98,
      247,
      199,
      160,
      129,
      247,
      24,
      154,
      128,
      68,
      93,
      230,
      158,
      104,
      169,
      142,
      241,
      47,
      169,
      3,
      41,
      188,
      103,
      211,
      42,
      59,
      69,
      229,
    ],
    dcv: 87,
    acv: 104,
    sb0: (
      leafCount: 4,
      chk: 1385234207,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 12],
    ),
    sb1: (
      leafCount: 4,
      chk: 1191316986,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [6, 0],
    ),
  ),
  (
    b: [
      250,
      89,
      15,
      149,
      241,
      205,
      75,
      65,
      3,
      145,
      137,
      41,
      17,
      52,
      178,
      33,
      253,
      154,
      55,
      62,
      165,
      181,
      246,
      93,
      103,
      251,
      151,
      113,
      142,
      106,
      62,
      162,
      188,
      141,
      236,
      69,
      85,
      188,
      28,
      148,
      247,
      196,
      84,
      198,
      60,
      85,
      170,
      137,
    ],
    dcv: 72,
    acv: 85,
    sb0: (
      leafCount: 4,
      chk: 3735650774,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [11, 2],
    ),
    sb1: (
      leafCount: 4,
      chk: 829441611,
      above: [31, 31],
      aboveSkip: [0, 0],
      aboveYm: [0, 11],
    ),
  ),
];

// HW per-SB decoded result captured from the continuous walk.
class _SbResult {
  final int leafCount;
  final int chk;
  final List<int> above;
  final List<int> left;
  final List<int> aboveSkip;
  final List<int> aboveYm;
  _SbResult(
    this.leafCount,
    this.chk,
    this.above,
    this.left,
    this.aboveSkip,
    this.aboveYm,
  );
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 48;

  test(
    '2-SB vertical pair decodes bit-exact on a continuous window',
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      final w = HarborKeyframeModeWalk(
        rootBsize: 3,
        maxBytes: maxBytes,
        coeffPrefix: true,
        multiSb: true,
      );
      const sbMi = 2;
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final cont = Logic(name: 'cont');
      final aboveOpen = Logic(name: 'above_open');
      // The horizontal-continuation ports default to 0 here (this test exercises
      // the VERTICAL pair: fresh left context per SB column, no left-open edge).
      final contLeft = Logic(name: 'cont_left');
      final leftOpen = Logic(name: 'left_open');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final dcQ = Logic(name: 'dc_q', width: 16);
      final acQ = Logic(name: 'ac_q', width: 16);

      w.input('clk').srcConnection! <= clk;
      w.input('reset').srcConnection! <= reset;
      w.input('start').srcConnection! <= start;
      w.input('cont').srcConnection! <= cont;
      w.input('above_open').srcConnection! <= aboveOpen;
      w.input('cont_left').srcConnection! <= contLeft;
      w.input('left_open').srcConnection! <= leftOpen;
      w.input('bytes').srcConnection! <= bytes;
      w.input('dc_q').srcConnection! <= dcQ;
      w.input('ac_q').srcConnection! <= acQ;
      await w.build();

      reset.inject(1);
      start.inject(0);
      cont.inject(0);
      aboveOpen.inject(0);
      contLeft.inject(0);
      leftOpen.inject(0);
      bytes.inject(0);
      dcQ.inject(0);
      acQ.inject(0);
      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      BigInt packBytes(List<int> b) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & 0xff) << (i * 8);
        }
        return v;
      }

      List<int> unpack(BigInt v, int n, int width) => [
        for (var i = 0; i < n; i++)
          ((v >> (i * width)) & BigInt.from((1 << width) - 1)).toInt(),
      ];

      // Run ONE SB on the hardware: pulse start with the given cont/above_open,
      // wait for done, then capture the per-SB outputs.
      Future<_SbResult> runSb({
        required bool contFlag,
        required bool aboveOpenFlag,
      }) async {
        cont.inject(contFlag ? 1 : 0);
        aboveOpen.inject(aboveOpenFlag ? 1 : 0);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (w.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 5000) fail('walk timeout');
        }
        final res = _SbResult(
          w.output('leaf_count').value.toInt(),
          w.output('chk').value.toInt(),
          unpack(w.output('above_ctx').value.toBigInt(), sbMi, 5),
          unpack(w.output('left_ctx').value.toBigInt(), sbMi, 5),
          unpack(w.output('above_skip').value.toBigInt(), sbMi, 1),
          unpack(w.output('above_ymode').value.toBigInt(), sbMi, 4),
        );
        // back to idle for the next SB (done -> idle needs start low).
        await clk.nextPosedge;
        return res;
      }

      var found = 0;
      for (var iter = 0; iter < _streams.length; iter++) {
        final s = _streams[iter];

        bytes.inject(packBytes(s.b));
        dcQ.inject(s.dcv);
        acQ.inject(s.acv);

        // SB0: fresh start (cont = 0, above_open = 0).
        final got0 = await runSb(contFlag: false, aboveOpenFlag: false);
        // SB1: CONTINUE the window (cont = 1) with a row above (above_open = 1).
        final got1 = await runSb(contFlag: true, aboveOpenFlag: true);

        expect(
          got0.leafCount,
          s.sb0.leafCount,
          reason: 'sb0 leafCount it=$iter',
        );
        expect(got0.chk, s.sb0.chk, reason: 'sb0 chk it=$iter');
        expect(got0.above, s.sb0.above, reason: 'sb0 above it=$iter');
        expect(
          got0.aboveSkip,
          s.sb0.aboveSkip,
          reason: 'sb0 aboveSkip it=$iter',
        );
        expect(got0.aboveYm, s.sb0.aboveYm, reason: 'sb0 aboveYm it=$iter');

        // CRUX: SB1 only matches when the window + CDFs stayed continuous AND
        // SB0's above-ctx propagated into SB1.
        expect(
          got1.leafCount,
          s.sb1.leafCount,
          reason: 'sb1 leafCount it=$iter',
        );
        expect(got1.chk, s.sb1.chk, reason: 'sb1 chk it=$iter');
        expect(got1.above, s.sb1.above, reason: 'sb1 above it=$iter');
        expect(
          got1.aboveSkip,
          s.sb1.aboveSkip,
          reason: 'sb1 aboveSkip it=$iter',
        );
        expect(got1.aboveYm, s.sb1.aboveYm, reason: 'sb1 aboveYm it=$iter');
        found++;
      }
      expect(
        found >= 3,
        isTrue,
        reason: 'too few 2x SPLIT pairs found ($found)',
      );
      await Simulator.endSimulation();
    },
  );
}
