import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

List<List<int>> _dctMatrix(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        ((k == 0 ? sqrt(1 / n) : sqrt(2 / n)) *
                cos((2 * i + 1) * k * pi / (2 * n)) *
                4096)
            .round(),
    ],
];

List<int> _invDct8(List<int> c) {
  final m = _dctMatrix(8);
  int rs(int x) => (x + 2048) >> 12;
  List<int> inv1d(List<int> inp) => [
    for (var i = 0; i < 8; i++)
      rs(
        [for (var k = 0; k < 8; k++) m[k][i] * inp[k]].reduce((a, b) => a + b),
      ),
  ];
  final tmp = [for (var r = 0; r < 8; r++) List.filled(8, 0)];
  for (var col = 0; col < 8; col++) {
    final o = inv1d([for (var r = 0; r < 8; r++) c[r * 8 + col]]);
    for (var r = 0; r < 8; r++) {
      tmp[r][col] = o[r];
    }
  }
  final out = List.filled(64, 0);
  for (var r = 0; r < 8; r++) {
    final o = inv1d([for (var col = 0; col < 8; col++) tmp[r][col]]);
    for (var col = 0; col < 8; col++) {
      out[r * 8 + col] = o[col];
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborInverseDct8', () {
    late HarborInverseDct8 t;
    late Logic clk, coeffs;

    Future<void> setUpDut() async {
      t = HarborInverseDct8();
      clk = SimpleClockGenerator(10).clk;
      coeffs = Logic(name: 'coeffs', width: 64 * 16);
      t.input('coeffs').srcConnection! <= coeffs;
      await t.build();
      coeffs.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt pack(List<int> c) {
      var v = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        v |= BigInt.from(c[i] & 0xFFFF) << (i * 16);
      }
      return v;
    }

    final cases = <(String, List<int>)>[
      ('dc only', [300, ...List.filled(63, 0)]),
      ('few ac', [0, 60, 0, 0, 0, 0, 0, 0, -40, ...List.filled(55, 0)]),
      ('ramp', [for (var i = 0; i < 64; i++) (i * 5 - 120)]),
      (
        'sparse mix',
        [for (var i = 0; i < 64; i++) (i % 7 == 0 ? (i - 30) * 2 : 0)],
      ),
    ];

    for (final c in cases) {
      test('matches the reference: ${c.$1}', () async {
        await setUpDut();
        coeffs.inject(pack(c.$2));
        await clk.nextPosedge;
        final v = t.output('residual').value.toBigInt();
        final got = [
          for (var i = 0; i < 64; i++)
            (() {
              final raw = ((v >> (i * 16)) & BigInt.from(0xFFFF)).toInt();
              return raw >= 0x8000 ? raw - 0x10000 : raw;
            })(),
        ];
        expect(got, equals(_invDct8(c.$2)), reason: c.$1);
        await Simulator.endSimulation();
      });
    }
  });
}
