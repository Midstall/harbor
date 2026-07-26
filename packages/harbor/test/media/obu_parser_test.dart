import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Encode a leb128 value to bytes (AV1 style, low 7 bits per byte, MSB = more).
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

// Build an OBU header byte stream and the expected decode.
class _Obu {
  _Obu(
    this.type,
    this.ext,
    this.hasSize,
    this.size, {
    this.tid = 0,
    this.sid = 0,
  });
  final int type, ext, hasSize, size, tid, sid;

  List<int> bytes() {
    final hdr = (type << 3) | (ext << 2) | (hasSize << 1);
    final out = <int>[hdr];
    if (ext == 1) out.add((tid << 5) | (sid << 3));
    if (hasSize == 1) out.addAll(_leb128(size));
    while (out.length < 10) {
      out.add(0);
    }
    return out;
  }

  int headerLen() => 1 + ext + (hasSize == 1 ? _leb128(size).length : 0);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborObuParser', () {
    late HarborObuParser p;
    late Logic clk, bytes;

    Future<void> setUpDut() async {
      p = HarborObuParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 10 * 8);
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

    final cases = <(String, _Obu)>[
      // OBU_TEMPORAL_DELIMITER (2), no ext, has_size, size 0.
      ('temporal delimiter', _Obu(2, 0, 1, 0)),
      // OBU_SEQUENCE_HEADER (1), has_size 1-byte size.
      ('seq header small size', _Obu(1, 0, 1, 11)),
      // OBU_FRAME (6), 2-byte leb128 size.
      ('frame 2-byte size', _Obu(6, 0, 1, 300)),
      // OBU_TILE_GROUP (4), big 3-byte leb128 size.
      ('tile group 3-byte size', _Obu(4, 0, 1, 70000)),
      // With extension header: temporal/spatial ids.
      ('with extension', _Obu(6, 1, 1, 250, tid: 5, sid: 2)),
      // has_size = 0 (size unknown, payload to end).
      ('no size field', _Obu(3, 0, 0, 0)),
      // Extension + no size.
      ('extension no size', _Obu(6, 1, 0, 0, tid: 3, sid: 1)),
      // Large 4-byte size.
      ('frame 4-byte size', _Obu(6, 0, 1, 20000000)),
    ];

    for (final c in cases) {
      test('parses: ${c.$1}', () async {
        await setUpDut();
        final o = c.$2;
        bytes.inject(pack(o.bytes()));
        await clk.nextPosedge;
        expect(
          p.output('obu_type').value.toInt(),
          equals(o.type),
          reason: 'type',
        );
        expect(
          p.output('extension_flag').value.toInt(),
          equals(o.ext),
          reason: 'ext',
        );
        expect(
          p.output('has_size').value.toInt(),
          equals(o.hasSize),
          reason: 'has_size',
        );
        expect(
          p.output('temporal_id').value.toInt(),
          equals(o.ext == 1 ? o.tid : 0),
          reason: 'tid',
        );
        expect(
          p.output('spatial_id').value.toInt(),
          equals(o.ext == 1 ? o.sid : 0),
          reason: 'sid',
        );
        expect(
          p.output('obu_size').value.toInt(),
          equals(o.hasSize == 1 ? o.size : 0),
          reason: 'size',
        );
        expect(
          p.output('header_len').value.toInt(),
          equals(o.headerLen()),
          reason: 'header_len',
        );
        await Simulator.endSimulation();
      });
    }
  });
}
