import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 SGR boxsum (libaom _boxsum1/_boxsum2 interior), bd8. For each
// output position the consumed value is the full (2r+1)x(2r+1) window sum, so
// the golden forms each window sum directly over the padded region.
({List<int> b, List<int> a}) _boxsum(
  List<int> padded,
  int r,
  int width,
  int height,
) {
  final win = 2 * r + 1;
  final side = width + 2 * r;
  final b = <int>[];
  final a = <int>[];
  for (var i = 0; i < height; i++) {
    for (var j = 0; j < width; j++) {
      var bs = 0, as_ = 0;
      for (var dr = 0; dr < win; dr++) {
        for (var dc = 0; dc < win; dc++) {
          final p = padded[(i + dr) * side + (j + dc)];
          bs += p;
          as_ += p * p;
        }
      }
      b.add(bs);
      a.add(as_);
    }
  }
  return (b: b, a: a);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final r in [1, 2]) {
    test('HarborSgrBoxsum matches libaom boxsum interior (r=$r)', () async {
      const width = 8, height = 8;
      final side = width + 2 * r;
      final sideV = height + 2 * r;
      final bs = HarborSgrBoxsum(radius: r, width: width, height: height);
      final clk = SimpleClockGenerator(10).clk;
      final padded = Logic(name: 'padded', width: side * sideV * 8);
      bs.input('padded').srcConnection! <= padded;
      await bs.build();
      Simulator.setMaxSimTime(60000000);
      unawaited(Simulator.run());

      final rng = Random(0xB0 + r);
      for (var iter = 0; iter < 300; iter++) {
        final px = [for (var i = 0; i < side * sideV; i++) rng.nextInt(256)];
        var packed = BigInt.zero;
        for (var i = 0; i < px.length; i++) {
          packed |= BigInt.from(px[i]) << (i * 8);
        }
        padded.put(packed);
        await clk.nextPosedge;
        final gold = _boxsum(px, r, width, height);
        final bv = bs.output('bsum').value;
        final av = bs.output('asum').value;
        for (var k = 0; k < width * height; k++) {
          expect(
            bv.getRange(k * 16, k * 16 + 16).toInt(),
            equals(gold.b[k]),
            reason: 'bsum r=$r iter=$iter k=$k',
          );
          expect(
            av.getRange(k * 24, k * 24 + 24).toInt(),
            equals(gold.a[k]),
            reason: 'asum r=$r iter=$iter k=$k',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }
}
