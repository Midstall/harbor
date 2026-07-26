@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// FULL 8x8 keyframe intra LUMA block: coded bytes + neighbours -> pixels.
//   bytes -> [HarborCoeffLevels kfIntra txSize:1] -> y_mode, angle_delta,
//            tx_type, coeffs(64)
//   coeffs + tx_type -> [HarborInvTxfm txSize:1 runtimeTxType] -> residual
//   y_mode + angle_delta + neighbours -> [HarborIntraPredFull bs:8] -> pred
//   recon = clip(pred + residual, 0, 255)
// The golden reconstruction, y_mode, angle, tx_type, dc/ac quant and
// coeff-nonzero flag per iteration are captured from the software decoder and
// embedded below so this test no longer depends on the SW oracle at run time.

const _recon = [
  [
    76,
    72,
    49,
    0,
    0,
    0,
    24,
    103,
    80,
    89,
    103,
    122,
    144,
    107,
    77,
    126,
    133,
    171,
    184,
    236,
    245,
    221,
    234,
    254,
    114,
    127,
    116,
    123,
    99,
    76,
    103,
    129,
    69,
    66,
    81,
    79,
    71,
    38,
    6,
    16,
    73,
    70,
    83,
    89,
    103,
    107,
    104,
    119,
    90,
    95,
    109,
    129,
    112,
    74,
    52,
    41,
    56,
    21,
    40,
    81,
    74,
    27,
    12,
    33,
  ],
  [
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
    131,
  ],
  [
    255,
    252,
    165,
    122,
    151,
    166,
    160,
    159,
    191,
    183,
    97,
    59,
    91,
    107,
    98,
    94,
    133,
    135,
    62,
    43,
    90,
    117,
    113,
    116,
    149,
    129,
    47,
    18,
    57,
    65,
    39,
    17,
    43,
    41,
    0,
    0,
    46,
    74,
    58,
    50,
    94,
    90,
    34,
    47,
    117,
    146,
    123,
    110,
    151,
    146,
    95,
    115,
    191,
    220,
    193,
    175,
    210,
    195,
    139,
    156,
    228,
    249,
    212,
    184,
  ],
  [
    151,
    162,
    131,
    112,
    134,
    158,
    134,
    96,
    120,
    111,
    132,
    147,
    118,
    80,
    65,
    89,
    139,
    140,
    126,
    118,
    120,
    108,
    68,
    55,
    140,
    142,
    112,
    94,
    118,
    125,
    79,
    57,
    121,
    117,
    124,
    124,
    121,
    99,
    67,
    86,
    159,
    166,
    120,
    89,
    124,
    167,
    119,
    83,
    137,
    127,
    147,
    157,
    131,
    129,
    114,
    149,
    163,
    161,
    160,
    162,
    153,
    191,
    174,
    184,
  ],
  [
    129,
    129,
    129,
    129,
    128,
    128,
    128,
    128,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
    129,
  ],
  [
    112,
    103,
    81,
    104,
    164,
    72,
    80,
    146,
    113,
    109,
    97,
    76,
    142,
    129,
    57,
    123,
    113,
    112,
    113,
    91,
    69,
    178,
    100,
    41,
    116,
    115,
    115,
    111,
    85,
    89,
    172,
    74,
    115,
    114,
    112,
    114,
    102,
    74,
    121,
    138,
    113,
    112,
    112,
    113,
    111,
    88,
    66,
    162,
    115,
    108,
    111,
    114,
    110,
    108,
    83,
    72,
    120,
    111,
    116,
    116,
    113,
    113,
    101,
    78,
  ],
  [
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    21,
    9,
    9,
    9,
    9,
    9,
    9,
    9,
    125,
    20,
    9,
    9,
    9,
    9,
    9,
    9,
    185,
    114,
    18,
    9,
    9,
    9,
    9,
    9,
    225,
    180,
    99,
    17,
    9,
    9,
    9,
    9,
    214,
    221,
    173,
    88,
    15,
    9,
    9,
    9,
    197,
    216,
    217,
    168,
    74,
    14,
    9,
    9,
  ],
  [
    255,
    164,
    0,
    0,
    68,
    0,
    0,
    0,
    163,
    89,
    0,
    75,
    255,
    255,
    255,
    0,
    248,
    255,
    216,
    141,
    153,
    221,
    255,
    255,
    138,
    255,
    255,
    172,
    0,
    0,
    0,
    149,
    33,
    42,
    169,
    244,
    92,
    23,
    16,
    37,
    255,
    221,
    162,
    177,
    255,
    255,
    255,
    234,
    255,
    255,
    255,
    230,
    162,
    189,
    255,
    255,
    46,
    0,
    253,
    196,
    0,
    0,
    49,
    121,
  ],
  [
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
    127,
  ],
  [
    127,
    128,
    131,
    129,
    125,
    133,
    132,
    115,
    134,
    145,
    141,
    138,
    131,
    132,
    130,
    111,
    129,
    135,
    123,
    126,
    120,
    109,
    112,
    110,
    147,
    133,
    127,
    125,
    118,
    120,
    121,
    124,
    133,
    133,
    126,
    112,
    104,
    111,
    113,
    112,
    129,
    134,
    133,
    124,
    110,
    114,
    125,
    113,
    137,
    133,
    133,
    124,
    110,
    108,
    117,
    112,
    138,
    159,
    138,
    111,
    116,
    98,
    94,
    129,
  ],
];
const _yMode = [0, 0, 2, 0, 2, 4, 4, 0, 8, 0];
const _angle = [0, 0, 5, 0, 1, 0, 2, 0, 2, 0];
const _txType = [3, 0, 2, 3, 0, 1, 0, 0, 0, 1];
const _nonZero = [
  true,
  false,
  true,
  true,
  false,
  true,
  false,
  true,
  false,
  true,
];
const _dcQ = [185, 105, 441, 77, 76, 8, 272, 309, 569, 31];
const _acQ = [243, 128, 757, 91, 90, 9, 394, 465, 1026, 35];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const bs = 8, n = 64, maxBytes = 64;

  test(
    '8x8 keyframe intra block: coded bytes + neighbours -> pixels',
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      final cl = HarborCoeffLevels(
        maxBytes: maxBytes,
        txSize: 1,
        readTxType: true,
        kfIntra: true,
      );
      final tx = HarborInvTxfm(txSize: 1, txType: 0, runtimeTxType: true);
      final pred = HarborIntraPredFull(bs: bs);
      final ra = HarborReconAdd(n: n);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final clStart = Logic(name: 'cl_start');
      final txStart = Logic(name: 'tx_start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final dcQ = Logic(name: 'dc_q', width: 16);
      final acQ = Logic(name: 'ac_q', width: 16);
      final skipCtx = Logic(name: 'skip_ctx', width: 2);
      final aMode = Logic(name: 'above_ymode', width: 4);
      final lMode = Logic(name: 'left_ymode', width: 4);
      final haveA = Logic(name: 'have_above');
      final haveL = Logic(name: 'have_left');
      final above = Logic(name: 'above', width: bs * 8);
      final left = Logic(name: 'left', width: bs * 8);
      final corner = Logic(name: 'corner', width: 8);

      cl.input('clk').srcConnection! <= clk;
      cl.input('reset').srcConnection! <= reset;
      cl.input('start').srcConnection! <= clStart;
      cl.input('bytes').srcConnection! <= bytes;
      cl.input('dc_q').srcConnection! <= dcQ;
      cl.input('ac_q').srcConnection! <= acQ;
      cl.input('skip_ctx').srcConnection! <= skipCtx;
      cl.input('above_ymode').srcConnection! <= aMode;
      cl.input('left_ymode').srcConnection! <= lMode;

      tx.input('clk').srcConnection! <= clk;
      tx.input('reset').srcConnection! <= reset;
      tx.input('start').srcConnection! <= txStart;
      tx.input('coeffs').srcConnection! <= cl.output('coeffs');
      tx.input('tx_type').srcConnection! <= cl.output('tx_type');

      pred.input('mode').srcConnection! <= cl.output('y_mode');
      // angle_delta: raw 0..6 -> signed (raw - 3).
      pred.input('angle_delta').srcConnection! <=
          (cl.output('angle_delta').zeroExtend(4) - Const(3, width: 4))
              .getRange(0, 4);
      pred.input('have_above').srcConnection! <= haveA;
      pred.input('have_left').srcConnection! <= haveL;
      pred.input('above').srcConnection! <= above;
      pred.input('left').srcConnection! <= left;
      pred.input('corner').srcConnection! <= corner;

      ra.input('pred').srcConnection! <= pred.output('pred');
      ra.input('residual').srcConnection! <= tx.output('residual');
      await ra.build();

      reset.inject(1);
      for (final s in [
        clStart,
        txStart,
        bytes,
        dcQ,
        acQ,
        skipCtx,
        aMode,
        lMode,
        haveA,
        haveL,
        above,
        left,
        corner,
      ]) {
        s.inject(0);
      }
      Simulator.setMaxSimTime(120000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      BigInt packB(List<int> b, int w) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & ((1 << w) - 1)) << (i * w);
        }
        return v;
      }

      final rng = Random(0x8B10);
      var sawCoeffs = false, sawDir = false;
      for (var iter = 0; iter < 10; iter++) {
        final b = [for (var i = 0; i < maxBytes; i++) rng.nextInt(256)];
        rng.nextInt(256); // qi: advances rng, dc/ac quant captured in goldens
        final sc0 = rng.nextInt(3);
        final am = rng.nextInt(13), lm = rng.nextInt(13);
        final av0 = rng.nextInt(2), lv0 = rng.nextInt(2);
        final av = [for (var i = 0; i < bs; i++) rng.nextInt(256)];
        final lf = [for (var i = 0; i < bs; i++) rng.nextInt(256)];
        final cr = rng.nextInt(256);
        final yMode = _yMode[iter];
        final angle = _angle[iter];
        final txType = _txType[iter];
        final want = _recon[iter];
        if (_nonZero[iter]) sawCoeffs = true;
        if (yMode >= 1 && yMode <= 8) sawDir = true;

        bytes.inject(packB(b, 8));
        dcQ.inject(_dcQ[iter]);
        acQ.inject(_acQ[iter]);
        skipCtx.inject(sc0);
        aMode.inject(am);
        lMode.inject(lm);
        haveA.inject(av0);
        haveL.inject(lv0);
        above.inject(packB(av, 8));
        left.inject(packB(lf, 8));
        corner.inject(cr);

        clStart.inject(1);
        await clk.nextPosedge;
        clStart.inject(0);
        var guard = 0;
        while (cl.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 8000) fail('coeff timeout iter=$iter');
        }
        txStart.inject(1);
        await clk.nextPosedge;
        txStart.inject(0);
        guard = 0;
        while (tx.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 128) fail('tx timeout iter=$iter');
        }

        final rvv = ra.output('recon').value.toBigInt();
        final got = [
          for (var p = 0; p < n; p++)
            ((rvv >> (p * 8)) & BigInt.from(0xff)).toInt(),
        ];
        expect(
          got,
          equals(want),
          reason: 'iter=$iter yMode=$yMode angle=$angle txType=$txType',
        );
        await clk.nextPosedge;
      }
      expect(sawCoeffs, isTrue, reason: 'no coded block seen');
      expect(sawDir, isTrue, reason: 'no directional mode seen');
      await Simulator.endSimulation();
    },
  );
}
