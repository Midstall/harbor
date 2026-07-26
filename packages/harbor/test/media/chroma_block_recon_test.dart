@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// intra_mode_to_tx_type (libaom). uv tx_type for non-CfL intra.
const _intraModeToTxType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];

// Goldens captured from the SW reference chroma 4x4 recon pipeline
// (coded bytes -> coeffs -> inverse transform + intra predict -> recon).
const _dcv = [
  113,
  559,
  988,
  23,
  1022,
  48,
  26,
  202,
  13,
  99,
  269,
  28,
  67,
  288,
  192,
  335,
  247,
  626,
  220,
  101,
  48,
  27,
  56,
  354,
  843,
  379,
  505,
  62,
  217,
  253,
  21,
  429,
  364,
  123,
  72,
  233,
  253,
  640,
  569,
  31,
  114,
  389,
  50,
  79,
  61,
  237,
  78,
  161,
  214,
  150,
];
const _acv = [
  138,
  1007,
  1567,
  26,
  1597,
  55,
  30,
  270,
  15,
  120,
  387,
  32,
  79,
  424,
  255,
  520,
  347,
  1129,
  300,
  122,
  56,
  31,
  65,
  560,
  1423,
  615,
  898,
  73,
  295,
  359,
  24,
  729,
  582,
  152,
  85,
  323,
  359,
  1151,
  1026,
  35,
  140,
  639,
  58,
  94,
  71,
  329,
  92,
  207,
  290,
  191,
];
const _coded = [
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  false,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
  true,
];
const _want = [
  [
    250,
    255,
    247,
    255,
    248,
    255,
    255,
    255,
    246,
    254,
    255,
    249,
    244,
    251,
    255,
    245,
  ],
  [255, 255, 255, 255, 0, 0, 0, 0, 64, 255, 179, 255, 0, 200, 0, 1],
  [118, 152, 137, 64, 109, 173, 146, 9, 104, 189, 152, 0, 100, 197, 155, 0],
  [
    130,
    126,
    130,
    128,
    131,
    128,
    132,
    130,
    135,
    134,
    138,
    135,
    135,
    133,
    137,
    132,
  ],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 14],
  [
    125,
    51,
    161,
    120,
    132,
    96,
    163,
    139,
    148,
    129,
    167,
    152,
    226,
    183,
    193,
    175,
  ],
  [
    198,
    197,
    196,
    197,
    198,
    196,
    195,
    196,
    198,
    195,
    194,
    195,
    198,
    194,
    193,
    194,
  ],
  [114, 235, 16, 166, 99, 215, 0, 152, 72, 189, 0, 150, 67, 189, 0, 170],
  [29, 29, 29, 30, 106, 106, 106, 107, 180, 180, 179, 179, 9, 9, 8, 7],
  [
    200,
    212,
    190,
    174,
    188,
    184,
    206,
    213,
    178,
    180,
    194,
    184,
    159,
    172,
    191,
    231,
  ],
  [34, 197, 255, 2, 33, 206, 255, 1, 32, 212, 255, 0, 31, 215, 255, 0],
  [
    122,
    125,
    119,
    122,
    121,
    121,
    122,
    123,
    121,
    121,
    122,
    123,
    122,
    125,
    119,
    122,
  ],
  [
    163,
    131,
    136,
    125,
    184,
    156,
    131,
    142,
    196,
    148,
    128,
    126,
    171,
    156,
    127,
    69,
  ],
  [
    106,
    116,
    130,
    140,
    106,
    116,
    130,
    140,
    106,
    116,
    130,
    140,
    106,
    116,
    130,
    140,
  ],
  [246, 205, 231, 51, 248, 209, 237, 58, 249, 212, 241, 62, 250, 214, 243, 65],
  [
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
    149,
  ],
  [40, 59, 28, 72, 196, 150, 169, 255, 62, 29, 19, 74, 141, 71, 87, 127],
  [255, 244, 119, 253, 148, 3, 0, 123, 196, 34, 11, 215, 255, 0, 0, 66],
  [35, 21, 18, 46, 150, 146, 124, 114, 188, 197, 180, 148, 15, 34, 41, 15],
  [64, 37, 39, 61, 54, 74, 49, 36, 43, 111, 75, 61, 84, 52, 68, 97],
  [
    184,
    90,
    198,
    161,
    183,
    125,
    189,
    171,
    180,
    147,
    186,
    177,
    177,
    155,
    187,
    178,
  ],
  [
    159,
    177,
    176,
    160,
    104,
    149,
    172,
    151,
    196,
    196,
    211,
    192,
    242,
    218,
    229,
    225,
  ],
  [25, 117, 46, 133, 21, 120, 43, 103, 7, 127, 57, 98, 7, 128, 57, 89],
  [
    224,
    226,
    228,
    229,
    130,
    134,
    137,
    138,
    213,
    218,
    222,
    224,
    255,
    255,
    255,
    255,
  ],
  [
    204,
    225,
    190,
    147,
    204,
    225,
    190,
    147,
    204,
    225,
    190,
    147,
    204,
    225,
    190,
    147,
  ],
  [248, 207, 171, 150, 231, 161, 118, 114, 214, 119, 66, 75, 221, 126, 79, 100],
  [204, 69, 220, 255, 68, 70, 100, 0, 255, 90, 90, 255, 0, 17, 0, 36],
  [
    132,
    131,
    130,
    129,
    132,
    131,
    130,
    129,
    132,
    131,
    130,
    129,
    132,
    131,
    130,
    129,
  ],
  [
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
    107,
  ],
  [
    224,
    243,
    255,
    255,
    234,
    249,
    255,
    255,
    120,
    130,
    151,
    168,
    224,
    231,
    249,
    255,
  ],
  [
    130,
    136,
    136,
    138,
    128,
    126,
    120,
    119,
    117,
    123,
    126,
    126,
    130,
    129,
    129,
    126,
  ],
  [156, 173, 112, 9, 241, 208, 191, 199, 86, 0, 0, 0, 88, 132, 139, 106],
  [132, 125, 131, 147, 100, 110, 101, 78, 106, 141, 110, 33, 147, 198, 153, 37],
  [21, 90, 137, 255, 18, 72, 164, 255, 26, 83, 149, 255, 29, 116, 174, 255],
  [
    127,
    134,
    137,
    129,
    127,
    130,
    134,
    134,
    142,
    140,
    131,
    125,
    141,
    136,
    129,
    131,
  ],
  [
    99,
    107,
    118,
    126,
    121,
    113,
    102,
    95,
    143,
    135,
    124,
    116,
    152,
    160,
    171,
    178,
  ],
  [60, 84, 145, 182, 96, 84, 89, 146, 105, 131, 91, 137, 82, 196, 149, 160],
  [82, 122, 129, 47, 42, 82, 89, 7, 154, 194, 201, 119, 0, 0, 3, 0],
  [0, 0, 129, 194, 9, 0, 99, 126, 180, 172, 208, 248, 29, 100, 88, 230],
  [33, 31, 29, 30, 30, 35, 29, 27, 29, 39, 26, 26, 30, 39, 21, 29],
  [
    245,
    240,
    204,
    238,
    212,
    201,
    225,
    221,
    143,
    179,
    199,
    195,
    137,
    153,
    155,
    154,
  ],
  [84, 38, 113, 255, 1, 0, 85, 255, 129, 0, 0, 83, 72, 110, 123, 74],
  [
    128,
    127,
    127,
    126,
    129,
    128,
    126,
    125,
    130,
    128,
    126,
    124,
    130,
    128,
    126,
    124,
  ],
  [86, 85, 83, 81, 87, 84, 79, 76, 88, 82, 74, 69, 89, 81, 71, 63],
  [195, 81, 104, 58, 220, 121, 127, 84, 247, 150, 121, 102, 220, 153, 103, 117],
  [246, 255, 255, 255, 175, 188, 255, 255, 62, 143, 153, 127, 123, 38, 0, 0],
  [
    101,
    102,
    100,
    107,
    112,
    109,
    115,
    98,
    113,
    115,
    109,
    127,
    100,
    100,
    102,
    95,
  ],
  [50, 21, 39, 17, 52, 16, 36, 5, 61, 135, 131, 116, 59, 76, 65, 52],
  [
    245,
    248,
    252,
    255,
    243,
    249,
    255,
    255,
    241,
    249,
    255,
    255,
    240,
    249,
    255,
    255,
  ],
  [121, 133, 138, 124, 50, 87, 106, 97, 139, 127, 120, 118, 88, 88, 91, 107],
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const bs = 4, n = 16, maxBytes = 32;
  const uvModes = [0, 1, 2, 9, 12]; // DC, V, H, SMOOTH, PAETH (non-directional)

  test('chroma 4x4 intra block: coded bytes + neighbours -> pixels', () async {
    final cl = HarborCoeffLevels(maxBytes: maxBytes, txSize: 0, planeType: 1);
    final tx = HarborInvTxfm(txSize: 0, txType: 0, runtimeTxType: true);
    final pred = HarborIntraPredAvail(bs: bs);
    final ra = HarborReconAdd(n: n);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final clStart = Logic(name: 'cl_start');
    final txStart = Logic(name: 'tx_start');
    final bytes = Logic(name: 'bytes', width: maxBytes * 8);
    final dcQ = Logic(name: 'dc_q', width: 16);
    final acQ = Logic(name: 'ac_q', width: 16);
    final txType = Logic(name: 'tx_type', width: 4);
    final mode = Logic(name: 'mode', width: 4);
    final haveA = Logic(name: 'have_above');
    final haveL = Logic(name: 'have_left');
    final above = Logic(name: 'above', width: bs * 8);
    final left = Logic(name: 'left', width: bs * 8);
    final corner = Logic(name: 'above_left', width: 8);

    cl.input('clk').srcConnection! <= clk;
    cl.input('reset').srcConnection! <= reset;
    cl.input('start').srcConnection! <= clStart;
    cl.input('bytes').srcConnection! <= bytes;
    cl.input('dc_q').srcConnection! <= dcQ;
    cl.input('ac_q').srcConnection! <= acQ;

    tx.input('clk').srcConnection! <= clk;
    tx.input('reset').srcConnection! <= reset;
    tx.input('start').srcConnection! <= txStart;
    tx.input('coeffs').srcConnection! <= cl.output('coeffs');
    tx.input('tx_type').srcConnection! <= txType;

    pred.input('mode').srcConnection! <= mode;
    pred.input('have_above').srcConnection! <= haveA;
    pred.input('have_left').srcConnection! <= haveL;
    pred.input('above').srcConnection! <= above;
    pred.input('left').srcConnection! <= left;
    pred.input('above_left').srcConnection! <= corner;

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
      txType,
      mode,
      haveA,
      haveL,
      above,
      left,
      corner,
    ]) {
      s.inject(0);
    }
    Simulator.setMaxSimTime(60000000);
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

    final rng = Random(0xC47A);
    var sawCoeffs = false;
    for (var iter = 0; iter < 50; iter++) {
      final b = [for (var i = 0; i < maxBytes; i++) rng.nextInt(256)];
      rng.nextInt(256); // advance rng (dequant index)
      final m = uvModes[rng.nextInt(uvModes.length)];
      final av0 = rng.nextInt(2), lv0 = rng.nextInt(2);
      final av = [for (var i = 0; i < bs; i++) rng.nextInt(256)];
      final lf = [for (var i = 0; i < bs; i++) rng.nextInt(256)];
      final cr = rng.nextInt(256);
      final dcv = _dcv[iter], acv = _acv[iter];
      final tt = _intraModeToTxType[m];
      if (_coded[iter]) sawCoeffs = true;

      bytes.inject(packB(b, 8));
      dcQ.inject(dcv);
      acQ.inject(acv);
      txType.inject(tt);
      mode.inject(m);
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
        if (++guard > 4000) fail('coeff timeout iter=$iter');
      }
      txStart.inject(1);
      await clk.nextPosedge;
      txStart.inject(0);
      guard = 0;
      while (tx.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 64) fail('tx timeout iter=$iter');
      }

      final rvv = ra.output('recon').value.toBigInt();
      final got = [
        for (var p = 0; p < n; p++)
          ((rvv >> (p * 8)) & BigInt.from(0xff)).toInt(),
      ];
      final want = _want[iter];
      expect(got, equals(want), reason: 'iter=$iter mode=$m tt=$tt');
      await clk.nextPosedge;
    }
    expect(sawCoeffs, isTrue, reason: 'no coded chroma block seen');
    await Simulator.endSimulation();
  });
}
