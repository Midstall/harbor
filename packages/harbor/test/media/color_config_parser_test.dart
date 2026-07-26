import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Semantic choices for a color_config. The encoder emits spec-order bits and
// computes the expected decoded fields.
class _CC {
  _CC(
    this.profile, {
    this.highBitdepth = 0,
    this.twelveBit = 0,
    this.mono = 0,
    this.cdp = 0,
    this.cp = 2,
    this.tc = 2,
    this.mc = 2,
    this.colorRange = 0,
    this.ssxBit = 1,
    this.ssyBit = 1,
    this.csp = 0,
    this.separateUv = 0,
  });
  final int profile,
      highBitdepth,
      twelveBit,
      mono,
      cdp,
      cp,
      tc,
      mc,
      colorRange,
      ssxBit,
      ssyBit,
      csp,
      separateUv;
}

(List<int>, Map<String, int>) _build(_CC s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  int bitDepth;
  f(s.highBitdepth, 1);
  if (s.profile == 2 && s.highBitdepth == 1) {
    f(s.twelveBit, 1);
    bitDepth = s.twelveBit == 1 ? 12 : 10;
  } else {
    bitDepth = s.highBitdepth == 1 ? 10 : 8;
  }
  int mono;
  if (s.profile == 1) {
    mono = 0;
  } else {
    f(s.mono, 1);
    mono = s.mono;
  }
  f(s.cdp, 1);
  int cp, tc, mc;
  if (s.cdp == 1) {
    f(s.cp, 8);
    f(s.tc, 8);
    f(s.mc, 8);
    cp = s.cp;
    tc = s.tc;
    mc = s.mc;
  } else {
    cp = 2;
    tc = 2;
    mc = 2;
  }
  int colorRange, ssx, ssy, csp = 0, separateUv;
  if (mono == 1) {
    f(s.colorRange, 1);
    colorRange = s.colorRange;
    ssx = 1;
    ssy = 1;
    f(s.separateUv, 1);
    separateUv = s.separateUv;
  } else if (cp == 1 && tc == 13 && mc == 0) {
    colorRange = 1;
    ssx = 0;
    ssy = 0;
    f(s.separateUv, 1);
    separateUv = s.separateUv;
  } else {
    f(s.colorRange, 1);
    colorRange = s.colorRange;
    if (s.profile == 0) {
      ssx = 1;
      ssy = 1;
    } else if (s.profile == 1) {
      ssx = 0;
      ssy = 0;
    } else {
      if (bitDepth == 12) {
        f(s.ssxBit, 1);
        ssx = s.ssxBit;
        if (ssx == 1) {
          f(s.ssyBit, 1);
          ssy = s.ssyBit;
        } else {
          ssy = 0;
        }
      } else {
        ssx = 1;
        ssy = 0;
      }
    }
    if (ssx == 1 && ssy == 1) {
      f(s.csp, 2);
      csp = s.csp;
    }
    f(s.separateUv, 1);
    separateUv = s.separateUv;
  }
  return (
    bits,
    {
      'bit_depth': bitDepth,
      'mono_chrome': mono,
      'num_planes': mono == 1 ? 1 : 3,
      'color_primaries': cp,
      'transfer_characteristics': tc,
      'matrix_coefficients': mc,
      'color_range': colorRange,
      'subsampling_x': ssx,
      'subsampling_y': ssy,
      'chroma_sample_position': csp,
      'separate_uv_delta_q': separateUv,
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

  group('HarborColorConfigParser', () {
    late HarborColorConfigParser p;
    late Logic clk, bytes, profile;

    Future<void> setUpDut() async {
      p = HarborColorConfigParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      profile = Logic(name: 'seq_profile', width: 3);
      p.input('bytes').srcConnection! <= bytes;
      p.input('seq_profile').srcConnection! <= profile;
      await p.build();
      bytes.inject(0);
      profile.inject(0);
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

    final cases = <(String, _CC)>[
      ('profile 0 8-bit 4:2:0', _CC(0)),
      (
        'profile 0 10-bit, color desc',
        _CC(
          0,
          highBitdepth: 1,
          cdp: 1,
          cp: 9,
          tc: 16,
          mc: 9,
          colorRange: 1,
          csp: 1,
        ),
      ),
      (
        'profile 1 4:4:4 8-bit',
        _CC(1, cdp: 1, cp: 1, tc: 13, mc: 13, colorRange: 1),
      ),
      (
        'profile 2 12-bit 4:2:0',
        _CC(
          2,
          highBitdepth: 1,
          twelveBit: 1,
          ssxBit: 1,
          ssyBit: 1,
          csp: 2,
          colorRange: 1,
        ),
      ),
      (
        'profile 2 12-bit 4:2:2',
        _CC(2, highBitdepth: 1, twelveBit: 1, ssxBit: 1, ssyBit: 0),
      ),
      (
        'profile 2 12-bit 4:4:4',
        _CC(2, highBitdepth: 1, twelveBit: 1, ssxBit: 0),
      ),
      ('profile 2 10-bit fixed 4:2:2', _CC(2, highBitdepth: 1, twelveBit: 0)),
      ('monochrome profile 0', _CC(0, mono: 1, colorRange: 1, separateUv: 1)),
      ('sRGB profile 1', _CC(1, cdp: 1, cp: 1, tc: 13, mc: 0, separateUv: 1)),
      (
        'profile 0 with separate_uv',
        _CC(
          0,
          cdp: 1,
          cp: 5,
          tc: 6,
          mc: 7,
          colorRange: 0,
          csp: 3,
          separateUv: 1,
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        profile.inject(c.$2.profile);
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
