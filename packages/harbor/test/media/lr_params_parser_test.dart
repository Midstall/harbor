import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _LR {
  _LR({
    required this.numPlanes,
    required this.subx,
    required this.suby,
    required this.use128,
    required this.disabled,
    this.lrType = const [0, 0, 0],
    this.shiftBit = 0,
    this.extraBit = 0,
    this.uvBit = 0,
  });
  final int numPlanes, subx, suby, use128, disabled;
  final List<int> lrType;
  final int shiftBit, extraBit, uvBit;
}

(List<int>, Map<String, int>) _build(_LR s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  const remap = [0, 3, 1, 2]; // RESTORE_NONE/SWITCHABLE/WIENER/SGRPROJ
  final exp = <String, int>{};
  final frt = [0, 0, 0];
  if (s.disabled == 1) {
    for (var i = 0; i < 3; i++) {
      exp['frame_restoration_type_$i'] = 0;
    }
    exp['uses_lr'] = 0;
    exp['lr_unit_shift'] = 0;
    exp['lr_uv_shift'] = 0;
    exp['restoration_size'] = 256 >> 2; // 64
    exp['bits_consumed'] = 0;
    return (bits, exp);
  }

  for (var i = 0; i < s.numPlanes; i++) {
    f(s.lrType[i], 2);
    frt[i] = remap[s.lrType[i]];
  }
  final usesLr = frt.any((t) => t != 0) ? 1 : 0;
  final usesChroma = (frt[1] != 0 || frt[2] != 0) ? 1 : 0;
  var unitShift = 0, uvShift = 0;
  if (usesLr == 1) {
    if (s.use128 == 1) {
      f(s.shiftBit, 1);
      unitShift = s.shiftBit + 1;
    } else {
      f(s.shiftBit, 1);
      if (s.shiftBit == 1) {
        f(s.extraBit, 1);
        unitShift = 1 + s.extraBit;
      } else {
        unitShift = 0;
      }
    }
    if (s.subx == 1 && s.suby == 1 && usesChroma == 1) {
      f(s.uvBit, 1);
      uvShift = s.uvBit;
    }
  }

  for (var i = 0; i < 3; i++) {
    exp['frame_restoration_type_$i'] = frt[i];
  }
  exp['uses_lr'] = usesLr;
  exp['lr_unit_shift'] = unitShift;
  exp['lr_uv_shift'] = uvShift;
  exp['restoration_size'] = 256 >> (2 - unitShift);
  exp['bits_consumed'] = bits.length;
  return (bits, exp);
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

  group('HarborLrParamsParser', () {
    late HarborLrParamsParser p;
    late Logic clk, bytes, numPlanes, subx, suby, use128, disabled;

    Future<void> setUpDut() async {
      p = HarborLrParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      numPlanes = Logic(name: 'num_planes', width: 2);
      subx = Logic(name: 'subsampling_x', width: 1);
      suby = Logic(name: 'subsampling_y', width: 1);
      use128 = Logic(name: 'use_128x128_superblock', width: 1);
      disabled = Logic(name: 'lr_disabled', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('num_planes').srcConnection! <= numPlanes;
      p.input('subsampling_x').srcConnection! <= subx;
      p.input('subsampling_y').srcConnection! <= suby;
      p.input('use_128x128_superblock').srcConnection! <= use128;
      p.input('lr_disabled').srcConnection! <= disabled;
      await p.build();
      bytes.inject(0);
      numPlanes.inject(3);
      subx.inject(1);
      suby.inject(1);
      use128.inject(0);
      disabled.inject(0);
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

    final cases = <(String, _LR)>[
      ('disabled', _LR(numPlanes: 3, subx: 1, suby: 1, use128: 0, disabled: 1)),
      (
        'all none',
        _LR(
          numPlanes: 3,
          subx: 1,
          suby: 1,
          use128: 0,
          disabled: 0,
          lrType: [0, 0, 0],
        ),
      ),
      (
        'wiener luma only',
        _LR(
          numPlanes: 3,
          subx: 1,
          suby: 1,
          use128: 0,
          disabled: 0,
          lrType: [2, 0, 0],
          shiftBit: 0,
        ),
      ),
      (
        'sgr luma, shift 2',
        _LR(
          numPlanes: 3,
          subx: 1,
          suby: 1,
          use128: 0,
          disabled: 0,
          lrType: [3, 0, 0],
          shiftBit: 1,
          extraBit: 1,
        ),
      ),
      (
        'switchable all, chroma shift',
        _LR(
          numPlanes: 3,
          subx: 1,
          suby: 1,
          use128: 0,
          disabled: 0,
          lrType: [1, 2, 3],
          shiftBit: 1,
          extraBit: 0,
          uvBit: 1,
        ),
      ),
      (
        '128 superblock',
        _LR(
          numPlanes: 3,
          subx: 1,
          suby: 1,
          use128: 1,
          disabled: 0,
          lrType: [2, 2, 2],
          shiftBit: 1,
          uvBit: 0,
        ),
      ),
      (
        '444 no chroma shift',
        _LR(
          numPlanes: 3,
          subx: 0,
          suby: 0,
          use128: 0,
          disabled: 0,
          lrType: [2, 2, 2],
          shiftBit: 0,
        ),
      ),
      (
        'mono wiener',
        _LR(
          numPlanes: 1,
          subx: 1,
          suby: 1,
          use128: 0,
          disabled: 0,
          lrType: [2, 0, 0],
          shiftBit: 1,
          extraBit: 1,
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        numPlanes.inject(c.$2.numPlanes);
        subx.inject(c.$2.subx);
        suby.inject(c.$2.suby);
        use128.inject(c.$2.use128);
        disabled.inject(c.$2.disabled);
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
