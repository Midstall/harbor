import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/film_grain_scale.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden models, transcribed verbatim from the SW reference film grain model.

const int _minLumaLegal = 16, _maxLumaLegal = 235;
const int _minChromaLegal = 16, _maxChromaLegal = 240;

int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Mirror of `_initScaling` (film_grain.dart line 73). Builds a 256-entry LUT
/// by piecewise-linear interpolation across `n` control points `[value,scale]`.
List<int> _initScalingGold(List<List<int>> pts, int n) {
  final lut = List<int>.filled(256, 0);
  if (n == 0) return lut;
  for (var i = 0; i < pts[0][0]; i++) {
    lut[i] = pts[0][1];
  }
  for (var point = 0; point < n - 1; point++) {
    final dy = pts[point + 1][1] - pts[point][1];
    final dx = pts[point + 1][0] - pts[point][0];
    final delta = dy * ((65536 + (dx >> 1)) ~/ dx);
    for (var x = 0; x < dx; x++) {
      lut[pts[point][0] + x] = pts[point][1] + ((x * delta + 32768) >> 16);
    }
  }
  for (var i = pts[n - 1][0]; i < 256; i++) {
    lut[i] = pts[n - 1][1];
  }
  return lut;
}

/// Mirror of `_scaleLut` for bd8: `(bd-8)==0` => returns `lut[index]` directly.
int _scaleLutBd8(List<int> lut, int index) => lut[index >> 0];

/// Mirror of the luma per-pixel kernel inside `_addNoise` (line 684-698), bd8.
/// `scaling` is `_scaleLut(lutY, pixel, 8)`. `clipLegal`/`isChroma` select the
/// clamp bounds: legal luma [16,235], legal chroma [16,240], else [0,255].
int _addNoiseGold(
  int pixel,
  int grain,
  int scaling,
  int scalingShift,
  bool clipLegal,
  bool isChroma,
) {
  const bd = 8;
  final rounding = 1 << (scalingShift - 1);
  final int lo, hi;
  if (clipLegal) {
    if (isChroma) {
      lo = _minChromaLegal << (bd - 8);
      hi = _maxChromaLegal << (bd - 8);
    } else {
      lo = _minLumaLegal << (bd - 8);
      hi = _maxLumaLegal << (bd - 8);
    }
  } else {
    lo = 0;
    hi = (256 << (bd - 8)) - 1;
  }
  final noise = (scaling * grain + rounding) >> scalingShift;
  return _clamp(pixel + noise, lo, hi);
}

void main() {
  test('filmGrainScalingLut matches _initScaling over random control points', () {
    final rng = Random(0xF11);
    for (var iter = 0; iter < 2000; iter++) {
      final n = 1 + rng.nextInt(14);
      // Build strictly-increasing x values in [0,255], arbitrary y in [0,255].
      final xs = <int>{};
      while (xs.length < n) {
        xs.add(rng.nextInt(256));
      }
      final sortedX = xs.toList()..sort();
      final pts = [
        for (final x in sortedX) [x, rng.nextInt(256)],
      ];
      final gold = _initScalingGold(pts, n);
      final got = filmGrainScalingLut(pts, n);
      expect(got, equals(gold), reason: 'iter=$iter n=$n pts=$pts');

      // Confirm the bd8 scaling lookup is just lut[index] for all 256 indices.
      for (var idx = 0; idx < 256; idx++) {
        expect(
          _scaleLutBd8(gold, idx),
          equals(gold[idx]),
          reason: 'bd8 _scaleLut idx=$idx',
        );
      }
    }
  });

  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborFilmGrainScale matches _addNoise per-pixel kernel (bd8)', () async {
    const w = 8, h = 8, n = w * h;
    final dut = HarborFilmGrainScale(width: w, height: h);
    final clk = SimpleClockGenerator(10).clk;
    final pixel = Logic(name: 'pixel', width: n * 8);
    final grain = Logic(name: 'grain', width: n * 8);
    final scaling = Logic(name: 'scaling', width: n * 8);
    final scalingShift = Logic(name: 'scaling_shift', width: 4);
    final clipLegal = Logic(name: 'clip_legal');
    final isChroma = Logic(name: 'is_chroma');
    dut.input('pixel').srcConnection! <= pixel;
    dut.input('grain').srcConnection! <= grain;
    dut.input('scaling').srcConnection! <= scaling;
    dut.input('scaling_shift').srcConnection! <= scalingShift;
    dut.input('clip_legal').srcConnection! <= clipLegal;
    dut.input('is_chroma').srcConnection! <= isChroma;
    await dut.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    final rng = Random(0x6A1);
    for (var iter = 0; iter < 1500; iter++) {
      // First few iters force clamp-boundary extremes (min/max pixel, fully
      // negative / fully positive grain at max scaling) to exercise both clips.
      final extreme = iter < 64;
      final px = [
        for (var i = 0; i < n; i++)
          extreme ? (rng.nextBool() ? 0 : 255) : rng.nextInt(256),
      ];
      // grain range for bd8 is [grainMin, grainMax] = [-128, 127] (signed 8b).
      final gr = [
        for (var i = 0; i < n; i++)
          extreme ? (rng.nextBool() ? -128 : 127) : rng.nextInt(256) - 128,
      ];
      final sc = [for (var i = 0; i < n; i++) extreme ? 255 : rng.nextInt(256)];
      final shift = 8 + rng.nextInt(4); // real scalingShift range 8..11.
      final clip = extreme ? (iter.isEven) : rng.nextBool();
      final chroma = extreme ? (iter ~/ 2).isEven : rng.nextBool();

      var pPx = BigInt.zero, pGr = BigInt.zero, pSc = BigInt.zero;
      for (var i = 0; i < n; i++) {
        pPx |= BigInt.from(px[i]) << (i * 8);
        pGr |= BigInt.from(gr[i]).toUnsigned(8) << (i * 8);
        pSc |= BigInt.from(sc[i]) << (i * 8);
      }
      pixel.put(pPx);
      grain.put(pGr);
      scaling.put(pSc);
      scalingShift.put(shift);
      clipLegal.put(clip ? 1 : 0);
      isChroma.put(chroma ? 1 : 0);
      await clk.nextPosedge;

      final ov = dut.output('out').value;
      for (var k = 0; k < n; k++) {
        final gold = _addNoiseGold(px[k], gr[k], sc[k], shift, clip, chroma);
        expect(
          ov.getRange(k * 8, k * 8 + 8).toInt(),
          equals(gold),
          reason:
              'iter=$iter k=$k px=${px[k]} gr=${gr[k]} sc=${sc[k]} '
              'shift=$shift clip=$clip chroma=$chroma',
        );
      }
    }
    await Simulator.endSimulation();
  });
}
