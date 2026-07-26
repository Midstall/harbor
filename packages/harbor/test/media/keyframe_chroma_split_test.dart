@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// CHROMA SPLIT 8x8 SB (rootBsize 3, 4:2:0): the partition splits the 8x8 into
// four 4x4 luma leaves. In 4:2:0 the chroma is decoded ONCE, at the bottom-right
// 4x4 (leaf 3, the only chromaRef block). Goldens below are captured from the
// libaom _decodeBlock + _reconBlock reference (seed 0xC0FFEE, qi 64, qband 0).
// The concrete qualifying byte streams the search kept are embedded alongside.

const _dcv = 61;
const _acv = 71;
const _streams = <List<int>>[
  [
    238,
    125,
    31,
    207,
    40,
    226,
    221,
    117,
    38,
    237,
    197,
    219,
    116,
    253,
    24,
    141,
    64,
    255,
    31,
    169,
    113,
    35,
    180,
    158,
    121,
    41,
    42,
    17,
    101,
    170,
    104,
    110,
    89,
    61,
    194,
    203,
    190,
    213,
    115,
    31,
    99,
    177,
    246,
    191,
    19,
    31,
    239,
    182,
  ],
  [
    254,
    64,
    37,
    50,
    252,
    43,
    47,
    60,
    156,
    58,
    88,
    82,
    98,
    237,
    140,
    194,
    40,
    100,
    170,
    149,
    134,
    82,
    165,
    223,
    33,
    215,
    24,
    95,
    154,
    8,
    76,
    134,
    20,
    104,
    62,
    43,
    143,
    111,
    248,
    230,
    130,
    31,
    53,
    168,
    198,
    185,
    255,
    237,
  ],
  [
    245,
    89,
    2,
    19,
    61,
    116,
    253,
    46,
    239,
    115,
    74,
    194,
    85,
    174,
    24,
    98,
    4,
    80,
    21,
    131,
    89,
    53,
    237,
    8,
    207,
    148,
    114,
    251,
    64,
    206,
    69,
    208,
    153,
    131,
    150,
    240,
    126,
    243,
    105,
    28,
    138,
    239,
    85,
    87,
    6,
    191,
    217,
    29,
  ],
  [
    244,
    215,
    153,
    116,
    232,
    245,
    202,
    88,
    80,
    155,
    169,
    254,
    0,
    0,
    5,
    236,
    195,
    158,
    75,
    73,
    182,
    155,
    126,
    129,
    183,
    215,
    117,
    179,
    65,
    15,
    6,
    212,
    88,
    227,
    125,
    241,
    145,
    156,
    114,
    246,
    13,
    106,
    226,
    205,
    137,
    205,
    107,
    167,
  ],
  [
    238,
    133,
    68,
    109,
    140,
    126,
    108,
    51,
    187,
    42,
    32,
    180,
    63,
    54,
    90,
    255,
    70,
    130,
    7,
    162,
    7,
    12,
    212,
    88,
    183,
    128,
    182,
    247,
    179,
    212,
    175,
    131,
    120,
    121,
    175,
    118,
    171,
    72,
    40,
    251,
    9,
    41,
    80,
    126,
    170,
    77,
    146,
    50,
  ],
  [
    245,
    146,
    29,
    120,
    99,
    138,
    19,
    35,
    235,
    30,
    153,
    220,
    120,
    72,
    211,
    97,
    169,
    133,
    91,
    105,
    12,
    29,
    177,
    151,
    236,
    137,
    97,
    96,
    164,
    170,
    88,
    194,
    149,
    170,
    18,
    165,
    160,
    252,
    249,
    239,
    124,
    207,
    198,
    1,
    75,
    246,
    33,
    191,
  ],
  [
    255,
    187,
    63,
    123,
    31,
    119,
    155,
    0,
    227,
    108,
    185,
    199,
    133,
    111,
    152,
    204,
    34,
    163,
    196,
    145,
    31,
    245,
    97,
    4,
    44,
    130,
    226,
    194,
    54,
    118,
    252,
    120,
    214,
    91,
    252,
    95,
    240,
    85,
    94,
    115,
    216,
    173,
    15,
    227,
    143,
    208,
    112,
    180,
  ],
  [
    239,
    6,
    18,
    167,
    240,
    118,
    109,
    108,
    96,
    181,
    88,
    72,
    246,
    68,
    77,
    6,
    122,
    70,
    171,
    20,
    1,
    191,
    54,
    194,
    91,
    235,
    227,
    106,
    198,
    165,
    60,
    176,
    208,
    153,
    204,
    145,
    155,
    65,
    222,
    143,
    188,
    49,
    194,
    125,
    232,
    183,
    112,
    58,
  ],
];
const _leafCount = [4, 4, 4, 4, 4, 4, 4, 4];
const _chk = [
  2817709673,
  1146894017,
  2924737368,
  3644666464,
  1770668095,
  1368844390,
  1930461148,
  3767656931,
];
const _uvMode = [13, 13, 9, 1, 13, 11, 9, 1];
const _cflAlphaIdx = [16, 0, 0, 0, 34, 0, 0, 0];
const _cflSigns = [2, 2, 0, 0, 4, 0, 0, 0];
const _uCoeffs = <List<int>>[
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [65475, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [
    610,
    65394,
    65465,
    0,
    65252,
    355,
    213,
    65465,
    65465,
    65465,
    0,
    0,
    0,
    0,
    0,
    0,
  ],
  [65414, 0, 0, 0, 0, 0, 0, 142, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
];
const _vCoeffs = <List<int>>[
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [
    65475,
    65394,
    71,
    0,
    65465,
    0,
    65252,
    0,
    71,
    65465,
    65394,
    0,
    71,
    0,
    65465,
    0,
  ],
];
const _lumaCoeffs3 = <List<int>>[
  [61, 142, 0, 65465, 65465, 65465, 0, 0, 0, 0, 0, 0, 0, 142, 0, 0],
  [65292, 355, 65465, 71, 0, 65465, 65465, 0, 0, 65465, 71, 0, 0, 0, 0, 0],
  [65353, 0, 0, 0, 65465, 0, 65465, 0, 65465, 142, 71, 0, 71, 0, 71, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [65475, 65465, 65465, 0, 0, 0, 65465, 0, 0, 65465, 0, 0, 65394, 0, 0, 0],
  [65475, 213, 0, 213, 213, 65465, 142, 142, 0, 65465, 0, 71, 65465, 0, 0, 0],
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  [2257, 64826, 142, 0, 65252, 568, 0, 0, 71, 0, 65394, 0, 65465, 65465, 0, 0],
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 48;

  test(
    'HarborKeyframeModeWalk chroma SPLIT 8x8 matches libaom',
    timeout: const Timeout(Duration(minutes: 30)),
    () async {
      const qband = 0;
      final t = HarborKeyframeModeWalk(
        rootBsize: 3,
        maxBytes: maxBytes,
        coeffPrefix: true,
        txLeaf: true,
        chroma: true,
        qband: qband,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);
      final dcQ = Logic(name: 'dc_q', width: 16);
      final acQ = Logic(name: 'ac_q', width: 16);
      t.input('clk').srcConnection! <= clk;
      t.input('reset').srcConnection! <= reset;
      t.input('start').srcConnection! <= start;
      t.input('bytes').srcConnection! <= bytes;
      t.input('dc_q').srcConnection! <= dcQ;
      t.input('ac_q').srcConnection! <= acQ;
      await t.build();
      reset.inject(1);
      start.inject(0);
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

      List<int> unpack(BigInt v, int n, int w) => [
        for (var i = 0; i < n; i++)
          ((v >> (i * w)) & BigInt.from((1 << w) - 1)).toInt(),
      ];

      const dcv = _dcv, acv = _acv;
      expect(
        _streams.isNotEmpty,
        isTrue,
        reason: 'no SPLIT chroma streams found',
      );
      for (var iter = 0; iter < _streams.length; iter++) {
        final b = _streams[iter];

        bytes.inject(packBytes(b));
        dcQ.inject(dcv);
        acQ.inject(acv);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (t.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 8000) fail('timeout iter=$iter');
        }
        expect(
          t.output('leaf_count').value.toInt(),
          _leafCount[iter],
          reason: 'leaf_count iter=$iter',
        );
        // luma coeffs feed the chk. Compare leaf 3's first 16 directly.
        final lc = unpack(t.output('leaf_coeffs').value.toBigInt(), 4 * 64, 16);
        expect(
          lc.sublist(3 * 64, 3 * 64 + 16),
          _lumaCoeffs3[iter],
          reason: 'leaf3 luma coeffs iter=$iter',
        );
        expect(
          t.output('chk').value.toInt(),
          _chk[iter],
          reason: 'chk iter=$iter',
        );
        expect(
          t.output('leaf_uv_mode').value.toInt(),
          _uvMode[iter],
          reason: 'leaf_uv_mode iter=$iter',
        );
        expect(
          t.output('leaf_cfl_alpha_idx').value.toInt(),
          _cflAlphaIdx[iter],
          reason: 'leaf_cfl_alpha_idx iter=$iter',
        );
        expect(
          t.output('leaf_cfl_signs').value.toInt(),
          _cflSigns[iter],
          reason: 'leaf_cfl_signs iter=$iter',
        );
        final uc = unpack(t.output('leaf_u_coeffs').value.toBigInt(), 16, 16);
        expect(uc, _uCoeffs[iter], reason: 'leaf_u_coeffs iter=$iter');
        final vc = unpack(t.output('leaf_v_coeffs').value.toBigInt(), 16, 16);
        expect(vc, _vCoeffs[iter], reason: 'leaf_v_coeffs iter=$iter');
        await clk.nextPosedge;
      }
      await Simulator.endSimulation();
    },
  );
}
