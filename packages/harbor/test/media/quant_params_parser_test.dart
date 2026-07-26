import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Semantic choices for quantization_params. The encoder emits spec-order bits.
class _QP {
  _QP({
    required this.numPlanes,
    required this.separateUv,
    required this.baseQ,
    this.yDc = 0,
    this.uDc = 0,
    this.uAc = 0,
    this.vDc = 0,
    this.vAc = 0,
    this.diffUv = 0,
    this.usingQm = 0,
    this.qmY = 0,
    this.qmU = 0,
    this.qmV = 0,
  });
  final int numPlanes, separateUv, baseQ;
  final int yDc, uDc, uAc, vDc, vAc, diffUv;
  final int usingQm, qmY, qmU, qmV;
}

(List<int>, Map<String, int>) _build(_QP s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  // read_delta_q encodes delta_coded then (if nonzero) su(7).
  void deltaQ(int v) {
    if (v != 0) {
      f(1, 1);
      f(v & 0x7f, 7); // su(7) two's complement
    } else {
      f(0, 1);
    }
  }

  f(s.baseQ, 8);
  deltaQ(s.yDc);
  var uDc = 0, uAc = 0, vDc = 0, vAc = 0;
  if (s.numPlanes > 1) {
    if (s.separateUv == 1) f(s.diffUv, 1);
    final dUv = s.separateUv == 1 ? s.diffUv : 0;
    deltaQ(s.uDc);
    deltaQ(s.uAc);
    uDc = s.uDc;
    uAc = s.uAc;
    if (dUv == 1) {
      deltaQ(s.vDc);
      deltaQ(s.vAc);
      vDc = s.vDc;
      vAc = s.vAc;
    } else {
      vDc = s.uDc;
      vAc = s.uAc;
    }
  }
  f(s.usingQm, 1);
  var qmY = 0, qmU = 0, qmV = 0;
  if (s.usingQm == 1) {
    f(s.qmY, 4);
    f(s.qmU, 4);
    qmY = s.qmY;
    qmU = s.qmU;
    if (s.separateUv == 1) {
      f(s.qmV, 4);
      qmV = s.qmV;
    } else {
      qmV = s.qmU;
    }
  }

  int s8(int v) => v & 0xff; // expected delta as 8-bit two's complement

  return (
    bits,
    {
      'base_q_idx': s.baseQ,
      'delta_q_y_dc': s8(s.yDc),
      'delta_q_u_dc': s8(uDc),
      'delta_q_u_ac': s8(uAc),
      'delta_q_v_dc': s8(vDc),
      'delta_q_v_ac': s8(vAc),
      'using_qmatrix': s.usingQm,
      'qm_y': qmY,
      'qm_u': qmU,
      'qm_v': qmV,
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

  group('HarborQuantParamsParser', () {
    late HarborQuantParamsParser p;
    late Logic clk, bytes, numPlanes, separateUv;

    Future<void> setUpDut() async {
      p = HarborQuantParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      numPlanes = Logic(name: 'num_planes', width: 2);
      separateUv = Logic(name: 'separate_uv_delta_q', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('num_planes').srcConnection! <= numPlanes;
      p.input('separate_uv_delta_q').srcConnection! <= separateUv;
      await p.build();
      bytes.inject(0);
      numPlanes.inject(3);
      separateUv.inject(0);
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

    final cases = <(String, _QP)>[
      ('simplest: q only', _QP(numPlanes: 3, separateUv: 0, baseQ: 128)),
      ('with luma delta', _QP(numPlanes: 3, separateUv: 0, baseQ: 64, yDc: 5)),
      (
        'chroma deltas shared',
        _QP(numPlanes: 3, separateUv: 0, baseQ: 100, yDc: -3, uDc: 7, uAc: -10),
      ),
      (
        'separate uv, diff',
        _QP(
          numPlanes: 3,
          separateUv: 1,
          baseQ: 90,
          diffUv: 1,
          uDc: 4,
          uAc: -8,
          vDc: 12,
          vAc: -20,
        ),
      ),
      (
        'separate uv, no diff',
        _QP(numPlanes: 3, separateUv: 1, baseQ: 90, diffUv: 0, uDc: 4, uAc: -8),
      ),
      ('monochrome', _QP(numPlanes: 1, separateUv: 0, baseQ: 200, yDc: -1)),
      (
        'qmatrix on, shared v',
        _QP(
          numPlanes: 3,
          separateUv: 0,
          baseQ: 50,
          usingQm: 1,
          qmY: 10,
          qmU: 6,
        ),
      ),
      (
        'qmatrix on, separate v',
        _QP(
          numPlanes: 3,
          separateUv: 1,
          baseQ: 50,
          usingQm: 1,
          qmY: 9,
          qmU: 5,
          qmV: 12,
        ),
      ),
      (
        'extreme deltas',
        _QP(
          numPlanes: 3,
          separateUv: 1,
          baseQ: 255,
          diffUv: 1,
          yDc: -64,
          uDc: 63,
          uAc: -64,
          vDc: 63,
          vAc: -1,
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
