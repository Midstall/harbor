import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// leb128 encode.
List<int> _leb128(int v) {
  final out = <int>[];
  do {
    var b = v & 0x7f;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

// Build one OBU: header byte (+ leb128 size) + payload bytes.
List<int> _obu(int type, List<int> payload) {
  final hdr = (type << 3) | (1 << 1); // has_size = 1, no extension
  return [hdr, ..._leb128(payload.length), ...payload];
}

// Reduced_still_picture sequence header payload for given dimensions.
List<int> _seqPayload(int profile, int level, int width, int height) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  f(profile, 3);
  f(0, 1); // still_picture
  f(1, 1); // reduced_still_picture_header
  f(level, 5);
  final wB = (width - 1).bitLength - 1;
  final hB = (height - 1).bitLength - 1;
  f(wB, 4);
  f(hB, 4);
  f(width - 1, wB + 1);
  f(height - 1, hB + 1);
  // Pad to a byte boundary.
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  final bytes = <int>[];
  for (var i = 0; i < bits.length; i += 8) {
    var b = 0;
    for (var j = 0; j < 8; j++) {
      b = (b << 1) | bits[i + j];
    }
    bytes.add(b);
  }
  return bytes;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborObuStreamWalker', () {
    test('walks a temporal-delimiter + sequence-header stream', () async {
      final w = HarborObuStreamWalker();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final bytes = Logic(name: 'bytes', width: 48 * 8);
      final streamLen = Logic(name: 'stream_len', width: 12);
      final start = Logic(name: 'start');
      w.input('clk').srcConnection! <= clk;
      w.input('reset').srcConnection! <= reset;
      w.input('bytes').srcConnection! <= bytes;
      w.input('stream_len').srcConnection! <= streamLen;
      w.input('start').srcConnection! <= start;
      await w.build();

      // Stream: temporal delimiter (type 2, empty), then a 1080p seq header
      // (type 1), then a padding OBU (type 15, empty).
      final stream = <int>[
        ..._obu(2, []),
        ..._obu(1, _seqPayload(0, 8, 1920, 1080)),
        ..._obu(15, []),
      ];
      final buf = List<int>.filled(48, 0);
      for (var i = 0; i < stream.length; i++) {
        buf[i] = stream[i];
      }
      var pv = BigInt.zero;
      for (var i = 0; i < 48; i++) {
        pv |= BigInt.from(buf[i] & 0xFF) << (i * 8);
      }

      reset.inject(1);
      bytes.inject(pv);
      streamLen.inject(stream.length);
      start.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      // Walk until done (a handful of cycles for 3 OBUs).
      var guard = 0;
      while (w.output('done').value.toInt() == 0 && guard < 20) {
        await clk.nextPosedge;
        guard++;
      }

      expect(w.output('done').value.toInt(), equals(1), reason: 'done');
      expect(
        w.output('obu_count').value.toInt(),
        equals(3),
        reason: 'obu_count',
      );
      expect(
        w.output('last_obu_type').value.toInt(),
        equals(15),
        reason: 'last type = padding',
      );
      expect(
        w.output('seq_profile').value.toInt(),
        equals(0),
        reason: 'profile',
      );
      expect(
        w.output('frame_width').value.toInt(),
        equals(1920),
        reason: 'width',
      );
      expect(
        w.output('frame_height').value.toInt(),
        equals(1080),
        reason: 'height',
      );
      await Simulator.endSimulation();
    });

    test('extracts 4k dimensions from a two-OBU stream', () async {
      final w = HarborObuStreamWalker();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final bytes = Logic(name: 'bytes', width: 48 * 8);
      final streamLen = Logic(name: 'stream_len', width: 12);
      final start = Logic(name: 'start');
      w.input('clk').srcConnection! <= clk;
      w.input('reset').srcConnection! <= reset;
      w.input('bytes').srcConnection! <= bytes;
      w.input('stream_len').srcConnection! <= streamLen;
      w.input('start').srcConnection! <= start;
      await w.build();

      final stream = <int>[
        ..._obu(2, []),
        ..._obu(1, _seqPayload(1, 16, 3840, 2160)),
      ];
      final buf = List<int>.filled(48, 0);
      for (var i = 0; i < stream.length; i++) {
        buf[i] = stream[i];
      }
      var pv = BigInt.zero;
      for (var i = 0; i < 48; i++) {
        pv |= BigInt.from(buf[i] & 0xFF) << (i * 8);
      }

      reset.inject(1);
      bytes.inject(pv);
      streamLen.inject(stream.length);
      start.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      var guard = 0;
      while (w.output('done').value.toInt() == 0 && guard < 20) {
        await clk.nextPosedge;
        guard++;
      }

      expect(w.output('done').value.toInt(), equals(1));
      expect(w.output('obu_count').value.toInt(), equals(2));
      expect(w.output('seq_profile').value.toInt(), equals(1));
      expect(w.output('frame_width').value.toInt(), equals(3840));
      expect(w.output('frame_height').value.toInt(), equals(2160));
      await Simulator.endSimulation();
    });
  });
}
