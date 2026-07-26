@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// PHASE 2 (RECON): HarborKeyframeDecodeHorzVertYuv driving a HORZ (two TX_8X4) or
// VERT (two TX_4X8) 8x8 luma SB in 4:2:0, depth-0 rect tx, decoded to FULL YUV
// (8x8 luma + 4x4 U + 4x4 V) and compared pixel-for-pixel vs the SW golden.
// Golden YUV planes + qualifying input streams captured from the SW oracle
// (goldenHorzVertYuv, seeds 0x7C121 HORZ, 0x7C122 VERT, qi=64 -> dcv=61 acv=71),
// both with non-trivial chroma.
const _dcv = 61;
const _acv = 71;

const _bHorz = [
  155,
  203,
  173,
  227,
  229,
  11,
  228,
  216,
  222,
  137,
  55,
  26,
  94,
  87,
  49,
  205,
  123,
  226,
  144,
  191,
  126,
  15,
  126,
  148,
  204,
  128,
  246,
  148,
  91,
  195,
  127,
  171,
  143,
  31,
  247,
  70,
  49,
  252,
  11,
  135,
  4,
  249,
  99,
  113,
  61,
  200,
  19,
  17,
];
const _horzLuma = [
  141,
  148,
  136,
  144,
  179,
  209,
  218,
  217,
  134,
  134,
  127,
  142,
  174,
  198,
  213,
  224,
  128,
  127,
  130,
  139,
  147,
  153,
  171,
  193,
  147,
  177,
  189,
  179,
  156,
  138,
  137,
  145,
  168,
  142,
  131,
  147,
  153,
  156,
  150,
  149,
  170,
  156,
  125,
  146,
  165,
  157,
  138,
  159,
  160,
  154,
  149,
  161,
  178,
  143,
  143,
  154,
  160,
  165,
  151,
  162,
  176,
  149,
  147,
  153,
];
const _horzU = [
  122,
  131,
  125,
  124,
  122,
  132,
  127,
  126,
  130,
  130,
  131,
  131,
  137,
  128,
  134,
  136,
];
const _horzV = [
  132,
  134,
  146,
  137,
  135,
  135,
  140,
  142,
  121,
  144,
  110,
  136,
  112,
  135,
  106,
  118,
];
const _bVert = [
  232,
  110,
  101,
  198,
  197,
  255,
  207,
  240,
  183,
  73,
  64,
  198,
  246,
  224,
  177,
  171,
  241,
  166,
  0,
  199,
  100,
  46,
  214,
  55,
  58,
  199,
  1,
  230,
  110,
  15,
  174,
  134,
  189,
  211,
  103,
  51,
  244,
  29,
  4,
  216,
  140,
  120,
  140,
  36,
  229,
  1,
  165,
  85,
];
const _vertLuma = [
  129,
  137,
  131,
  131,
  135,
  123,
  123,
  122,
  136,
  151,
  131,
  132,
  136,
  130,
  133,
  135,
  142,
  151,
  124,
  128,
  127,
  133,
  131,
  136,
  134,
  137,
  124,
  127,
  115,
  114,
  116,
  120,
  125,
  125,
  128,
  130,
  120,
  124,
  133,
  125,
  133,
  123,
  128,
  131,
  125,
  132,
  131,
  126,
  138,
  123,
  125,
  126,
  113,
  113,
  110,
  120,
  131,
  122,
  125,
  122,
  131,
  122,
  119,
  114,
];
const _vertU = [
  127,
  126,
  125,
  124,
  127,
  126,
  125,
  124,
  127,
  126,
  125,
  124,
  127,
  126,
  125,
  124,
];
const _vertV = [
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
];

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

  Future<void> runCase(
    HarborKeyframeDecodeHorzVertYuv t,
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
      if (++guard > 12000) fail('decode timeout $tag');
    }
    final lv = t.output('luma').value.toBigInt();
    final gotL = [
      for (var p = 0; p < f * f; p++)
        ((lv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotL, equals(g.luma), reason: 'luma $tag (bytes=$b)');
    final uv = t.output('u').value.toBigInt();
    final gotU = [
      for (var p = 0; p < 16; p++)
        ((uv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotU, equals(g.u), reason: 'U $tag (bytes=$b)');
    final vv = t.output('v').value.toBigInt();
    final gotV = [
      for (var p = 0; p < 16; p++)
        ((vv >> (p * 8)) & BigInt.from(0xff)).toInt(),
    ];
    expect(gotV, equals(g.v), reason: 'V $tag (bytes=$b)');
    await clk.nextPosedge;
    await clk.nextPosedge;
  }

  test(
    'HarborKeyframeDecodeHorzVertYuv: bytes -> YUV (HORZ + VERT)',
    timeout: const Timeout(Duration(minutes: 120)),
    () async {
      final t = HarborKeyframeDecodeHorzVertYuv(
        maxBytes: maxBytes,
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
      // isolated SB: no above/left/corner.
      t.input('have_above').srcConnection! <= Const(0);
      t.input('have_left').srcConnection! <= Const(0);
      t.input('above').srcConnection! <= Const(0, width: f * 8);
      t.input('left').srcConnection! <= Const(0, width: f * 8);
      t.input('above_left').srcConnection! <= Const(0, width: 8);
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

      await runCase(t, clk, start, bytes, dcQ, acQ, _bHorz, dcv, acv, (
        luma: _horzLuma,
        u: _horzU,
        v: _horzV,
      ), 'HORZ');
      await runCase(t, clk, start, bytes, dcQ, acQ, _bVert, dcv, acv, (
        luma: _vertLuma,
        u: _vertU,
        v: _vertV,
      ), 'VERT');

      await Simulator.endSimulation();
    },
  );
}
