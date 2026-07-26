@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

// ignore: avoid_relative_lib_imports
import 'package:harbor/src/media/mask_blend.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden = Dart copies of the AV1 blend expression and mask tables, mirroring
// the AV1 spec tile decode reconstruction.
//
// Blend core (OBMC ~4417/4463, inter-intra ~4532/4557):
//   out = (m * a + (64 - m) * b + 32) >> 6
// where a,b are 8-bit predictions and m is a 6-bit mask (0..64).
int _blendGold(int m, int a, int b) => (m * a + (64 - m) * b + 32) >> 6;

// OBMC 1D masks (tile_decode.dart ~4321-4346), indexed by overlap dimension.
const _obmcMask1 = [64];
const _obmcMask2 = [45, 64];
const _obmcMask4 = [39, 50, 59, 64];
const _obmcMask8 = [36, 42, 48, 53, 57, 61, 64, 64];
const _obmcMask16 = [
  34,
  37,
  40,
  43,
  46,
  49,
  52,
  54,
  56,
  58,
  60,
  61,
  64,
  64,
  64,
  64,
];
const _obmcMask32 = [
  33, 35, 36, 38, 40, 41, 43, 44, 45, 47, 48, 50, 51, 52, 53, 55, //
  56, 57, 58, 59, 60, 60, 61, 62, 64, 64, 64, 64, 64, 64, 64, 64,
];
List<int> _obmcMaskGold(int len) {
  switch (len) {
    case 1:
      return _obmcMask1;
    case 2:
      return _obmcMask2;
    case 4:
      return _obmcMask4;
    case 8:
      return _obmcMask8;
    case 16:
      return _obmcMask16;
    default:
      return _obmcMask32;
  }
}

// Inter-intra smooth ramp (tile_decode.dart ~4563), 132 entries.
const _iiWeights1d = [
  60, 58, 56, 54, 52, 50, 48, 47, 45, 44, 42, 41, 39, 38, 37, 35, 34, 33, 32, //
  31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 22, 21, 20, 19, 19, 18, 18, 17, 16, //
  16, 15, 15, 14, 14, 13, 13, 12, 12, 12, 11, 11, 10, 10, 10, 9, 9, 9, 8, //
  8, 8, 8, 7, 7, 7, 7, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 4, 4, //
  4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, //
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
];

// Inter-intra 2D mask, modes: 0=DC, 1=V, 2=H, 3=SMOOTH (tile_decode.dart ~4538).
List<int> _interIntraMaskGold(int mode, int pbw, int pbh) {
  final scale = 128 ~/ (pbw > pbh ? pbw : pbh);
  final mask = List<int>.filled(pbw * pbh, 0);
  for (var y = 0; y < pbh; y++) {
    for (var x = 0; x < pbw; x++) {
      int m;
      switch (mode) {
        case 1:
          m = _iiWeights1d[y * scale];
          break;
        case 2:
          m = _iiWeights1d[x * scale];
          break;
        case 3:
          m = _iiWeights1d[(y < x ? y : x) * scale];
          break;
        default:
          m = 32;
      }
      mask[y * pbw + x] = m;
    }
  }
  return mask;
}

BigInt _packBytes(List<int> vals, int bits) {
  var packed = BigInt.zero;
  for (var i = 0; i < vals.length; i++) {
    packed |= BigInt.from(vals[i]) << (i * bits);
  }
  return packed;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Central runtime module: per-pixel mask blend over a parameterized block.
  for (final dims in [
    [8, 8],
    [1, 1],
    [4, 16],
    [16, 4],
  ]) {
    final w = dims[0], h = dims[1];
    test('HarborMaskBlend bit-exact blend ${w}x$h', () async {
      final n = w * h;
      final dut = HarborMaskBlend(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;
      final aIn = Logic(name: 'a', width: n * 8);
      final bIn = Logic(name: 'b', width: n * 8);
      final mIn = Logic(name: 'm', width: n * 7);
      dut.input('a').srcConnection! <= aIn;
      dut.input('b').srcConnection! <= bIn;
      dut.input('mask').srcConnection! <= mIn;
      await dut.build();
      Simulator.setMaxSimTime(60000000);
      unawaited(Simulator.run());

      final rng = Random(0x6B + w * 31 + h);
      for (var iter = 0; iter < 400; iter++) {
        final a = [for (var i = 0; i < n; i++) rng.nextInt(256)];
        final b = [for (var i = 0; i < n; i++) rng.nextInt(256)];
        // structured + random masks: full range 0..64.
        final m = [for (var i = 0; i < n; i++) rng.nextInt(65)];
        if (iter == 0) {
          for (var i = 0; i < n; i++) m[i] = 64;
        } else if (iter == 1) {
          for (var i = 0; i < n; i++) m[i] = 0;
        } else if (iter == 2) {
          for (var i = 0; i < n; i++) m[i] = 32;
        }
        aIn.put(_packBytes(a, 8));
        bIn.put(_packBytes(b, 8));
        mIn.put(_packBytes(m, 7));
        await clk.nextPosedge;
        final outv = dut.output('out').value;
        for (var k = 0; k < n; k++) {
          final got = outv.getRange(k * 8, k * 8 + 8).toInt();
          expect(
            got,
            equals(_blendGold(m[k], a[k], b[k])),
            reason:
                'blend ${w}x$h iter=$iter k=$k m=${m[k]} '
                'a=${a[k]} b=${b[k]}',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }

  // OBMC mask producer: bit-exact vs SW 1D table + 2D row/col indexing.
  test('HarborMaskBlend.obmcMask matches SW above/left construction', () {
    for (final len in [1, 2, 4, 8, 16, 32]) {
      expect(
        HarborMaskBlend.obmcMask1d(len),
        equals(_obmcMaskGold(len)),
        reason: 'obmc 1d len=$len',
      );
    }
    // Above blend: pbh is the overlap (mask indexed by row i).
    for (final pbw in [1, 2, 4, 8, 16, 32]) {
      for (final pbh in [1, 2, 4, 8, 16, 32]) {
        final got = HarborMaskBlend.obmcMask(pbw, pbh, above: true);
        final m1d = _obmcMaskGold(pbh);
        for (var i = 0; i < pbh; i++) {
          for (var j = 0; j < pbw; j++) {
            expect(
              got[i * pbw + j],
              equals(m1d[i]),
              reason: 'obmc above pbw=$pbw pbh=$pbh i=$i j=$j',
            );
          }
        }
        // Left blend: pbw is the overlap (mask indexed by col j).
        final gotL = HarborMaskBlend.obmcMask(pbw, pbh, above: false);
        final m1dL = _obmcMaskGold(pbw);
        for (var i = 0; i < pbh; i++) {
          for (var j = 0; j < pbw; j++) {
            expect(
              gotL[i * pbw + j],
              equals(m1dL[j]),
              reason: 'obmc left pbw=$pbw pbh=$pbh i=$i j=$j',
            );
          }
        }
      }
    }
  });

  // Inter-intra mask producer: bit-exact vs SW for every mode and block size.
  test('HarborMaskBlend.interIntraMask matches SW construction', () {
    const modes = {
      0: InterIntraMode.dc,
      1: InterIntraMode.v,
      2: InterIntraMode.h,
      3: InterIntraMode.smooth,
    };
    for (final pbw in [4, 8, 16, 32]) {
      for (final pbh in [4, 8, 16, 32]) {
        modes.forEach((swMode, mode) {
          final got = HarborMaskBlend.interIntraMask(mode, pbw, pbh);
          final gold = _interIntraMaskGold(swMode, pbw, pbh);
          expect(
            got,
            equals(gold),
            reason: 'interintra mode=$swMode pbw=$pbw pbh=$pbh',
          );
        });
      }
    }
  });

  // End-to-end: drive the real OBMC and inter-intra mask patterns through the
  // runtime blend module and check against the full SW pixel expression.
  test(
    'HarborMaskBlend blends real OBMC + inter-intra masks bit-exact',
    () async {
      const w = 8, h = 8, n = w * h;
      final dut = HarborMaskBlend(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;
      final aIn = Logic(name: 'a', width: n * 8);
      final bIn = Logic(name: 'b', width: n * 8);
      final mIn = Logic(name: 'm', width: n * 7);
      dut.input('a').srcConnection! <= aIn;
      dut.input('b').srcConnection! <= bIn;
      dut.input('mask').srcConnection! <= mIn;
      await dut.build();
      Simulator.setMaxSimTime(60000000);
      unawaited(Simulator.run());

      final patterns = <List<int>>[
        HarborMaskBlend.obmcMask(w, h, above: true),
        HarborMaskBlend.obmcMask(w, h, above: false),
        HarborMaskBlend.interIntraMask(InterIntraMode.v, w, h),
        HarborMaskBlend.interIntraMask(InterIntraMode.h, w, h),
        HarborMaskBlend.interIntraMask(InterIntraMode.smooth, w, h),
        HarborMaskBlend.interIntraMask(InterIntraMode.dc, w, h),
      ];

      final rng = Random(0x0B3C);
      var idx = 0;
      for (final m in patterns) {
        for (var rep = 0; rep < 30; rep++) {
          final a = [for (var i = 0; i < n; i++) rng.nextInt(256)];
          final b = [for (var i = 0; i < n; i++) rng.nextInt(256)];
          aIn.put(_packBytes(a, 8));
          bIn.put(_packBytes(b, 8));
          mIn.put(_packBytes(m, 7));
          await clk.nextPosedge;
          final outv = dut.output('out').value;
          for (var k = 0; k < n; k++) {
            expect(
              outv.getRange(k * 8, k * 8 + 8).toInt(),
              equals(_blendGold(m[k], a[k], b[k])),
              reason: 'pattern=$idx rep=$rep k=$k',
            );
          }
        }
        idx++;
      }
      await Simulator.endSimulation();
    },
  );
}
