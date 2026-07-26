@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/src/media/keyframe_decode_yuv_var.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// End-to-end bytes -> full YUV (8x8 luma + 4x4 U + 4x4 V, 4:2:0) through
// HarborKeyframeDecodeYuvVar. The headline case is the DEPTH-1 NONE 8x8 leaf
// (luma decodes as four TX_4X4 sub-blocks AND the U/V chroma is decoded on the
// same shared window). NONE depth-0 and SPLIT regression cases are also run.
//
// The input byte streams and golden luma/U/V pixels below were captured from the
// SW AV1 reference (libaom-conformant) offline: bD1 is the first depth-1 tx-split
// YUV stream from Random(0x0D1A), bNone the first NONE depth-0 stream from
// Random(0x59A1), bSplit the first SPLIT stream from Random(0x5917).
const _dcv = 61; // dq.dcQlookup[64]
const _acv = 71; // dq.acQlookup[64]

const _bD1 = [
  74,
  248,
  180,
  159,
  191,
  228,
  76,
  55,
  253,
  151,
  2,
  198,
  210,
  157,
  177,
  20,
  154,
  186,
  218,
  209,
  84,
  77,
  20,
  29,
  227,
  253,
  4,
  180,
  224,
  8,
  209,
  203,
  16,
  169,
  14,
  176,
  249,
  137,
  166,
  51,
  44,
  202,
  72,
  154,
  245,
  132,
  65,
  183,
];
const _gD1 = (
  luma: [
    127,
    127,
    127,
    127,
    129,
    127,
    112,
    131,
    127,
    127,
    127,
    127,
    121,
    127,
    116,
    131,
    127,
    127,
    127,
    127,
    133,
    127,
    121,
    131,
    127,
    127,
    127,
    127,
    125,
    127,
    124,
    131,
    127,
    127,
    127,
    127,
    125,
    127,
    124,
    131,
    127,
    127,
    127,
    127,
    125,
    127,
    124,
    131,
    127,
    127,
    127,
    127,
    125,
    127,
    124,
    131,
    127,
    127,
    127,
    127,
    125,
    127,
    124,
    131,
  ],
  u: [
    127,
    127,
    127,
    127,
    122,
    122,
    122,
    122,
    122,
    122,
    122,
    122,
    129,
    129,
    129,
    129,
  ],
  v: [
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
);

const _bNone = [
  36,
  113,
  226,
  112,
  136,
  109,
  37,
  30,
  77,
  3,
  84,
  249,
  91,
  81,
  84,
  182,
  139,
  242,
  60,
  231,
  155,
  84,
  63,
  72,
  195,
  112,
  38,
  104,
  222,
  79,
  163,
  210,
  135,
  253,
  37,
  0,
  98,
  229,
  190,
  163,
  226,
  66,
  234,
  228,
  104,
  191,
  42,
  244,
];
const _gNone = (
  luma: [
    129,
    130,
    129,
    128,
    128,
    128,
    129,
    130,
    130,
    132,
    130,
    128,
    128,
    128,
    129,
    130,
    130,
    131,
    128,
    126,
    126,
    125,
    125,
    126,
    129,
    128,
    123,
    123,
    124,
    122,
    118,
    117,
    129,
    126,
    120,
    120,
    122,
    119,
    114,
    111,
    129,
    127,
    120,
    120,
    122,
    119,
    113,
    111,
    131,
    130,
    123,
    121,
    123,
    120,
    116,
    115,
    132,
    133,
    125,
    122,
    123,
    121,
    119,
    120,
  ],
  u: [
    128,
    128,
    127,
    127,
    128,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
  ],
  v: [
    128,
    128,
    127,
    127,
    128,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
  ],
);

const _bSplit = [
  242,
  176,
  37,
  28,
  98,
  131,
  0,
  33,
  93,
  158,
  11,
  107,
  214,
  234,
  2,
  113,
  199,
  154,
  164,
  113,
  238,
  43,
  230,
  139,
  136,
  112,
  69,
  133,
  118,
  118,
  76,
  23,
  171,
  113,
  89,
  227,
  165,
  2,
  213,
  193,
  121,
  247,
  131,
  142,
  124,
  71,
  137,
  215,
];
const _gSplit = (
  luma: [
    133,
    135,
    112,
    104,
    114,
    102,
    110,
    118,
    135,
    158,
    111,
    83,
    102,
    112,
    110,
    101,
    135,
    144,
    115,
    107,
    100,
    107,
    104,
    112,
    158,
    119,
    113,
    137,
    105,
    97,
    98,
    95,
    128,
    255,
    175,
    0,
    39,
    83,
    93,
    92,
    127,
    198,
    177,
    41,
    99,
    108,
    141,
    153,
    139,
    110,
    158,
    160,
    191,
    165,
    198,
    172,
    76,
    93,
    133,
    195,
    244,
    180,
    214,
    208,
  ],
  u: [
    128,
    128,
    127,
    127,
    128,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
  ],
  v: [
    128,
    128,
    127,
    127,
    128,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
    129,
    128,
    128,
    128,
  ],
);

BigInt _packBytes(List<int> b) {
  var v = BigInt.zero;
  for (var i = 0; i < b.length; i++) {
    v |= BigInt.from(b[i] & 0xff) << (i * 8);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 48;
  const f = 8;
  const qband = 0;

  // Drive one composed stream through the DUT and assert luma/U/V bit-exact.
  Future<void> runCase(
    HarborKeyframeDecodeYuvVar t,
    Logic clk,
    Logic start,
    Logic bytes,
    Logic dcQ,
    Logic acQ,
    List<int> b,
    int dcv,
    int acv,
    ({List<int> luma, List<int> u, List<int> v}) g,
    String tag,
  ) async {
    bytes.inject(_packBytes(b));
    dcQ.inject(dcv);
    acQ.inject(acv);
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);
    var guard = 0;
    while (t.output('done').value.toInt() != 1) {
      await clk.nextPosedge;
      if (++guard > 8000) fail('decode timeout $tag');
    }
    final lv = t.output('luma').value.toBigInt();
    final gotL = [
      for (var p = 0; p < f * f; p++)
        ((lv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotL, equals(g.luma), reason: 'luma $tag');
    final uv = t.output('u').value.toBigInt();
    final gotU = [
      for (var p = 0; p < 16; p++)
        ((uv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotU, equals(g.u), reason: 'U $tag');
    final vv = t.output('v').value.toBigInt();
    final gotV = [
      for (var p = 0; p < 16; p++)
        ((vv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotV, equals(g.v), reason: 'V $tag');
    await clk.nextPosedge;
    await clk.nextPosedge;
  }

  test(
    'HarborKeyframeDecodeYuvVar: bytes -> YUV (depth-1 tx-split + NONE + SPLIT)',
    timeout: const Timeout(Duration(minutes: 120)),
    () async {
      final t = HarborKeyframeDecodeYuvVar(maxBytes: maxBytes, qband: qband);
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
      Simulator.setMaxSimTime(2000000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      const dcv = _dcv, acv = _acv;

      expect(_bD1.isNotEmpty, isTrue, reason: 'no depth-1 YUV stream found');
      expect(_bNone.isNotEmpty, isTrue, reason: 'no NONE YUV stream found');
      expect(_bSplit.isNotEmpty, isTrue, reason: 'no SPLIT YUV stream found');

      // Deliverable first: the depth-1 chroma-on-depth-1 path.
      await runCase(
        t,
        clk,
        start,
        bytes,
        dcQ,
        acQ,
        _bD1,
        dcv,
        acv,
        _gD1,
        'depth1',
      );
      // Regression: NONE depth-0 and SPLIT.
      await runCase(
        t,
        clk,
        start,
        bytes,
        dcQ,
        acQ,
        _bNone,
        dcv,
        acv,
        _gNone,
        'none',
      );
      await runCase(
        t,
        clk,
        start,
        bytes,
        dcQ,
        acQ,
        _bSplit,
        dcv,
        acv,
        _gSplit,
        'split',
      );

      await Simulator.endSimulation();
    },
  );
}
