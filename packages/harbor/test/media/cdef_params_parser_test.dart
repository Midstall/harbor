import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _CDEF {
  _CDEF({
    required this.numPlanes,
    required this.disabled,
    this.dampingM3 = 0,
    this.cdefBits = 0,
    this.yPri = const [],
    this.ySec = const [],
    this.uvPri = const [],
    this.uvSec = const [],
  });
  final int numPlanes, disabled, dampingM3, cdefBits;
  final List<int> yPri, ySec, uvPri, uvSec;
}

(List<int>, Map<String, int>) _build(_CDEF s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  final exp = <String, int>{};
  if (s.disabled == 1) {
    exp['cdef_damping'] = 3;
    exp['cdef_bits'] = 0;
    for (var i = 0; i < 8; i++) {
      exp['y_pri_$i'] = 0;
      exp['y_sec_$i'] = 0;
      exp['uv_pri_$i'] = 0;
      exp['uv_sec_$i'] = 0;
    }
    exp['bits_consumed'] = 0;
    return (bits, exp);
  }

  f(s.dampingM3, 2);
  f(s.cdefBits, 2);
  final n = 1 << s.cdefBits;
  final yp = List<int>.filled(8, 0),
      ys = List<int>.filled(8, 0),
      up = List<int>.filled(8, 0),
      us = List<int>.filled(8, 0);
  for (var i = 0; i < n; i++) {
    f(s.yPri[i], 4);
    f(s.ySec[i], 2);
    yp[i] = s.yPri[i];
    ys[i] = s.ySec[i] == 3 ? 4 : s.ySec[i];
    if (s.numPlanes > 1) {
      f(s.uvPri[i], 4);
      f(s.uvSec[i], 2);
      up[i] = s.uvPri[i];
      us[i] = s.uvSec[i] == 3 ? 4 : s.uvSec[i];
    }
  }

  exp['cdef_damping'] = s.dampingM3 + 3;
  exp['cdef_bits'] = s.cdefBits;
  for (var i = 0; i < 8; i++) {
    exp['y_pri_$i'] = yp[i];
    exp['y_sec_$i'] = ys[i];
    exp['uv_pri_$i'] = up[i];
    exp['uv_sec_$i'] = us[i];
  }
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

  group('HarborCdefParamsParser', () {
    late HarborCdefParamsParser p;
    late Logic clk, bytes, numPlanes, disabled;

    Future<void> setUpDut() async {
      p = HarborCdefParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      numPlanes = Logic(name: 'num_planes', width: 2);
      disabled = Logic(name: 'cdef_disabled', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('num_planes').srcConnection! <= numPlanes;
      p.input('cdef_disabled').srcConnection! <= disabled;
      await p.build();
      bytes.inject(0);
      numPlanes.inject(3);
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

    final cases = <(String, _CDEF)>[
      ('disabled', _CDEF(numPlanes: 3, disabled: 1)),
      (
        '1 strength set',
        _CDEF(
          numPlanes: 3,
          disabled: 0,
          dampingM3: 1,
          cdefBits: 0,
          yPri: [5],
          ySec: [2],
          uvPri: [3],
          uvSec: [1],
        ),
      ),
      (
        'sec==3 maps to 4',
        _CDEF(
          numPlanes: 3,
          disabled: 0,
          dampingM3: 0,
          cdefBits: 0,
          yPri: [9],
          ySec: [3],
          uvPri: [4],
          uvSec: [3],
        ),
      ),
      (
        '4 strength sets',
        _CDEF(
          numPlanes: 3,
          disabled: 0,
          dampingM3: 2,
          cdefBits: 2,
          yPri: [1, 5, 9, 13, 0, 0, 0, 0],
          ySec: [0, 1, 2, 3, 0, 0, 0, 0],
          uvPri: [2, 6, 10, 14, 0, 0, 0, 0],
          uvSec: [1, 2, 3, 0, 0, 0, 0, 0],
        ),
      ),
      (
        'mono, 8 sets',
        _CDEF(
          numPlanes: 1,
          disabled: 0,
          dampingM3: 3,
          cdefBits: 3,
          yPri: [1, 2, 3, 4, 5, 6, 7, 8],
          ySec: [0, 1, 2, 3, 0, 1, 2, 3],
          uvPri: List.filled(8, 0),
          uvSec: List.filled(8, 0),
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        numPlanes.inject(c.$2.numPlanes);
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
