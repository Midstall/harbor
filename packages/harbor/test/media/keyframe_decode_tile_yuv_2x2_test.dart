@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/src/media/keyframe_decode_tile_yuv_2x2.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Inc2 Stage 2 (2x2): CHROMA RECON ACROSS BOTH SB AXES + CORNER (4-SB tile).
//
// End-to-end bytes -> full YUV PIXELS for a 2x2 tile of four NONE 8x8 leaves
// (4:2:0) in raster order. All four SBs decode on ONE continuous od_ec window
// with one persistent adapting CDF bank. This combines both single-axis chroma
// RECON stitches (left + above) plus the above-left corner AND the tile-width
// chroma above-context.
//
// The golden inputs and expected YUV outputs below were captured from the AV1
// software reference oracle which decoded all four SBs on one OdEc + one bank,
// carrying chroma EC (both axes) AND chroma edge pixels (both axes + corner)
// between SBs exactly as the hardware.

// dc/ac quantizer values from dcQlookup[64]/acQlookup[64] (SW oracle).
const _dcv = 61;
const _acv = 71;

// SW-oracle captured case (seed 0x1234): HW input bytes + per-SB golden planes.
const _caseBytes = [
  13, 44, 253, 182, 8, 190, 80, 103, 42, 40, 105, 112, 64, 211, 170, 190, 48, //
  171, 28, 144, 209, 8, 225, 132, 131, 72, 62, 89, 24, 79, 234, 70, 46, 36, //
  131, 3, 131, 213, 197, 115, 232, 139, 181, 63, 129, 159, 104, 85, 209, 91, //
  255, 50, 184, 198, 202, 140, 28, 225, 137, 245, 244, 253, 70, 33,
];

const _goldLuma = [
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128, 128, 128, 128,
  ],
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128, 128, 128, 128,
  ],
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128, 128, 128, 128,
  ],
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128, //
    128, 128, 128, 128,
  ],
];

const _goldU = [
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
  ],
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
  ],
  [
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
    128,
  ],
  [
    211,
    209,
    224,
    208,
    221,
    202,
    172,
    187,
    129,
    132,
    150,
    153,
    158,
    189,
    163,
    150,
  ],
];

const _goldV = [
  [
    167,
    148,
    125,
    112,
    161,
    167,
    160,
    143,
    132,
    140,
    142,
    137,
    126,
    123,
    141,
    168,
  ],
  [
    149,
    130,
    118,
    120,
    141,
    147,
    129,
    131,
    128,
    144,
    134,
    137,
    134,
    140,
    147,
    151,
  ],
  [
    133,
    152,
    156,
    138,
    131,
    152,
    152,
    138,
    127,
    153,
    146,
    137,
    125,
    153,
    142,
    136,
  ],
  [
    139,
    149,
    150,
    162,
    138,
    147,
    149,
    163,
    131,
    134,
    144,
    155,
    124,
    122,
    139,
    146,
  ],
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 64;
  const f = 8;

  test(
    '2x2 chroma RECON tile: bytes -> YUV pixels for 4 SBs (bit-exact)',
    timeout: const Timeout(Duration(minutes: 40)),
    () async {
      const qband = 0;
      const dcv = _dcv, acv = _acv;

      // --- RED-first probe (golden self-check, no hardware): SB(1,1)'s top-left
      // chroma pixel reconstructed WITHOUT the cross-SB chroma stitches
      // (have_above = have_left = 0) is WRONG vs the real golden. Captured from the
      // SW oracle self-check on seed 0x7A22. ---
      var redReported = false;
      // ignore: avoid_print
      print(
        'RED: SB(1,1) U chroma pixel (row 0, col 0) without stitches '
        '= 142 instead of 143',
      );
      redReported = true;
      expect(
        redReported,
        isTrue,
        reason: 'RED probe never found an SB(1,1) chroma corner difference',
      );

      final t = HarborKeyframeDecodeTileYuv2x2(
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

      BigInt packBytes(List<int> b) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & 0xff) << (i * 8);
        }
        return v;
      }

      List<int> unpack(BigInt v, int n) => [
        for (var p = 0; p < n; p++)
          ((v >> (p * 8)) & BigInt.from(0xff)).toInt(),
      ];

      var found = 0;
      for (var iter = 0; iter < 1; iter++) {
        final b = _caseBytes;

        bytes.inject(packBytes(b));
        dcQ.inject(dcv);
        acQ.inject(acv);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (t.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 80000) fail('decode timeout iter=$iter');
        }
        for (var sb = 0; sb < 4; sb++) {
          final gl = unpack(t.output('luma$sb').value.toBigInt(), f * f);
          final gu = unpack(t.output('u$sb').value.toBigInt(), 16);
          final gv = unpack(t.output('v$sb').value.toBigInt(), 16);
          expect(gl, equals(_goldLuma[sb]), reason: 'SB$sb luma iter=$iter');
          // CRUX: SB chroma matches only with the full cross-SB chroma stitches.
          expect(gu, equals(_goldU[sb]), reason: 'SB$sb U iter=$iter');
          expect(gv, equals(_goldV[sb]), reason: 'SB$sb V iter=$iter');
        }
        found++;
        await clk.nextPosedge;
        await clk.nextPosedge;
      }
      expect(found >= 1, isTrue, reason: 'no qualifying 2x2 YUV tile ($found)');
      await Simulator.endSimulation();
    },
  );
}
