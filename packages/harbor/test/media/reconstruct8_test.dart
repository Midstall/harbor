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

int _clamp(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborReconstruct8', () {
    late HarborReconstruct8 t;
    late Logic clk, coeffs, dcq, acq, mode, above, left, aboveLeft;

    Future<void> setUpDut() async {
      t = HarborReconstruct8();
      clk = SimpleClockGenerator(10).clk;
      coeffs = Logic(name: 'coeffs', width: 64 * 16);
      dcq = Logic(name: 'dc_q', width: 8);
      acq = Logic(name: 'ac_q', width: 8);
      mode = Logic(name: 'mode', width: 3);
      above = Logic(name: 'above', width: 64);
      left = Logic(name: 'left', width: 64);
      aboveLeft = Logic(name: 'above_left', width: 8);
      t.input('coeffs').srcConnection! <= coeffs;
      t.input('dc_q').srcConnection! <= dcq;
      t.input('ac_q').srcConnection! <= acq;
      t.input('mode').srcConnection! <= mode;
      t.input('above').srcConnection! <= above;
      t.input('left').srcConnection! <= left;
      t.input('above_left').srcConnection! <= aboveLeft;
      await t.build();
      coeffs.inject(0);
      dcq.inject(8);
      acq.inject(8);
      mode.inject(0);
      above.inject(0);
      left.inject(0);
      aboveLeft.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packC(List<int> c) {
      var v = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        v |= BigInt.from(c[i] & 0xFFFF) << (i * 16);
      }
      return v;
    }

    BigInt packP(List<int> p) {
      var v = BigInt.zero;
      for (var i = 0; i < p.length; i++) {
        v |= BigInt.from(p[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    final aboveN = [for (var i = 0; i < 8; i++) 120 + i * 2];
    final leftN = [for (var i = 0; i < 8; i++) 100 + i * 2];

    final cases = <(String, int, List<int>)>[
      ('dc, dc coeff', 0, [80, ...List.filled(63, 0)]),
      ('vertical, ac', 1, [10, 5, -3, 0, 2, ...List.filled(59, 0)]),
      ('horizontal, ac', 2, [20, -6, 0, 4, ...List.filled(60, 0)]),
    ];

    for (final c in cases) {
      test('reconstructs: ${c.$1}', () async {
        await setUpDut();
        const dcQv = 16, acQv = 12;
        coeffs.inject(packC(c.$3));
        dcq.inject(dcQv);
        acq.inject(acQv);
        mode.inject(c.$2);
        above.inject(packP(aboveN));
        left.inject(packP(leftN));
        aboveLeft.inject(118);
        await clk.nextPosedge;

        final deq = [
          for (var i = 0; i < 64; i++) c.$3[i] * (i == 0 ? dcQv : acQv),
        ];
        final residual = _invDct8(deq);
        int predAt(int r, int col) {
          switch (c.$2) {
            case 1:
              return aboveN[col];
            case 2:
              return leftN[r];
            default:
              final s =
                  aboveN.reduce((a, b) => a + b) +
                  leftN.reduce((a, b) => a + b);
              return (s + 8) >> 4;
          }
        }

        final v = t.output('recon').value.toBigInt();
        for (var r = 0; r < 8; r++) {
          for (var col = 0; col < 8; col++) {
            final got = ((v >> ((r * 8 + col) * 8)) & BigInt.from(0xFF))
                .toInt();
            final exp = _clamp(predAt(r, col) + residual[r * 8 + col]);
            expect(got, equals(exp), reason: '${c.$1} ($r,$col)');
          }
        }
        await Simulator.endSimulation();
      });
    }
  });
}
