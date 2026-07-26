import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _paeth(int a, int l, int al) {
  final base = a + l - al;
  final pa = (base - a).abs();
  final pl = (base - l).abs();
  final pal = (base - al).abs();
  if (pa <= pl && pa <= pal) return a;
  if (pl <= pal) return l;
  return al;
}

const _smWeights4 = [255, 149, 85, 64];
const _smWeights8 = [255, 197, 146, 105, 73, 50, 37, 32];

// Reference: predict + reconstruct (residual indexed stride-8).
List<int> _predict(
  int mode,
  int n,
  List<int> above,
  List<int> left,
  int al,
  List<int> res,
) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    s += above[i] + left[i];
  }
  final dc = (s + n) >> (n == 8 ? 4 : 3);
  final sm = n == 8 ? _smWeights8 : _smWeights4;
  final belowLeft = left[n - 1];
  final aboveRight = above[n - 1];
  final out = List.filled(64, 0);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      final vsum = sm[r] * above[c] + (256 - sm[r]) * belowLeft;
      final hsum = sm[c] * left[r] + (256 - sm[c]) * aboveRight;
      final int pred;
      switch (mode) {
        case 0:
          pred = dc;
        case 1:
          pred = above[c];
        case 2:
          pred = left[r];
        case 3:
          pred = _paeth(above[c], left[r], al);
        case 4:
          pred = (vsum + hsum + 256) >> 9;
        case 5:
          pred = (vsum + 128) >> 8;
        case 6:
          pred = (hsum + 128) >> 8;
        default:
          pred = above[(r + c + 1) > 7 ? 7 : (r + c + 1)];
      }
      out[r * 8 + c] = _clampPx(pred + res[r * 8 + c]);
    }
  }
  return out;
}

BigInt _packPix(List<int> px) {
  var v = BigInt.zero;
  for (var i = 0; i < px.length; i++) {
    v |= BigInt.from(px[i] & 0xFF) << (i * 8);
  }
  return v;
}

BigInt _packRes(List<int> r) {
  var v = BigInt.zero;
  for (var i = 0; i < 64; i++) {
    v |= BigInt.from(r[i] & 0xFFFF) << (i * 16);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraPredictor', () {
    late HarborIntraPredictor pred;
    late Logic clk, mode, size, above, left, aboveLeft, residual;

    Future<void> setUpDut() async {
      pred = HarborIntraPredictor();
      clk = SimpleClockGenerator(10).clk; // just to drive simulation ticks
      mode = Logic(name: 'mode', width: 3);
      size = Logic(name: 'size');
      above = Logic(name: 'above', width: 64);
      left = Logic(name: 'left', width: 64);
      aboveLeft = Logic(name: 'above_left', width: 8);
      residual = Logic(name: 'residual', width: 64 * 16);

      pred.input('mode').srcConnection! <= mode;
      pred.input('size').srcConnection! <= size;
      pred.input('above').srcConnection! <= above;
      pred.input('left').srcConnection! <= left;
      pred.input('above_left').srcConnection! <= aboveLeft;
      pred.input('residual').srcConnection! <= residual;

      await pred.build();
      mode.inject(0);
      size.inject(0);
      above.inject(0);
      left.inject(0);
      aboveLeft.inject(0);
      residual.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    List<int> readRecon() {
      final v = pred.output('recon').value.toBigInt();
      return [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
    }

    for (final n in [4, 8]) {
      for (final m in [0, 1, 2, 3, 4, 5, 6, 7]) {
        final names = [
          'DC',
          'Vertical',
          'Horizontal',
          'Paeth',
          'SMOOTH',
          'SMOOTH_V',
          'SMOOTH_H',
          'D45',
        ];
        test(
          '${n}x$n ${names[m]} reconstruction matches the reference',
          () async {
            await setUpDut();
            final abovePx = [for (var i = 0; i < 8; i++) (i * 30 + 40) & 0xFF];
            final leftPx = [for (var i = 0; i < 8; i++) (i * 23 + 55) & 0xFF];
            const al = 100;
            // A residual with both positive and negative values (to test clamp).
            final res = [for (var i = 0; i < 64; i++) (i * 9 - 130)];

            mode.inject(m);
            size.inject(n == 8 ? 1 : 0);
            above.inject(_packPix(abovePx));
            left.inject(_packPix(leftPx));
            aboveLeft.inject(al);
            residual.inject(_packRes(res));
            await clk.nextPosedge;

            final got = readRecon();
            final expected = _predict(m, n, abovePx, leftPx, al, res);
            for (var r = 0; r < n; r++) {
              for (var c = 0; c < n; c++) {
                expect(
                  got[r * 8 + c],
                  equals(expected[r * 8 + c]),
                  reason: 'pixel ($r,$c)',
                );
              }
            }
            await Simulator.endSimulation();
          },
        );
      }
    }
  });
}
