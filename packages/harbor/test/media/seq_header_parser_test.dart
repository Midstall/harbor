import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// A tiny MSB-first bit writer to build a reduced_still_picture sequence header.
class _BitWriter {
  final bits = <int>[];
  void f(int value, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((value >> k) & 1);
    }
  }

  List<int> toBytes(int len) {
    final out = List.filled(len, 0);
    for (var i = 0; i < bits.length && i < len * 8; i++) {
      if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
    }
    return out;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSeqHeaderParser', () {
    late HarborSeqHeaderParser p;
    late Logic clk, bytes;

    Future<void> setUpDut() async {
      p = HarborSeqHeaderParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      p.input('bytes').srcConnection! <= bytes;
      await p.build();
      bytes.inject(0);
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

    // Build the reduced_still_picture header and the expected consumed bits.
    (List<int>, int) build(
      int profile,
      int still,
      int level,
      int width,
      int height,
    ) {
      final w = _BitWriter();
      w.f(profile, 3);
      w.f(still, 1);
      w.f(1, 1); // reduced_still_picture_header = 1
      w.f(level, 5);
      // Pick the minimal bit-widths for the dimensions.
      final wBitsM1 = (width - 1).bitLength - 1; // frame_width_bits_minus_1
      final hBitsM1 = (height - 1).bitLength - 1;
      w.f(wBitsM1, 4);
      w.f(hBitsM1, 4);
      w.f(width - 1, wBitsM1 + 1);
      w.f(height - 1, hBitsM1 + 1);
      return (w.toBytes(16), w.bits.length);
    }

    final cases = <(String, int, int, int, int, int)>[
      ('1080p main', 0, 0, 8, 1920, 1080),
      ('4k high', 1, 0, 16, 3840, 2160),
      ('still 64x64', 0, 1, 0, 64, 64),
      ('720p', 0, 0, 5, 1280, 720),
      ('odd size', 2, 0, 12, 1000, 600),
      ('tiny 16x16', 0, 1, 1, 16, 16),
      ('wide 8192x256', 0, 0, 8, 8192, 256),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (buf, consumed) = build(c.$2, c.$3, c.$4, c.$5, c.$6);
        bytes.inject(pack(buf));
        await clk.nextPosedge;
        expect(
          p.output('seq_profile').value.toInt(),
          equals(c.$2),
          reason: 'profile',
        );
        expect(
          p.output('still_picture').value.toInt(),
          equals(c.$3),
          reason: 'still',
        );
        expect(
          p.output('reduced_still_picture').value.toInt(),
          equals(1),
          reason: 'reduced',
        );
        expect(
          p.output('seq_level_idx').value.toInt(),
          equals(c.$4),
          reason: 'level',
        );
        expect(
          p.output('frame_width').value.toInt(),
          equals(c.$5),
          reason: 'width',
        );
        expect(
          p.output('frame_height').value.toInt(),
          equals(c.$6),
          reason: 'height',
        );
        expect(
          p.output('bits_consumed').value.toInt(),
          equals(consumed),
          reason: 'consumed',
        );
        expect(
          p.output('supported').value.toInt(),
          equals(1),
          reason: 'supported',
        );
        await Simulator.endSimulation();
      });
    }
  });
}
