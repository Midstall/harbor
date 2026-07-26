import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _DP {
  _DP({
    required this.baseQ,
    required this.allowIntrabc,
    this.dqPresent = 0,
    this.dqRes = 0,
    this.dlfPresent = 0,
    this.dlfRes = 0,
    this.dlfMulti = 0,
  });
  final int baseQ, allowIntrabc, dqPresent, dqRes, dlfPresent, dlfRes, dlfMulti;
}

(List<int>, Map<String, int>) _build(_DP s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  var dqp = 0, dqr = 0, dlp = 0, dlr = 0, dlm = 0;
  if (s.baseQ > 0) {
    f(s.dqPresent, 1);
    dqp = s.dqPresent;
  }
  if (dqp == 1) {
    f(s.dqRes, 2);
    dqr = s.dqRes;
  }
  if (dqp == 1) {
    if (s.allowIntrabc == 0) {
      f(s.dlfPresent, 1);
      dlp = s.dlfPresent;
    }
    if (dlp == 1) {
      f(s.dlfRes, 2);
      f(s.dlfMulti, 1);
      dlr = s.dlfRes;
      dlm = s.dlfMulti;
    }
  }

  return (
    bits,
    {
      'delta_q_present': dqp,
      'delta_q_res': dqr,
      'delta_lf_present': dlp,
      'delta_lf_res': dlr,
      'delta_lf_multi': dlm,
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

  group('HarborDeltaParamsParser', () {
    late HarborDeltaParamsParser p;
    late Logic clk, bytes, baseQ, intrabc;

    Future<void> setUpDut() async {
      p = HarborDeltaParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      baseQ = Logic(name: 'base_q_idx', width: 8);
      intrabc = Logic(name: 'allow_intrabc', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('base_q_idx').srcConnection! <= baseQ;
      p.input('allow_intrabc').srcConnection! <= intrabc;
      await p.build();
      bytes.inject(0);
      baseQ.inject(0);
      intrabc.inject(0);
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

    final cases = <(String, _DP)>[
      ('base_q 0 reads nothing', _DP(baseQ: 0, allowIntrabc: 0)),
      ('present off', _DP(baseQ: 100, allowIntrabc: 0, dqPresent: 0)),
      (
        'dq on, no lf',
        _DP(baseQ: 100, allowIntrabc: 0, dqPresent: 1, dqRes: 2, dlfPresent: 0),
      ),
      (
        'dq + lf full',
        _DP(
          baseQ: 64,
          allowIntrabc: 0,
          dqPresent: 1,
          dqRes: 1,
          dlfPresent: 1,
          dlfRes: 3,
          dlfMulti: 1,
        ),
      ),
      (
        'intrabc skips lf present',
        _DP(baseQ: 64, allowIntrabc: 1, dqPresent: 1, dqRes: 2),
      ),
      (
        'lf res no multi path',
        _DP(
          baseQ: 200,
          allowIntrabc: 0,
          dqPresent: 1,
          dqRes: 0,
          dlfPresent: 1,
          dlfRes: 2,
          dlfMulti: 0,
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        baseQ.inject(c.$2.baseQ);
        intrabc.inject(c.$2.allowIntrabc);
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
