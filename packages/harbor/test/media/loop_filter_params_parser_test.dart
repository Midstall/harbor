import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _LF {
  _LF({
    required this.numPlanes,
    required this.lossless,
    this.l0 = 0,
    this.l1 = 0,
    this.l2 = 0,
    this.l3 = 0,
    this.sharp = 0,
    this.deltaEnabled = 0,
    this.deltaUpdate = 0,
    this.refUpd = const [0, 0, 0, 0, 0, 0, 0, 0],
    this.refVal = const [0, 0, 0, 0, 0, 0, 0, 0],
    this.modeUpd = const [0, 0],
    this.modeVal = const [0, 0],
  });
  final int numPlanes,
      lossless,
      l0,
      l1,
      l2,
      l3,
      sharp,
      deltaEnabled,
      deltaUpdate;
  final List<int> refUpd, refVal, modeUpd, modeVal;
}

(List<int>, Map<String, int>) _build(_LF s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  const refDefaults = [1, 0, 0, 0, -1, 0, -1, -1];
  int s8(int v) => v & 0xff;

  final exp = <String, int>{};
  if (s.lossless == 1) {
    for (var i = 0; i < 4; i++) {
      exp['loop_filter_level_$i'] = 0;
    }
    exp['sharpness'] = 0;
    exp['delta_enabled'] = 0;
    exp['delta_update'] = 0;
    for (var i = 0; i < 8; i++) {
      exp['ref_delta_$i'] = s8(refDefaults[i]);
    }
    for (var i = 0; i < 2; i++) {
      exp['mode_delta_$i'] = 0;
    }
    exp['bits_consumed'] = 0;
    return (bits, exp);
  }

  f(s.l0, 6);
  f(s.l1, 6);
  var l2 = 0, l3 = 0;
  if (s.numPlanes > 1 && (s.l0 != 0 || s.l1 != 0)) {
    f(s.l2, 6);
    f(s.l3, 6);
    l2 = s.l2;
    l3 = s.l3;
  }
  f(s.sharp, 3);
  f(s.deltaEnabled, 1);
  var du = 0;
  final refOut = List<int>.from(refDefaults);
  final modeOut = [0, 0];
  if (s.deltaEnabled == 1) {
    f(s.deltaUpdate, 1);
    du = s.deltaUpdate;
    if (du == 1) {
      for (var i = 0; i < 8; i++) {
        f(s.refUpd[i], 1);
        if (s.refUpd[i] == 1) {
          f(s.refVal[i] & 0x7f, 7);
          refOut[i] = s.refVal[i];
        }
      }
      for (var i = 0; i < 2; i++) {
        f(s.modeUpd[i], 1);
        if (s.modeUpd[i] == 1) {
          f(s.modeVal[i] & 0x7f, 7);
          modeOut[i] = s.modeVal[i];
        }
      }
    }
  }

  exp['loop_filter_level_0'] = s.l0;
  exp['loop_filter_level_1'] = s.l1;
  exp['loop_filter_level_2'] = l2;
  exp['loop_filter_level_3'] = l3;
  exp['sharpness'] = s.sharp;
  exp['delta_enabled'] = s.deltaEnabled;
  exp['delta_update'] = du;
  for (var i = 0; i < 8; i++) {
    exp['ref_delta_$i'] = s8(refOut[i]);
  }
  for (var i = 0; i < 2; i++) {
    exp['mode_delta_$i'] = s8(modeOut[i]);
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

  group('HarborLoopFilterParamsParser', () {
    late HarborLoopFilterParamsParser p;
    late Logic clk, bytes, numPlanes, lossless;

    Future<void> setUpDut() async {
      p = HarborLoopFilterParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      numPlanes = Logic(name: 'num_planes', width: 2);
      lossless = Logic(name: 'coded_lossless', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('num_planes').srcConnection! <= numPlanes;
      p.input('coded_lossless').srcConnection! <= lossless;
      await p.build();
      bytes.inject(0);
      numPlanes.inject(3);
      lossless.inject(0);
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

    final cases = <(String, _LF)>[
      ('lossless skips all', _LF(numPlanes: 3, lossless: 1)),
      (
        'levels only, no chroma read',
        _LF(numPlanes: 3, lossless: 0, l0: 0, l1: 0, sharp: 2),
      ),
      (
        'y levels set, chroma read',
        _LF(
          numPlanes: 3,
          lossless: 0,
          l0: 32,
          l1: 28,
          l2: 20,
          l3: 18,
          sharp: 1,
        ),
      ),
      (
        'mono no chroma',
        _LF(numPlanes: 1, lossless: 0, l0: 40, l1: 40, sharp: 3),
      ),
      (
        'delta enabled no update',
        _LF(
          numPlanes: 3,
          lossless: 0,
          l0: 16,
          l1: 16,
          deltaEnabled: 1,
          deltaUpdate: 0,
        ),
      ),
      (
        'delta update some refs',
        _LF(
          numPlanes: 3,
          lossless: 0,
          l0: 24,
          l1: 24,
          deltaEnabled: 1,
          deltaUpdate: 1,
          refUpd: [1, 0, 0, 1, 0, 0, 0, 1],
          refVal: [3, 0, 0, -5, 0, 0, 0, 10],
          modeUpd: [1, 0],
          modeVal: [-7, 0],
        ),
      ),
      (
        'delta update all',
        _LF(
          numPlanes: 3,
          lossless: 0,
          l0: 50,
          l1: 48,
          l2: 30,
          l3: 30,
          sharp: 4,
          deltaEnabled: 1,
          deltaUpdate: 1,
          refUpd: [1, 1, 1, 1, 1, 1, 1, 1],
          refVal: [1, -2, 3, -4, 5, -6, 7, -8],
          modeUpd: [1, 1],
          modeVal: [12, -20],
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        numPlanes.inject(c.$2.numPlanes);
        lossless.inject(c.$2.lossless);
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
