import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _FS {
  _FS({
    required this.override,
    required this.wBitsM1,
    required this.hBitsM1,
    required this.maxWm1,
    required this.maxHm1,
    required this.enableSr,
    this.wM1 = 0,
    this.hM1 = 0,
    this.useSr = 0,
    this.codedDenom = 0,
  });
  final int override, wBitsM1, hBitsM1, maxWm1, maxHm1, enableSr;
  final int wM1, hM1, useSr, codedDenom;
}

(List<int>, Map<String, int>) _build(_FS s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  int wM1, hM1;
  if (s.override == 1) {
    f(s.wM1, s.wBitsM1 + 1);
    f(s.hM1, s.hBitsM1 + 1);
    wM1 = s.wM1;
    hM1 = s.hM1;
  } else {
    wM1 = s.maxWm1;
    hM1 = s.maxHm1;
  }
  final fw = wM1 + 1;
  final fh = hM1 + 1;
  var denom = 8, useSr = 0;
  if (s.enableSr == 1) {
    f(s.useSr, 1);
    useSr = s.useSr;
    if (useSr == 1) {
      f(s.codedDenom, 3);
      denom = s.codedDenom + 9;
    }
  }
  int miOf(int dim) => 2 * ((dim + 7) >> 3);

  return (
    bits,
    {
      'frame_width': fw,
      'frame_height': fh,
      'upscaled_width': fw,
      'superres_denom': denom,
      'mi_cols': miOf(fw),
      'mi_rows': miOf(fh),
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

  group('HarborFrameSizeParser', () {
    late HarborFrameSizeParser p;
    late Logic clk, bytes, ov, wb, hb, maxW, maxH, enSr;

    Future<void> setUpDut() async {
      p = HarborFrameSizeParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      ov = Logic(name: 'frame_size_override', width: 1);
      wb = Logic(name: 'frame_width_bits_minus_1', width: 4);
      hb = Logic(name: 'frame_height_bits_minus_1', width: 4);
      maxW = Logic(name: 'max_frame_width_minus_1', width: 16);
      maxH = Logic(name: 'max_frame_height_minus_1', width: 16);
      enSr = Logic(name: 'enable_superres', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('frame_size_override').srcConnection! <= ov;
      p.input('frame_width_bits_minus_1').srcConnection! <= wb;
      p.input('frame_height_bits_minus_1').srcConnection! <= hb;
      p.input('max_frame_width_minus_1').srcConnection! <= maxW;
      p.input('max_frame_height_minus_1').srcConnection! <= maxH;
      p.input('enable_superres').srcConnection! <= enSr;
      await p.build();
      bytes.inject(0);
      for (final x in [ov, wb, hb, enSr]) {
        x.inject(0);
      }
      maxW.inject(0);
      maxH.inject(0);
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

    final cases = <(String, _FS)>[
      (
        'from seq max 1080p',
        _FS(
          override: 0,
          wBitsM1: 10,
          hBitsM1: 10,
          maxWm1: 1919,
          maxHm1: 1079,
          enableSr: 0,
        ),
      ),
      (
        'override 1280x720',
        _FS(
          override: 1,
          wBitsM1: 11,
          hBitsM1: 10,
          maxWm1: 0,
          maxHm1: 0,
          enableSr: 0,
          wM1: 1279,
          hM1: 719,
        ),
      ),
      (
        'superres enabled, used',
        _FS(
          override: 0,
          wBitsM1: 11,
          hBitsM1: 10,
          maxWm1: 3839,
          maxHm1: 2159,
          enableSr: 1,
          useSr: 1,
          codedDenom: 4,
        ),
      ),
      (
        'superres enabled, unused',
        _FS(
          override: 0,
          wBitsM1: 11,
          hBitsM1: 10,
          maxWm1: 3839,
          maxHm1: 2159,
          enableSr: 1,
          useSr: 0,
        ),
      ),
      (
        'tiny 64x64 override',
        _FS(
          override: 1,
          wBitsM1: 5,
          hBitsM1: 5,
          maxWm1: 0,
          maxHm1: 0,
          enableSr: 0,
          wM1: 63,
          hM1: 63,
        ),
      ),
      (
        'non-multiple-8 size',
        _FS(
          override: 1,
          wBitsM1: 11,
          hBitsM1: 10,
          maxWm1: 0,
          maxHm1: 0,
          enableSr: 0,
          wM1: 1233,
          hM1: 691,
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        ov.inject(c.$2.override);
        wb.inject(c.$2.wBitsM1);
        hb.inject(c.$2.hBitsM1);
        maxW.inject(c.$2.maxWm1);
        maxH.inject(c.$2.maxHm1);
        enSr.inject(c.$2.enableSr);
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
