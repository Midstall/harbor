import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Contiguous encoder for quant -> loop_filter -> cdef -> lr.
class _Cfg {
  _Cfg({
    required this.baseQ,
    required this.l0,
    required this.l1,
    this.l2 = 0,
    this.l3 = 0,
    this.sharp = 0,
    required this.dampingM3,
    required this.cdefBits,
    required this.yPri,
    required this.ySec,
    required this.uvPri,
    required this.uvSec,
    required this.lrType,
    this.shiftBit = 0,
    this.extraBit = 0,
    this.uvBit = 0,
  });
  final int numPlanes = 3, separateUv = 0, subx = 1, suby = 1, use128 = 0;
  final int baseQ, l0, l1, l2, l3, sharp, dampingM3, cdefBits;
  final List<int> yPri, ySec, uvPri, uvSec, lrType;
  final int shiftBit, extraBit, uvBit;
}

(List<int>, Map<String, int>) _build(_Cfg s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  // quant (no deltas, no qmatrix).
  f(s.baseQ, 8);
  f(0, 1); // y_dc delta_coded
  if (s.numPlanes > 1) {
    if (s.separateUv == 1) f(0, 1); // diff_uv (0)
    f(0, 1); // u_dc
    f(0, 1); // u_ac
  }
  f(0, 1); // using_qmatrix

  // loop_filter (delta disabled).
  f(s.l0, 6);
  f(s.l1, 6);
  if (s.numPlanes > 1 && (s.l0 != 0 || s.l1 != 0)) {
    f(s.l2, 6);
    f(s.l3, 6);
  }
  f(s.sharp, 3);
  f(0, 1); // delta_enabled

  // cdef.
  f(s.dampingM3, 2);
  f(s.cdefBits, 2);
  final n = 1 << s.cdefBits;
  for (var i = 0; i < n; i++) {
    f(s.yPri[i], 4);
    f(s.ySec[i], 2);
    if (s.numPlanes > 1) {
      f(s.uvPri[i], 4);
      f(s.uvSec[i], 2);
    }
  }

  // lr.
  const remap = [0, 3, 1, 2];
  final frt = [0, 0, 0];
  for (var i = 0; i < s.numPlanes; i++) {
    f(s.lrType[i], 2);
    frt[i] = remap[s.lrType[i]];
  }
  final usesLr = frt.any((t) => t != 0) ? 1 : 0;
  final usesChroma = (frt[1] != 0 || frt[2] != 0) ? 1 : 0;
  if (usesLr == 1) {
    if (s.use128 == 1) {
      f(s.shiftBit, 1);
    } else {
      f(s.shiftBit, 1);
      if (s.shiftBit == 1) f(s.extraBit, 1);
    }
    if (s.subx == 1 && s.suby == 1 && usesChroma == 1) f(s.uvBit, 1);
  }

  return (
    bits,
    {
      'base_q_idx': s.baseQ,
      'loop_filter_level_0': s.l0,
      'loop_filter_level_1': s.l1,
      'cdef_bits': s.cdefBits,
      'cdef_damping': s.dampingM3 + 3,
      'frame_restoration_type_0': frt[0],
      'uses_lr': usesLr,
      'bits_consumed': bits.length,
    },
  );
}

List<int> _bytes(List<int> bits) {
  final out = List.filled(64, 0);
  for (var i = 0; i < bits.length && i < 512; i++) {
    if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborFilterConfigParser', () {
    late HarborFilterConfigParser p;
    late Logic clk, bytes;
    late Logic numPlanes,
        separateUv,
        lossless,
        cdefDis,
        lrDis,
        subx,
        suby,
        use128;

    Future<void> setUpDut() async {
      p = HarborFilterConfigParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 64 * 8);
      numPlanes = Logic(name: 'num_planes', width: 2);
      separateUv = Logic(name: 'separate_uv_delta_q', width: 1);
      lossless = Logic(name: 'coded_lossless', width: 1);
      cdefDis = Logic(name: 'cdef_disabled', width: 1);
      lrDis = Logic(name: 'lr_disabled', width: 1);
      subx = Logic(name: 'subsampling_x', width: 1);
      suby = Logic(name: 'subsampling_y', width: 1);
      use128 = Logic(name: 'use_128x128_superblock', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('num_planes').srcConnection! <= numPlanes;
      p.input('separate_uv_delta_q').srcConnection! <= separateUv;
      p.input('coded_lossless').srcConnection! <= lossless;
      p.input('cdef_disabled').srcConnection! <= cdefDis;
      p.input('lr_disabled').srcConnection! <= lrDis;
      p.input('subsampling_x').srcConnection! <= subx;
      p.input('subsampling_y').srcConnection! <= suby;
      p.input('use_128x128_superblock').srcConnection! <= use128;
      await p.build();
      bytes.inject(0);
      numPlanes.inject(3);
      separateUv.inject(0);
      lossless.inject(0);
      cdefDis.inject(0);
      lrDis.inject(0);
      subx.inject(1);
      suby.inject(1);
      use128.inject(0);
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

    final cases = <(String, _Cfg)>[
      (
        'typical 1 cdef set, wiener',
        _Cfg(
          baseQ: 128,
          l0: 32,
          l1: 28,
          l2: 20,
          l3: 18,
          sharp: 1,
          dampingM3: 1,
          cdefBits: 0,
          yPri: [5],
          ySec: [2],
          uvPri: [3],
          uvSec: [1],
          lrType: [2, 0, 0],
          shiftBit: 0,
        ),
      ),
      (
        '4 cdef sets, sgr switchable',
        _Cfg(
          baseQ: 64,
          l0: 40,
          l1: 40,
          l2: 30,
          l3: 30,
          sharp: 2,
          dampingM3: 2,
          cdefBits: 2,
          yPri: [1, 5, 9, 13, 0, 0, 0, 0],
          ySec: [0, 1, 2, 3, 0, 0, 0, 0],
          uvPri: [2, 6, 10, 14, 0, 0, 0, 0],
          uvSec: [1, 2, 3, 0, 0, 0, 0, 0],
          lrType: [1, 3, 3],
          shiftBit: 1,
          extraBit: 0,
          uvBit: 1,
        ),
      ),
      (
        'no loop filter, no lr',
        _Cfg(
          baseQ: 200,
          l0: 0,
          l1: 0,
          sharp: 0,
          dampingM3: 0,
          cdefBits: 0,
          yPri: [0],
          ySec: [0],
          uvPri: [0],
          uvSec: [0],
          lrType: [0, 0, 0],
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        numPlanes.inject(c.$2.numPlanes);
        separateUv.inject(c.$2.separateUv);
        subx.inject(c.$2.subx);
        suby.inject(c.$2.suby);
        use128.inject(c.$2.use128);
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
