@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// STAGE 1: CHROMA ENTROPY ACROSS SB BOUNDARIES (multi-SB tile).
//
// Decodes a 1x2 HORIZONTAL tile of two 8x8 NONE leaves (4:2:0) on ONE continuous
// od_ec window with persistent, adapting CDF contexts (the real tile model). The
// crux: SB1's chroma 4x4 TXB (U and V) has a chroma neighbour to the LEFT, namely
// SB0's chroma EC (carried across the SB boundary via cont_left). SB1's chroma
// txb_skip ctx (aboveEc + leftEc + 7) and dc_sign ctx therefore DEPEND on SB0's
// chroma EC. SB1 decodes bit-exact ONLY because the hardware propagated SB0's
// chroma EC into SB1's left chroma neighbour.
//
// The golden VALUES below were captured from the reference software decode
// (goldenTile1x2, one OdEc + one persistent context bank carrying the chroma EC
// from SB0 into SB1) for the 6 qualifying seeded streams (Random(0x5C0), qi=64
// so dc_q=61 ac_q=71, requiring SB0 nonzero chroma EC and SB0 luma all_zero),
// preserving the exact generation order.

const _dcv = 61, _acv = 71;

typedef _Sb = ({
  int leafCount,
  int chk,
  int uvMode,
  int cflAlphaIdx,
  int cflSigns,
  List<int> uCoeffs,
  List<int> vCoeffs,
});

typedef _Stream = ({List<int> b, _Sb sb0, _Sb sb1});

const _streams = <_Stream>[
  (
    b: [
      13,
      32,
      139,
      42,
      99,
      83,
      129,
      214,
      17,
      57,
      205,
      4,
      73,
      121,
      6,
      46,
      57,
      104,
      134,
      149,
      176,
      26,
      142,
      170,
      200,
      235,
      216,
      167,
      164,
      53,
      74,
      239,
      196,
      129,
      106,
      53,
      222,
      139,
      97,
      164,
      132,
      112,
      231,
      100,
      141,
      162,
      173,
      174,
    ],
    sb0: (
      leafCount: 1,
      chk: 332959098,
      uvMode: 0,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [61, 65465, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
    sb1: (
      leafCount: 1,
      chk: 1666090008,
      uvMode: 12,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [61, 71, 71, 71, 71, 65465, 65465, 71, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
  (
    b: [
      63,
      61,
      33,
      32,
      114,
      6,
      225,
      246,
      105,
      161,
      170,
      45,
      218,
      58,
      9,
      168,
      27,
      35,
      178,
      69,
      159,
      145,
      211,
      239,
      82,
      72,
      211,
      229,
      49,
      150,
      248,
      214,
      20,
      186,
      177,
      197,
      212,
      75,
      70,
      201,
      140,
      207,
      221,
      165,
      120,
      141,
      32,
      86,
    ],
    sb0: (
      leafCount: 1,
      chk: 332959098,
      uvMode: 13,
      cflAlphaIdx: 16,
      cflSigns: 4,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [61, 0, 0, 0, 0, 0, 0, 0, 0, 0, 71, 0, 0, 0, 65465, 0],
    ),
    sb1: (
      leafCount: 1,
      chk: 1719375005,
      uvMode: 0,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [61, 65465, 0, 0, 0, 0, 0, 0, 0, 71, 0, 0, 0, 0, 0, 0],
      vCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
  (
    b: [
      127,
      165,
      51,
      29,
      52,
      120,
      36,
      191,
      178,
      208,
      157,
      162,
      98,
      155,
      101,
      65,
      115,
      226,
      195,
      165,
      17,
      221,
      50,
      38,
      173,
      119,
      99,
      22,
      125,
      148,
      255,
      176,
      102,
      110,
      242,
      84,
      228,
      164,
      59,
      78,
      249,
      25,
      250,
      168,
      116,
      20,
      20,
      155,
    ],
    sb0: (
      leafCount: 1,
      chk: 1824908826,
      uvMode: 13,
      cflAlphaIdx: 0,
      cflSigns: 2,
      uCoeffs: [61, 65465, 0, 0, 71, 71, 0, 0, 65465, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [
        65475,
        65465,
        0,
        65465,
        0,
        0,
        0,
        65465,
        71,
        0,
        71,
        71,
        0,
        71,
        65394,
        0,
      ],
    ),
    sb1: (
      leafCount: 1,
      chk: 1489002035,
      uvMode: 13,
      cflAlphaIdx: 0,
      cflSigns: 2,
      uCoeffs: [122, 0, 65394, 71, 142, 0, 0, 0, 0, 0, 0, 0, 71, 0, 0, 0],
      vCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
  (
    b: [
      13,
      39,
      76,
      168,
      145,
      106,
      22,
      170,
      234,
      185,
      162,
      164,
      19,
      118,
      133,
      136,
      217,
      205,
      33,
      4,
      201,
      83,
      20,
      89,
      235,
      196,
      84,
      39,
      142,
      218,
      232,
      247,
      152,
      131,
      233,
      30,
      220,
      90,
      186,
      57,
      222,
      20,
      152,
      157,
      156,
      12,
      194,
      75,
    ],
    sb0: (
      leafCount: 1,
      chk: 332959098,
      uvMode: 0,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [
        61,
        65252,
        71,
        0,
        65323,
        71,
        65465,
        0,
        71,
        0,
        0,
        0,
        71,
        0,
        0,
        0,
      ],
    ),
    sb1: (
      leafCount: 1,
      chk: 1707374347,
      uvMode: 10,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
  (
    b: [
      49,
      139,
      111,
      80,
      215,
      192,
      152,
      121,
      76,
      170,
      171,
      195,
      45,
      96,
      180,
      178,
      60,
      1,
      36,
      96,
      82,
      136,
      222,
      164,
      184,
      85,
      193,
      66,
      41,
      240,
      143,
      134,
      3,
      129,
      23,
      140,
      116,
      142,
      209,
      125,
      125,
      70,
      167,
      16,
      165,
      212,
      90,
      189,
    ],
    sb0: (
      leafCount: 1,
      chk: 332959098,
      uvMode: 12,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [
        0,
        65394,
        0,
        0,
        65465,
        65465,
        0,
        0,
        0,
        65465,
        71,
        0,
        0,
        0,
        0,
        0,
      ],
      vCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
    sb1: (
      leafCount: 1,
      chk: 2250371275,
      uvMode: 2,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
  (
    b: [
      131,
      207,
      144,
      214,
      97,
      233,
      123,
      62,
      71,
      231,
      136,
      227,
      66,
      182,
      233,
      174,
      8,
      252,
      3,
      88,
      21,
      198,
      153,
      149,
      72,
      191,
      118,
      73,
      91,
      80,
      144,
      214,
      160,
      124,
      67,
      45,
      234,
      13,
      44,
      26,
      117,
      106,
      253,
      40,
      189,
      104,
      187,
      22,
    ],
    sb0: (
      leafCount: 1,
      chk: 685613610,
      uvMode: 9,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [
        65414,
        65465,
        71,
        0,
        213,
        0,
        65323,
        65465,
        142,
        0,
        71,
        71,
        71,
        65465,
        65394,
        65465,
      ],
    ),
    sb1: (
      leafCount: 1,
      chk: 19375570,
      uvMode: 12,
      cflAlphaIdx: 0,
      cflSigns: 0,
      uCoeffs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      vCoeffs: [183, 71, 0, 0, 71, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ),
  ),
];

// HW per-SB chroma result captured from the continuous walk.
class _SbChroma {
  final int leafCount;
  final int chk;
  final int uvMode;
  final int cflAlphaIdx;
  final int cflSigns;
  final List<int> uCoeffs;
  final List<int> vCoeffs;
  _SbChroma(
    this.leafCount,
    this.chk,
    this.uvMode,
    this.cflAlphaIdx,
    this.cflSigns,
    this.uCoeffs,
    this.vCoeffs,
  );
}

// Running CHROMA checksum for one SB (the surface this stage owns). The module's
// `chk` output folds the LUMA coeffs whose neighbour-derived dc_sign/scan is a
// later (recon) stage. The chroma U/V + uv_mode fully pin the cross-SB
// chroma-entropy result this task delivers.
int _chromaChk(
  int uvMode,
  int cflAlphaIdx,
  int cflSigns,
  List<int> uCoeffs,
  List<int> vCoeffs,
) {
  var c = (uvMode * 31 + cflAlphaIdx) & 0xFFFFFFFF;
  c = (c * 31 + cflSigns) & 0xFFFFFFFF;
  for (final x in uCoeffs) {
    c = (c * 31 + (x & 0xffff)) & 0xFFFFFFFF;
  }
  for (final x in vCoeffs) {
    c = (c * 31 + (x & 0xffff)) & 0xFFFFFFFF;
  }
  return c;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 48;

  test(
    '1x2 chroma tile: SB1 chroma decodes bit-exact from SB0 chroma EC',
    timeout: const Timeout(Duration(minutes: 25)),
    () async {
      const qband = 0;
      final w = HarborKeyframeModeWalk(
        rootBsize: 3,
        maxBytes: maxBytes,
        coeffPrefix: true,
        txLeaf: true,
        chroma: true,
        multiSb: true,
        tileMiW: 4,
        qband: qband,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final cont = Logic(name: 'cont');
      final aboveOpen = Logic(name: 'above_open');
      final contLeft = Logic(name: 'cont_left');
      final leftOpen = Logic(name: 'left_open');
      final sbCMi = Logic(name: 'sb_c_mi', width: w.input('sb_c_mi').width);
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
      w.input('sb_c_mi').srcConnection! <= sbCMi;
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
      sbCMi.inject(0);
      bytes.inject(0);
      dcQ.inject(0);
      acQ.inject(0);
      Simulator.setMaxSimTime(400000000);
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

      Future<_SbChroma> runSb({
        required bool contFlag,
        required bool aboveOpenFlag,
        required bool contLeftFlag,
        required bool leftOpenFlag,
        required int sbCol,
      }) async {
        cont.inject(contFlag ? 1 : 0);
        aboveOpen.inject(aboveOpenFlag ? 1 : 0);
        contLeft.inject(contLeftFlag ? 1 : 0);
        leftOpen.inject(leftOpenFlag ? 1 : 0);
        sbCMi.inject(sbCol);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (w.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 12000) fail('walk timeout');
        }
        final uc = unpack(w.output('leaf_u_coeffs').value.toBigInt(), 16, 16);
        final vc = unpack(w.output('leaf_v_coeffs').value.toBigInt(), 16, 16);
        final res = _SbChroma(
          w.output('leaf_count').value.toInt(),
          w.output('chk').value.toInt(),
          w.output('leaf_uv_mode').value.toInt(),
          w.output('leaf_cfl_alpha_idx').value.toInt(),
          w.output('leaf_cfl_signs').value.toInt(),
          uc,
          vc,
        );
        await clk.nextPosedge;
        return res;
      }

      var found = 0;
      for (var iter = 0; iter < _streams.length; iter++) {
        final s = _streams[iter];

        bytes.inject(packBytes(s.b));
        dcQ.inject(_dcv);
        acQ.inject(_acv);

        // SB0: fresh start (no neighbours).
        final got0 = await runSb(
          contFlag: false,
          aboveOpenFlag: false,
          contLeftFlag: false,
          leftOpenFlag: false,
          sbCol: 0,
        );
        // SB1: HORIZONTAL continuation (cont_left = 1, left_open = 1), same SB
        // row, to the RIGHT (sb_c_mi = 2). cont = 1 keeps the window continuous.
        final got1 = await runSb(
          contFlag: true,
          aboveOpenFlag: false,
          contLeftFlag: true,
          leftOpenFlag: true,
          sbCol: 2,
        );

        expect(
          got0.leafCount,
          s.sb0.leafCount,
          reason: 'sb0 leafCount it=$iter',
        );
        expect(got0.chk, s.sb0.chk, reason: 'sb0 chk it=$iter');
        expect(got0.uvMode, s.sb0.uvMode, reason: 'sb0 uvMode it=$iter');
        expect(got0.uCoeffs, s.sb0.uCoeffs, reason: 'sb0 uCoeffs it=$iter');
        expect(got0.vCoeffs, s.sb0.vCoeffs, reason: 'sb0 vCoeffs it=$iter');

        // CRUX: SB1 only matches if SB0's chroma EC propagated as SB1's left
        // chroma neighbour (the txb_skip + dc_sign ctx for SB1's U/V depend on it).
        expect(
          got1.leafCount,
          s.sb1.leafCount,
          reason: 'sb1 leafCount it=$iter',
        );
        expect(got1.uvMode, s.sb1.uvMode, reason: 'sb1 uvMode it=$iter');
        expect(got1.uCoeffs, s.sb1.uCoeffs, reason: 'sb1 uCoeffs it=$iter');
        expect(got1.vCoeffs, s.sb1.vCoeffs, reason: 'sb1 vCoeffs it=$iter');

        final wantChk1 = _chromaChk(
          s.sb1.uvMode,
          s.sb1.cflAlphaIdx,
          s.sb1.cflSigns,
          s.sb1.uCoeffs,
          s.sb1.vCoeffs,
        );
        final wantChk0 = _chromaChk(
          s.sb0.uvMode,
          s.sb0.cflAlphaIdx,
          s.sb0.cflSigns,
          s.sb0.uCoeffs,
          s.sb0.vCoeffs,
        );
        expect(
          _chromaChk(
            got1.uvMode,
            got1.cflAlphaIdx,
            got1.cflSigns,
            got1.uCoeffs,
            got1.vCoeffs,
          ),
          wantChk1,
          reason: 'sb1 chromaChk it=$iter',
        );
        expect(
          _chromaChk(
            got0.uvMode,
            got0.cflAlphaIdx,
            got0.cflSigns,
            got0.uCoeffs,
            got0.vCoeffs,
          ),
          wantChk0,
          reason: 'sb0 chromaChk it=$iter',
        );
        // With SB0 luma all_zero, SB1's luma left neighbour is 0, so the module's
        // full running chk (luma + leaf modes) also lines up for BOTH SBs.
        expect(got1.chk, s.sb1.chk, reason: 'sb1 chk it=$iter');
        found++;
      }
      expect(
        found >= 1,
        isTrue,
        reason: 'no qualifying 1x2 tile found ($found)',
      );
      await Simulator.endSimulation();
    },
  );
}
