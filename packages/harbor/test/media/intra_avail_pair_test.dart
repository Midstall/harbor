@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/src/media/intra_recon_walk.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// INCREMENT 0 of the multi-superblock tile walk: prove TILE-RELATIVE intra
// availability with a horizontal pair of 8x8 superblocks.
//
//   * Block A sits at the tile-left edge (sb_c == tile_left_mi) so its left
//     neighbour is UNAVAILABLE (haveL == false), matching the SW rule
//     haveLeft = px > tileLeftPx.
//   * Block B sits immediately to the right of A. With tile-relative
//     availability its left neighbour IS available, and the left reference is
//     A's reconstructed RIGHT COLUMN, fed in via the external ext_left port.
//
// Both blocks are reconstructed by HarborIntraReconWalk and compared pixel-for-
// pixel against a SW-reference golden that genuinely reconstructs the same two blocks
// at the same absolute positions (so the golden B has A available to its left).

const _intraSet = [9, 0, 10, 11, 3, 1, 2]; // DCT/ADST/IDTX 1D, no FLIPADST

// Goldens captured from the SW reference recon (predict + inverse-transform +
// add + clip) of the two 8x8 blocks, at the exact inputs used below.
const _goldA = [
  78,
  83,
  87,
  92,
  97,
  101,
  106,
  110,
  115,
  120,
  124,
  129,
  134,
  138,
  143,
  147,
  152,
  157,
  161,
  166,
  171,
  175,
  80,
  84,
  89,
  94,
  98,
  103,
  108,
  112,
  117,
  121,
  126,
  131,
  135,
  140,
  145,
  149,
  154,
  158,
  163,
  168,
  172,
  177,
  82,
  86,
  91,
  95,
  100,
  105,
  109,
  114,
  119,
  123,
  128,
  132,
  137,
  142,
  146,
  151,
  156,
  160,
  165,
  169,
];
const _goldB = [
  80,
  119,
  101,
  96,
  106,
  114,
  111,
  102,
  113,
  121,
  132,
  135,
  120,
  109,
  110,
  119,
  10,
  67,
  92,
  106,
  99,
  94,
  98,
  108,
  43,
  177,
  87,
  118,
  100,
  124,
  110,
  105,
  195,
  168,
  135,
  122,
  125,
  128,
  123,
  113,
  77,
  68,
  108,
  110,
  107,
  97,
  104,
  111,
  102,
  98,
  128,
  125,
  116,
  104,
  108,
  116,
  160,
  192,
  131,
  130,
  123,
  132,
  121,
  113,
];
const _goldBLeftUnavail = [
  99,
  138,
  119,
  114,
  124,
  131,
  128,
  119,
  95,
  112,
  129,
  138,
  127,
  119,
  122,
  131,
  55,
  106,
  125,
  135,
  124,
  116,
  119,
  128,
  51,
  188,
  99,
  131,
  115,
  139,
  125,
  121,
  166,
  150,
  126,
  120,
  129,
  136,
  133,
  124,
  111,
  99,
  135,
  134,
  129,
  117,
  123,
  130,
  99,
  100,
  133,
  134,
  128,
  117,
  122,
  130,
  120,
  166,
  115,
  124,
  124,
  137,
  129,
  123,
];
const _goldLeftUnavail = [
  99,
  138,
  119,
  114,
  124,
  131,
  128,
  119,
  95,
  112,
  129,
  138,
  127,
  119,
  122,
  131,
  55,
  106,
  125,
  135,
  124,
  116,
  119,
  128,
  51,
  188,
  99,
  131,
  115,
  139,
  125,
  121,
  166,
  150,
  126,
  120,
  129,
  136,
  133,
  124,
  111,
  99,
  135,
  134,
  129,
  117,
  123,
  130,
  99,
  100,
  133,
  134,
  128,
  117,
  122,
  130,
  120,
  166,
  115,
  124,
  124,
  137,
  129,
  123,
];
const _goldLeftAvail = [
  0,
  39,
  21,
  16,
  26,
  34,
  31,
  22,
  1,
  17,
  34,
  42,
  30,
  23,
  26,
  35,
  0,
  15,
  33,
  41,
  29,
  21,
  23,
  32,
  0,
  101,
  10,
  39,
  21,
  45,
  30,
  26,
  87,
  66,
  39,
  30,
  37,
  43,
  39,
  30,
  37,
  19,
  51,
  46,
  38,
  25,
  30,
  36,
  30,
  24,
  52,
  48,
  39,
  26,
  29,
  37,
  56,
  94,
  37,
  40,
  36,
  47,
  37,
  30,
];

// Drive HarborIntraReconWalk for a single 8x8 leaf at SB position
// (sb_r, sb_c) inside a tile rooted at (tile_top_mi, tile_left_mi), with the
// given external neighbours, and return the 8x8 reconstructed plane.
Future<List<int>> _dutRecon8(
  HarborIntraReconWalk t,
  Map<String, Logic> p, {
  required Logic clk,
  required Logic start,
  required int sbR,
  required int sbC,
  required int tileTopMi,
  required int tileLeftMi,
  required int mode,
  required int txType,
  required List<int> coeffs,
  required List<int> extAbove,
  required List<int> extLeft,
  required int extCorner,
}) async {
  // one leaf at plane origin (0,0), log2size 1 (8x8).
  p['leaf_count']!.inject(1);
  p['positions']!.inject(0); // miR=0, miC=0
  p['log2sizes']!.inject(1);
  p['y_modes']!.inject(mode);
  p['tx_types']!.inject(txType);
  var coV = BigInt.zero;
  for (var i = 0; i < 64; i++) {
    coV |= BigInt.from(coeffs[i] & 0xffff) << (i * 16);
  }
  p['coeffs']!.inject(coV);
  p['sb_r']!.inject(sbR);
  p['sb_c']!.inject(sbC);
  p['tile_top_mi']!.inject(tileTopMi);
  p['tile_left_mi']!.inject(tileLeftMi);
  var aV = BigInt.zero, lV = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    aV |= BigInt.from(extAbove[i] & 0xff) << (i * 8);
    lV |= BigInt.from(extLeft[i] & 0xff) << (i * 8);
  }
  p['ext_above']!.inject(aV);
  p['ext_left']!.inject(lV);
  p['ext_corner']!.inject(extCorner & 0xff);

  start.inject(1);
  await clk.nextPosedge;
  start.inject(0);
  var guard = 0;
  while (t.output('done').value.toInt() != 1) {
    await clk.nextPosedge;
    if (++guard > 2000) fail('DUT timeout');
  }
  final fv = t.output('frame').value.toBigInt();
  final got = [
    for (var k = 0; k < 64; k++) ((fv >> (k * 8)) & BigInt.from(0xff)).toInt(),
  ];
  await clk.nextPosedge; // deassert done before next start
  return got;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('tile-relative LEFT-neighbour propagation across an 8x8 pair', () async {
    final t = HarborIntraReconWalk(sbSize: 8, maxLeaves: 1, tiled: true);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final p = {
      'leaf_count': Logic(
        name: 'leaf_count',
        width: t.input('leaf_count').width,
      ),
      'positions': Logic(name: 'positions', width: t.input('positions').width),
      'log2sizes': Logic(name: 'log2sizes', width: t.input('log2sizes').width),
      'y_modes': Logic(name: 'y_modes', width: t.input('y_modes').width),
      'tx_types': Logic(name: 'tx_types', width: t.input('tx_types').width),
      'coeffs': Logic(name: 'coeffs', width: t.input('coeffs').width),
      'sb_r': Logic(name: 'sb_r', width: t.input('sb_r').width),
      'sb_c': Logic(name: 'sb_c', width: t.input('sb_c').width),
      'tile_top_mi': Logic(
        name: 'tile_top_mi',
        width: t.input('tile_top_mi').width,
      ),
      'tile_left_mi': Logic(
        name: 'tile_left_mi',
        width: t.input('tile_left_mi').width,
      ),
      'ext_above': Logic(name: 'ext_above', width: t.input('ext_above').width),
      'ext_left': Logic(name: 'ext_left', width: t.input('ext_left').width),
      'ext_corner': Logic(
        name: 'ext_corner',
        width: t.input('ext_corner').width,
      ),
    };

    t.input('clk').srcConnection! <= clk;
    t.input('reset').srcConnection! <= reset;
    t.input('start').srcConnection! <= start;
    for (final e in p.entries) {
      t.input(e.key).srcConnection! <= e.value;
    }
    await t.build();

    reset.inject(1);
    start.inject(0);
    for (final v in p.values) {
      v.inject(0);
    }
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Tile rooted at MI (0, 0). SB A at (sb_r=0, sb_c=0) is the tile-left SB.
    // SB B at (sb_r=0, sb_c=2) is the next SB (8px = 2 MI to the right).
    const tileTopMi = 0, tileLeftMi = 0;

    // Block A: tile-left, so left unavailable. Use a directional mode driven by
    // the left column so block B is sensitive to A's right column.
    const modeA = 0; // DC
    final txTypeA = _intraSet[0];
    final coeffsA = [for (var i = 0; i < 64; i++) ((i * 37) % 800) - 400];

    final goldA = _goldA;

    final dutA = await _dutRecon8(
      t,
      p,
      clk: clk,
      start: start,
      sbR: 0,
      sbC: 0,
      tileTopMi: tileTopMi,
      tileLeftMi: tileLeftMi,
      mode: modeA,
      txType: txTypeA,
      coeffs: coeffsA,
      extAbove: List<int>.filled(8, 0),
      extLeft: List<int>.filled(8, 0),
      extCorner: 0,
    );
    expect(dutA, equals(goldA), reason: 'block A (tile-left edge) mismatch');

    // A's reconstructed RIGHT COLUMN (pixels at local col 7) feeds B's left ref.
    final aRightCol = [for (var r = 0; r < 8; r++) goldA[r * 8 + 7]];

    // Block B: mode that reads the left column. SMOOTH_H_PRED (mode 11) blends
    // the left column horizontally, so a wrong (unavailable) left changes pixels.
    const modeB = 11; // SMOOTH_H_PRED
    final txTypeB = _intraSet[1];
    final coeffsB = [for (var i = 0; i < 64; i++) ((i * 17) % 600) - 300];

    final goldB = _goldB;

    final goldBLeftUnavail = _goldBLeftUnavail;
    // Sanity: the two goldens differ, so the test genuinely exercises the path.
    expect(
      goldB,
      isNot(equals(goldBLeftUnavail)),
      reason: 'mode/coeffs must make left-availability observable on B',
    );

    final dutB = await _dutRecon8(
      t,
      p,
      clk: clk,
      start: start,
      sbR: 0,
      sbC: 2,
      tileTopMi: tileTopMi,
      tileLeftMi: tileLeftMi,
      mode: modeB,
      txType: txTypeB,
      coeffs: coeffsB,
      extAbove: List<int>.filled(8, 0),
      extLeft: aRightCol,
      extCorner: 0,
    );

    // The RED-witness pixel: with the availability bug, DUT B == left-unavailable
    // golden, which differs from the correct goldB. Report the first such pixel.
    var redIdx = -1;
    for (var k = 0; k < 64; k++) {
      if (goldB[k] != goldBLeftUnavail[k]) {
        redIdx = k;
        break;
      }
    }
    expect(redIdx >= 0, isTrue);
    // ignore: avoid_print
    print(
      'RED witness: block B pixel[$redIdx] would be '
      '${goldBLeftUnavail[redIdx]} (left UNAVAILABLE) instead of '
      '${goldB[redIdx]} (left available, from A right col)',
    );

    expect(
      dutB,
      equals(goldB),
      reason: 'block B must consume A right column as its LEFT reference',
    );

    await Simulator.endSimulation();
  });

  test('tile-left column: haveL is false at the tile-left edge', () async {
    // A dedicated assertion that a block whose plane-absolute col == tileLeftPx
    // sees left UNAVAILABLE. We prove it by reconstructing the SAME block with a
    // NON-zero ext_left and showing the DUT ignores it (haveL false), matching
    // the SW left-unavailable golden, NOT the left-available one.
    final t = HarborIntraReconWalk(sbSize: 8, maxLeaves: 1, tiled: true);
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final p = {
      for (final k in [
        'leaf_count',
        'positions',
        'log2sizes',
        'y_modes',
        'tx_types',
        'coeffs',
        'sb_r',
        'sb_c',
        'tile_top_mi',
        'tile_left_mi',
        'ext_above',
        'ext_left',
        'ext_corner',
      ])
        k: Logic(name: k, width: t.input(k).width),
    };
    t.input('clk').srcConnection! <= clk;
    t.input('reset').srcConnection! <= reset;
    t.input('start').srcConnection! <= start;
    for (final e in p.entries) {
      t.input(e.key).srcConnection! <= e.value;
    }
    await t.build();

    reset.inject(1);
    start.inject(0);
    for (final v in p.values) {
      v.inject(0);
    }
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    const mode = 11; // SMOOTH_H, left-sensitive
    final txType = _intraSet[1];
    final coeffs = [for (var i = 0; i < 64; i++) ((i * 17) % 600) - 300];
    final bogusLeft = [for (var r = 0; r < 8; r++) 30 + r * 5];

    // Tile rooted so the SB IS the tile-left SB: tile_left_mi == sb_c.
    final got = await _dutRecon8(
      t,
      p,
      clk: clk,
      start: start,
      sbR: 0,
      sbC: 4, // SB at MI col 4
      tileTopMi: 0,
      tileLeftMi: 4, // tile left == this SB col -> haveL false
      mode: mode,
      txType: txType,
      coeffs: coeffs,
      extAbove: List<int>.filled(8, 0),
      extLeft: bogusLeft, // present, but must be ignored
      extCorner: 99,
    );

    final goldLeftUnavail = _goldLeftUnavail;
    final goldLeftAvail = _goldLeftAvail;
    expect(goldLeftUnavail, isNot(equals(goldLeftAvail)));
    expect(
      got,
      equals(goldLeftUnavail),
      reason: 'at the tile-left column haveL must be false (left ignored)',
    );
    expect(got, isNot(equals(goldLeftAvail)));

    await Simulator.endSimulation();
  });
}
