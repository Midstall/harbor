@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/intra_recon_walk_seq.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Tiled sequential recon walk: tile-relative availability + external-neighbour
// draw for SB-edge leaves. Case A: SB at tile origin (external inputs unused ->
// same as origin-pinned). Case B: second-column SB whose left edge draws from
// ext_left (the real cross-SB path). Goldens captured from the reference
// per-leaf recon are embedded at the end of the file.

class _Leaf {
  final int miR, miC, log2, mode, txType;
  final List<int> coeffs;
  _Leaf(this.miR, this.miC, this.log2, this.mode, this.txType, this.coeffs);
  int get side => 4 << log2;
}

List<int> _rc(Random rng, int side) {
  final co = List<int>.filled(side * side, 0);
  for (var i = 0; i < side; i++) {
    co[rng.nextInt(side * side)] = rng.nextInt(1024) - 512;
  }
  return co;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const sbSize = 16, maxLeaves = 4, maxLog2 = 2, f = 16;
  const miBits = 3; // bitLength(16/4)=3

  test(
    'HarborIntraReconWalkSeq tiled: origin + second-column SB',
    timeout: const Timeout(Duration(minutes: 15)),
    () async {
      final t = HarborIntraReconWalkSeq(
        sbSize: sbSize,
        maxLeaves: maxLeaves,
        maxLog2: maxLog2,
        tiled: true,
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final leafCount = Logic(name: 'lc', width: t.input('leaf_count').width);
      final positions = Logic(name: 'pos', width: t.input('positions').width);
      final log2sizes = Logic(name: 'l2', width: t.input('log2sizes').width);
      final yModes = Logic(name: 'ym', width: t.input('y_modes').width);
      final txTypes = Logic(name: 'tt', width: t.input('tx_types').width);
      final coeffs = Logic(name: 'co', width: t.input('coeffs').width);
      final sbR = Logic(name: 'sbr', width: 16);
      final sbC = Logic(name: 'sbc', width: 16);
      final tileTop = Logic(name: 'tt2', width: 16);
      final tileLeft = Logic(name: 'tl', width: 16);
      final extAbove = Logic(name: 'ea', width: f * 8);
      final extLeft = Logic(name: 'el', width: f * 8);
      final extCorner = Logic(name: 'ec', width: 8);
      for (final (p, s) in [
        ('clk', clk),
        ('reset', reset),
        ('start', start),
        ('leaf_count', leafCount),
        ('positions', positions),
        ('log2sizes', log2sizes),
        ('y_modes', yModes),
        ('tx_types', txTypes),
        ('coeffs', coeffs),
        ('sb_r', sbR),
        ('sb_c', sbC),
        ('tile_top_mi', tileTop),
        ('tile_left_mi', tileLeft),
        ('ext_above', extAbove),
        ('ext_left', extLeft),
        ('ext_corner', extCorner),
      ]) {
        t.input(p).srcConnection! <= s;
      }
      await t.build();
      for (final l in [
        reset,
        start,
        leafCount,
        positions,
        log2sizes,
        yModes,
        txTypes,
        coeffs,
        sbR,
        sbC,
        tileTop,
        tileLeft,
        extAbove,
        extLeft,
        extCorner,
      ]) {
        l.inject(0);
      }
      reset.inject(1);
      Simulator.setMaxSimTime(400000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      BigInt packB(List<int> b) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & 0xff) << (i * 8);
        }
        return v;
      }

      final rng = Random(0x71710);
      // (label, sbR, sbC, tileTop, tileLeft, useExt)
      final cfgs = [
        ('origin', 0, 0, 0, 0, false),
        ('second-col', 0, 4, 0, 0, true),
      ];
      for (final cfg in cfgs) {
        final label = cfg.$1;
        final sr = cfg.$2, sc = cfg.$3, ttop = cfg.$4, tleft = cfg.$5;
        final useExt = cfg.$6;
        final leaves = [
          for (final p in const [
            [0, 0],
            [0, 2],
            [2, 0],
            [2, 2],
          ])
            _Leaf(p[0], p[1], 1, rng.nextInt(13), 0, _rc(rng, 8)),
        ];
        final ea = [for (var i = 0; i < f; i++) useExt ? rng.nextInt(256) : 0];
        final el = [for (var i = 0; i < f; i++) useExt ? rng.nextInt(256) : 0];
        final ec = useExt ? rng.nextInt(256) : 0;

        var posV = BigInt.zero, l2V = BigInt.zero, ymV = BigInt.zero;
        var ttV = BigInt.zero, coV = BigInt.zero;
        for (var l = 0; l < leaves.length; l++) {
          final lf = leaves[l];
          posV |= BigInt.from(lf.miR | (lf.miC << miBits)) << (l * 2 * miBits);
          l2V |= BigInt.from(lf.log2) << (l * 2);
          ymV |= BigInt.from(lf.mode) << (l * 4);
          ttV |= BigInt.from(lf.txType) << (l * 4);
          for (var i = 0; i < lf.side * lf.side; i++) {
            coV |= BigInt.from(lf.coeffs[i] & 0xffff) << ((l * 256 + i) * 16);
          }
        }
        leafCount.inject(leaves.length);
        positions.inject(posV);
        log2sizes.inject(l2V);
        yModes.inject(ymV);
        txTypes.inject(ttV);
        coeffs.inject(coV);
        sbR.inject(sr);
        sbC.inject(sc);
        tileTop.inject(ttop);
        tileLeft.inject(tleft);
        extAbove.inject(packB(ea));
        extLeft.inject(packB(el));
        extCorner.inject(ec);
        start.inject(1);
        await clk.nextPosedge;
        start.inject(0);
        var guard = 0;
        while (t.output('done').value.toInt() != 1) {
          await clk.nextPosedge;
          if (++guard > 20000) fail('timeout $label');
        }
        final fv = t.output('frame').value.toBigInt();
        final got = [
          for (var p = 0; p < f * f; p++)
            ((fv >> (p * 8)) & BigInt.from(0xff)).toInt(),
        ];
        final want = _goldenWalkSeqTiled[label]![0];
        expect(got, equals(want), reason: label);
        print('$label OK');
        await clk.nextPosedge;
        await clk.nextPosedge;
      }
      await Simulator.endSimulation();
    },
  );
}

const _goldenWalkSeqTiled = <String, List<List<int>>>{
  'origin': [
    [
      112,
      137,
      133,
      123,
      132,
      128,
      122,
      136,
      133,
      140,
      137,
      139,
      138,
      129,
      140,
      138,
      101,
      149,
      149,
      117,
      118,
      129,
      129,
      131,
      137,
      130,
      147,
      138,
      127,
      146,
      124,
      144,
      128,
      134,
      127,
      128,
      134,
      119,
      115,
      137,
      130,
      147,
      132,
      138,
      146,
      116,
      152,
      133,
      131,
      139,
      130,
      119,
      125,
      131,
      127,
      121,
      137,
      129,
      146,
      140,
      123,
      150,
      121,
      145,
      132,
      132,
      134,
      129,
      120,
      123,
      129,
      124,
      132,
      142,
      137,
      135,
      145,
      119,
      148,
      135,
      148,
      113,
      116,
      141,
      133,
      119,
      124,
      129,
      135,
      136,
      140,
      142,
      127,
      142,
      128,
      142,
      139,
      119,
      120,
      126,
      127,
      141,
      141,
      111,
      134,
      137,
      141,
      135,
      139,
      128,
      140,
      138,
      141,
      108,
      115,
      141,
      135,
      126,
      130,
      127,
      134,
      138,
      139,
      139,
      133,
      135,
      135,
      140,
      134,
      123,
      119,
      133,
      142,
      119,
      130,
      128,
      153,
      142,
      155,
      119,
      120,
      158,
      138,
      145,
      158,
      130,
      96,
      102,
      142,
      147,
      132,
      128,
      129,
      131,
      138,
      122,
      127,
      154,
      147,
      143,
      127,
      139,
      139,
      129,
      129,
      132,
      114,
      132,
      120,
      136,
      128,
      134,
      138,
      140,
      146,
      125,
      145,
      157,
      102,
      109,
      116,
      137,
      148,
      132,
      134,
      156,
      134,
      153,
      151,
      128,
      137,
      106,
      139,
      140,
      137,
      130,
      112,
      162,
      117,
      113,
      115,
      137,
      121,
      156,
      164,
      144,
      160,
      138,
      136,
      145,
      144,
      137,
      74,
      135,
      123,
      162,
      154,
      151,
      141,
      162,
      168,
      154,
      160,
      156,
      138,
      167,
      96,
      166,
      107,
      130,
      146,
      114,
      168,
      142,
      144,
      142,
      140,
      134,
      120,
      135,
      136,
      146,
      135,
      162,
      89,
      134,
      109,
      152,
      161,
      120,
      135,
      130,
      137,
      151,
      134,
      169,
    ],
  ],
  'second-col': [
    [
      137,
      113,
      129,
      137,
      157,
      126,
      141,
      157,
      157,
      185,
      153,
      164,
      168,
      164,
      153,
      166,
      149,
      145,
      120,
      159,
      128,
      141,
      116,
      138,
      141,
      133,
      169,
      118,
      171,
      149,
      138,
      158,
      131,
      138,
      142,
      138,
      140,
      128,
      133,
      135,
      121,
      153,
      127,
      136,
      154,
      138,
      142,
      146,
      174,
      127,
      153,
      124,
      147,
      124,
      139,
      125,
      117,
      143,
      128,
      140,
      141,
      158,
      127,
      155,
      70,
      170,
      114,
      147,
      124,
      152,
      135,
      141,
      146,
      151,
      167,
      131,
      178,
      149,
      152,
      161,
      31,
      64,
      154,
      129,
      138,
      145,
      146,
      157,
      159,
      183,
      161,
      155,
      182,
      153,
      163,
      163,
      114,
      34,
      83,
      156,
      148,
      118,
      137,
      136,
      137,
      151,
      147,
      149,
      144,
      176,
      125,
      166,
      124,
      100,
      34,
      97,
      165,
      119,
      117,
      143,
      133,
      152,
      145,
      128,
      167,
      134,
      147,
      147,
      51,
      18,
      11,
      32,
      25,
      0,
      0,
      18,
      141,
      173,
      125,
      148,
      176,
      148,
      151,
      130,
      27,
      32,
      39,
      45,
      48,
      46,
      42,
      39,
      142,
      170,
      158,
      130,
      160,
      115,
      154,
      163,
      188,
      193,
      190,
      181,
      184,
      199,
      207,
      204,
      127,
      174,
      157,
      137,
      186,
      97,
      170,
      144,
      255,
      255,
      255,
      255,
      255,
      242,
      236,
      242,
      144,
      157,
      146,
      130,
      194,
      139,
      156,
      126,
      101,
      91,
      91,
      98,
      94,
      80,
      75,
      81,
      169,
      143,
      156,
      117,
      153,
      173,
      125,
      156,
      177,
      186,
      185,
      175,
      180,
      201,
      210,
      205,
      133,
      171,
      153,
      151,
      150,
      135,
      139,
      160,
      199,
      225,
      235,
      225,
      232,
      252,
      251,
      231,
      119,
      175,
      152,
      157,
      177,
      117,
      154,
      142,
      163,
      170,
      166,
      153,
      151,
      160,
      161,
      153,
      172,
      127,
      177,
      100,
      171,
      164,
      129,
      152,
    ],
  ],
};
