import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

(List<int>, Map<String, int>) _build(
  int diff,
  int upW,
  int frH,
  int rwM1,
  int rhM1,
) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  f(diff, 1);
  var rw = upW, rh = frH;
  if (diff == 1) {
    f(rwM1, 16);
    f(rhM1, 16);
    rw = rwM1 + 1;
    rh = rhM1 + 1;
  }
  return (
    bits,
    {
      'render_width': rw,
      'render_height': rh,
      'render_different': diff,
      'bits_consumed': bits.length,
    },
  );
}

List<int> _bytes(List<int> bits) {
  final out = List.filled(16, 0);
  for (var i = 0; i < bits.length && i < 128; i++) {
    if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborRenderSizeParser', () {
    late HarborRenderSizeParser p;
    late Logic clk, bytes, upW, frH;

    Future<void> setUpDut() async {
      p = HarborRenderSizeParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      upW = Logic(name: 'upscaled_width', width: 17);
      frH = Logic(name: 'frame_height', width: 17);
      p.input('bytes').srcConnection! <= bytes;
      p.input('upscaled_width').srcConnection! <= upW;
      p.input('frame_height').srcConnection! <= frH;
      await p.build();
      bytes.inject(0);
      upW.inject(0);
      frH.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt pack(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    final cases = <(String, int, int, int, int, int)>[
      ('same as frame', 0, 1920, 1080, 0, 0),
      ('different 1280x720', 1, 1920, 1080, 1279, 719),
      ('different small', 1, 3840, 2160, 639, 359),
      ('same 4k', 0, 3840, 2160, 0, 0),
    ];

    for (final c in cases) {
      test(c.$1, () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2, c.$3, c.$4, c.$5, c.$6);
        bytes.inject(pack(_bytes(bits)));
        upW.inject(c.$3);
        frH.inject(c.$4);
        await clk.nextPosedge;
        for (final key in exp.keys) {
          expect(
            p.output(key).value.toInt(),
            equals(exp[key]),
            reason: '${c.$1}: $key',
          );
        }
        await Simulator.endSimulation();
      });
    }
  });
}
