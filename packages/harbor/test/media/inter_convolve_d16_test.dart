import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart' show HarborCompoundBlend;
import 'package:harbor/src/media/inter_convolve_d16.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Filter tables, copied EXACTLY from lib/src/media/inter_convolve.dart
// (regular / smooth / sharp). The golden below mirrors tile_decode.dart
// `_compoundConvolve` for bd8, the !doAverage CONV_BUF res producer.
const List<List<int>> _regular = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, -6, 126, 8, -2, 0, 0],
  [0, 2, -10, 122, 18, -4, 0, 0],
  [0, 2, -12, 116, 28, -8, 2, 0],
  [0, 2, -14, 110, 38, -10, 2, 0],
  [0, 2, -14, 102, 48, -12, 2, 0],
  [0, 2, -16, 94, 58, -12, 2, 0],
  [0, 2, -14, 84, 66, -12, 2, 0],
  [0, 2, -14, 76, 76, -14, 2, 0],
  [0, 2, -12, 66, 84, -14, 2, 0],
  [0, 2, -12, 58, 94, -16, 2, 0],
  [0, 2, -12, 48, 102, -14, 2, 0],
  [0, 2, -10, 38, 110, -14, 2, 0],
  [0, 2, -8, 28, 116, -12, 2, 0],
  [0, 0, -4, 18, 122, -10, 2, 0],
  [0, 0, -2, 8, 126, -6, 2, 0],
];

const List<List<int>> _smooth = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, 28, 62, 34, 2, 0, 0],
  [0, 0, 26, 62, 36, 4, 0, 0],
  [0, 0, 22, 62, 40, 4, 0, 0],
  [0, 0, 20, 60, 42, 6, 0, 0],
  [0, 0, 18, 58, 44, 8, 0, 0],
  [0, 0, 16, 56, 46, 10, 0, 0],
  [0, -2, 16, 54, 48, 12, 0, 0],
  [0, -2, 14, 52, 52, 14, -2, 0],
  [0, 0, 12, 48, 54, 16, -2, 0],
  [0, 0, 10, 46, 56, 16, 0, 0],
  [0, 0, 8, 44, 58, 18, 0, 0],
  [0, 0, 6, 42, 60, 20, 0, 0],
  [0, 0, 4, 40, 62, 22, 0, 0],
  [0, 0, 4, 36, 62, 26, 0, 0],
  [0, 0, 2, 34, 62, 28, 2, 0],
];

const List<List<int>> _sharp = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [-2, 2, -6, 126, 8, -2, 2, 0],
  [-2, 6, -12, 124, 16, -6, 4, -2],
  [-2, 8, -18, 120, 26, -10, 6, -2],
  [-4, 10, -22, 116, 38, -14, 6, -2],
  [-4, 10, -22, 108, 48, -18, 8, -2],
  [-4, 10, -24, 100, 60, -20, 8, -2],
  [-4, 10, -24, 90, 70, -22, 10, -2],
  [-4, 12, -24, 80, 80, -24, 12, -4],
  [-2, 10, -22, 70, 90, -24, 10, -4],
  [-2, 8, -20, 60, 100, -24, 10, -4],
  [-2, 8, -18, 48, 108, -22, 10, -4],
  [-2, 6, -14, 38, 116, -22, 10, -4],
  [-2, 6, -10, 26, 120, -18, 8, -2],
  [-2, 4, -6, 16, 124, -12, 6, -2],
  [0, 2, -2, 8, 126, -6, 2, -2],
];

const _bd = 8;

// Golden, a direct copy of tile_decode.dart `_compoundConvolve` (bd8),
// restricted to the !doAverage CONV_BUF res producer. `ref` is the
// already edge-replicated patch. Output (0,0) at frac 0 reads ref[3][3] (the
// 8-tap support extends 3 left/up, 4 right/down), so x0 = y0 = 3 and we index
// ref directly (no further replication needed, the patch is (h+7)x(w+7) and
// already replicated by the caller).
List<List<int>> _goldenD16(
  List<List<int>> ref,
  int subX,
  int subY,
  int w,
  int h,
  List<List<int>> fx,
  List<List<int>> fy,
) {
  const filterBits = 7, round0 = 3, round1 = 7;
  const offsetBits = 8 + 2 * filterBits - round0; // 19
  const roundOffset =
      (1 << (offsetBits - round1)) + (1 << (offsetBits - round1 - 1)); // 6144
  const x0 = 3, y0 = 3;
  final dst = [for (var y = 0; y < h; y++) List<int>.filled(w, 0)];

  if (subX == 0 && subY == 0) {
    const bits = 2 * filterBits - round1 - round0; // 4
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        dst[y][x] = (ref[y0 + y][x0 + x] << bits) + roundOffset;
      }
    }
    return dst;
  }
  if (subX != 0 && subY == 0) {
    const bits = filterBits - round1; // 0
    final xf = fx[subX];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var raw = 0;
        for (var k = 0; k < 8; k++) {
          raw += xf[k] * ref[y0 + y][x0 + x - 3 + k];
        }
        dst[y][x] =
            ((1 << bits) * ((raw + (1 << (round0 - 1))) >> round0)) +
            roundOffset;
      }
    }
    return dst;
  }
  if (subX == 0 && subY != 0) {
    const bits = filterBits - round0; // 4
    final yf = fy[subY];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var raw = 0;
        for (var k = 0; k < 8; k++) {
          raw += yf[k] * ref[y0 + y - 3 + k][x0 + x];
        }
        raw *= (1 << bits);
        dst[y][x] = ((raw + (1 << (round1 - 1))) >> round1) + roundOffset;
      }
    }
    return dst;
  }
  // 2D separable.
  final xf = fx[subX], yf = fy[subY];
  final imH = h + 7;
  final im = List<int>.filled(imH * w, 0);
  const bd = _bd;
  for (var y = 0; y < imH; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 1 << (bd + filterBits - 1); // 1<<14
      for (var k = 0; k < 8; k++) {
        sum += xf[k] * ref[y0 + y - 3][x0 + x - 3 + k];
      }
      im[y * w + x] = (sum + (1 << (round0 - 1))) >> round0;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 1 << offsetBits;
      for (var k = 0; k < 8; k++) {
        sum += yf[k] * im[(y + k) * w + x];
      }
      dst[y][x] = (sum + (1 << (round1 - 1))) >> round1;
    }
  }
  return dst;
}

List<List<int>> _filterTable(InterConvolveD16Filter f) {
  switch (f) {
    case InterConvolveD16Filter.regular:
      return _regular;
    case InterConvolveD16Filter.smooth:
      return _smooth;
    case InterConvolveD16Filter.sharp:
      return _sharp;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Patch geometry: output WxH needs (W+7)x(H+7) replicated samples. Output
  // (0,0) at frac 0 maps to patch[3][3]. Same contract as HarborInterConvolve.
  for (final family in InterConvolveD16Filter.values) {
    test('HarborInterConvolveD16 matches _compoundConvolve CONV_BUF '
        'all 4 cases (${family.name})', () async {
      const w = 4, h = 4;
      final ph = h + 7, pw = w + 7;
      final dut = HarborInterConvolveD16(width: w, height: h, filter: family);
      final clk = SimpleClockGenerator(10).clk;
      final patch = Logic(name: 'patch', width: pw * ph * 8);
      final fracX = Logic(name: 'frac_x', width: 4);
      final fracY = Logic(name: 'frac_y', width: 4);
      dut.input('patch').srcConnection! <= patch;
      dut.input('frac_x').srcConnection! <= fracX;
      dut.input('frac_y').srcConnection! <= fracY;
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      final table = _filterTable(family);
      final rng = Random(0xD16 + family.index);

      // Phase set covering all four (subX, subY) quadrants and a spread.
      final phases = <List<int>>[
        [0, 0], // copy
        [4, 0], [8, 0], [1, 0], [15, 0], // horizontal only
        [0, 4], [0, 8], [0, 1], [0, 15], // vertical only
        [4, 4], [8, 8], [1, 15], [15, 1], [6, 10], [11, 3], // 2D
      ];

      var vectors = 0;
      var resMin = 1 << 30, resMax = -(1 << 30);
      final caseSeen = <String, bool>{
        '00': false,
        'x0': false,
        '0y': false,
        'xy': false,
      };
      for (final phase in phases) {
        final fx = phase[0], fy = phase[1];
        for (var iter = 0; iter < 3; iter++) {
          final px = [
            for (var r = 0; r < ph; r++)
              [for (var c = 0; c < pw; c++) rng.nextInt(256)],
          ];
          var packed = BigInt.zero;
          for (var r = 0; r < ph; r++) {
            for (var c = 0; c < pw; c++) {
              packed |= BigInt.from(px[r][c]) << ((r * pw + c) * 8);
            }
          }
          patch.put(packed);
          fracX.put(fx);
          fracY.put(fy);
          await clk.nextPosedge;

          final gold = _goldenD16(px, fx, fy, w, h, table, table);
          final out = dut.output('conv').value;
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final idx = y * w + x;
              final g = gold[y][x];
              // Verify res fits unsigned 16b and is non-negative.
              expect(
                g,
                greaterThanOrEqualTo(0),
                reason: 'res non-negative ${family.name} fx=$fx fy=$fy',
              );
              expect(
                g,
                lessThanOrEqualTo(0xFFFF),
                reason: 'res fits 16b ${family.name} fx=$fx fy=$fy',
              );
              expect(
                out.getRange(idx * 16, idx * 16 + 16).toInt(),
                equals(g),
                reason: '${family.name} fx=$fx fy=$fy iter=$iter ($x,$y)',
              );
              if (g < resMin) resMin = g;
              if (g > resMax) resMax = g;
            }
          }
          vectors++;
          if (fx == 0 && fy == 0) {
            caseSeen['00'] = true;
          } else if (fx != 0 && fy == 0) {
            caseSeen['x0'] = true;
          } else if (fx == 0 && fy != 0) {
            caseSeen['0y'] = true;
          } else {
            caseSeen['xy'] = true;
          }
        }
      }
      expect(
        caseSeen.values.every((v) => v),
        isTrue,
        reason: 'all four convolve cases covered: $caseSeen',
      );
      expect(vectors, greaterThanOrEqualTo(30));
      // Sanity: res stayed centred on roundOffset=6144 and within 16b.
      expect(resMin, greaterThanOrEqualTo(0));
      expect(resMax, lessThanOrEqualTo(0xFFFF));
      await Simulator.endSimulation();
    });
  }

  test('HarborInterConvolveD16 rejects bad config', () {
    expect(() => HarborInterConvolveD16(width: 0), throwsArgumentError);
    expect(() => HarborInterConvolveD16(height: 0), throwsArgumentError);
  });

  // Strong end-to-end check: feed two conv outputs (two phases, two patches)
  // into HarborCompoundBlend's average path and verify the full predict matches
  // the SW doAverage golden end-to-end.
  test(
    'HarborInterConvolveD16 + HarborCompoundBlend matches doAverage',
    () async {
      const w = 4, h = 4;
      final ph = h + 7, pw = w + 7;
      final n = w * h;
      const family = InterConvolveD16Filter.regular;

      final conv = HarborInterConvolveD16(width: w, height: h, filter: family);
      final blend = HarborCompoundBlend(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;

      final patch = Logic(name: 'patch', width: pw * ph * 8);
      final fracX = Logic(name: 'frac_x', width: 4);
      final fracY = Logic(name: 'frac_y', width: 4);
      final src0 = Logic(name: 'src0', width: n * 16);
      final src1 = Logic(name: 'src1', width: n * 16);
      final mask = Logic(name: 'mask', width: n * 7);
      final fwd = Logic(name: 'fwd', width: 5);
      final bck = Logic(name: 'bck', width: 5);
      final useDistWtd = Logic(name: 'use_dist_wtd', width: 1);
      final mode = Logic(name: 'mode', width: 2);

      conv.input('patch').srcConnection! <= patch;
      conv.input('frac_x').srcConnection! <= fracX;
      conv.input('frac_y').srcConnection! <= fracY;
      blend.input('src0').srcConnection! <= src0;
      blend.input('src1').srcConnection! <= src1;
      blend.input('mask').srcConnection! <= mask;
      blend.input('fwd').srcConnection! <= fwd;
      blend.input('bck').srcConnection! <= bck;
      blend.input('use_dist_wtd').srcConnection! <= useDistWtd;
      blend.input('mode').srcConnection! <= mode;

      await conv.build();
      await blend.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      int clip255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

      // Run the conv DUT for a (patch, phase) and read its 16b conv output.
      Future<List<int>> runConv(List<List<int>> p, int fx, int fy) async {
        var packed = BigInt.zero;
        for (var r = 0; r < ph; r++) {
          for (var c = 0; c < pw; c++) {
            packed |= BigInt.from(p[r][c]) << ((r * pw + c) * 8);
          }
        }
        patch.put(packed);
        fracX.put(fx);
        fracY.put(fy);
        await clk.nextPosedge;
        final out = conv.output('conv').value;
        return [
          for (var k = 0; k < n; k++) out.getRange(k * 16, k * 16 + 16).toInt(),
        ];
      }

      final rng = Random(0xBEEF);
      final phasePairs = <List<int>>[
        [4, 4, 8, 8], // both 2D
        [0, 0, 6, 10], // copy vs 2D
        [4, 0, 0, 8], // horiz vs vert
        [15, 1, 1, 15],
      ];

      for (final pp in phasePairs) {
        final p0 = [
          for (var r = 0; r < ph; r++)
            [for (var c = 0; c < pw; c++) rng.nextInt(256)],
        ];
        final p1 = [
          for (var r = 0; r < ph; r++)
            [for (var c = 0; c < pw; c++) rng.nextInt(256)],
        ];
        final c0 = await runConv(p0, pp[0], pp[1]);
        final c1 = await runConv(p1, pp[2], pp[3]);

        // Drive both 16b sets into the blend, average path.
        var pk0 = BigInt.zero, pk1 = BigInt.zero;
        for (var k = 0; k < n; k++) {
          pk0 |= BigInt.from(c0[k]) << (k * 16);
          pk1 |= BigInt.from(c1[k]) << (k * 16);
        }
        src0.put(pk0);
        src1.put(pk1);
        mask.put(0);
        fwd.put(8);
        bck.put(8);
        useDistWtd.put(0);
        mode.put(0);
        await clk.nextPosedge;
        final outVal = blend.output('out').value;

        // SW doAverage golden: tmp = (src0+src1)>>1, then tmp -= 6144,
        //                      pl = clip((tmp + 8) >> 4).
        for (var k = 0; k < n; k++) {
          var tmp = (c0[k] + c1[k]) >> 1;
          tmp -= 6144;
          final gold = clip255((tmp + (1 << 3)) >> 4);
          expect(
            outVal.getRange(k * 8, k * 8 + 8).toInt(),
            equals(gold),
            reason: 'pp=$pp k=$k',
          );
        }
      }
      await Simulator.endSimulation();
    },
  );
}
