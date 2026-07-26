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

List<int> _invDct4(List<int> c) {
  final m = _dctMatrix(4);
  int rs(int x) => (x + 2048) >> 12;
  List<int> inv1d(List<int> inp) => [
    for (var i = 0; i < 4; i++)
      rs(
        [for (var k = 0; k < 4; k++) m[k][i] * inp[k]].reduce((a, b) => a + b),
      ),
  ];
  final tmp = [for (var r = 0; r < 4; r++) List.filled(4, 0)];
  for (var col = 0; col < 4; col++) {
    final o = inv1d([for (var r = 0; r < 4; r++) c[r * 4 + col]]);
    for (var r = 0; r < 4; r++) {
      tmp[r][col] = o[r];
    }
  }
  final out = List.filled(16, 0);
  for (var r = 0; r < 4; r++) {
    final o = inv1d([for (var col = 0; col < 4; col++) tmp[r][col]]);
    for (var col = 0; col < 4; col++) {
      out[r * 4 + col] = o[col];
    }
  }
  return out;
}

int _clamp(int x) => x < 0 ? 0 : (x > 255 ? 255 : x);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborReconstruct4', () {
    late HarborReconstruct4 t;
    late Logic clk, coeffs, dcq, acq, mode, above, left, aboveLeft;

    Future<void> setUpDut() async {
      t = HarborReconstruct4();
      clk = SimpleClockGenerator(10).clk;
      coeffs = Logic(name: 'coeffs', width: 16 * 16);
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
      for (var i = 0; i < 16; i++) {
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

    // (name, mode, levels, dcq, acq, above8, left8)
    final aboveN = [120, 122, 124, 126, 128, 130, 132, 134];
    final leftN = [100, 102, 104, 106, 108, 110, 112, 114];

    final cases = <(String, int, List<int>)>[
      ('dc, dc-only coeff', 0, [40, ...List.filled(15, 0)]),
      (
        'dc, mixed coeffs',
        0,
        [30, -5, 3, 0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
      (
        'vertical, ac coeffs',
        1,
        [10, 4, -2, 0, -3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
      ('horizontal', 2, [20, -8, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
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

        // Reference: dequant -> invDct -> intra predict (mode).
        final deq = [
          for (var i = 0; i < 16; i++) c.$3[i] * (i == 0 ? dcQv : acQv),
        ];
        final residual = _invDct4(deq);
        int predAt(int r, int col) {
          switch (c.$2) {
            case 1: // vertical
              return aboveN[col];
            case 2: // horizontal
              return leftN[r];
            default: // dc
              final s =
                  aboveN.take(4).reduce((a, b) => a + b) +
                  leftN.take(4).reduce((a, b) => a + b);
              return (s + 4) >> 3;
          }
        }

        final v = t.output('recon').value.toBigInt();
        for (var r = 0; r < 4; r++) {
          for (var col = 0; col < 4; col++) {
            final got = ((v >> ((r * 8 + col) * 8)) & BigInt.from(0xFF))
                .toInt();
            final exp = _clamp(predAt(r, col) + residual[r * 4 + col]);
            expect(got, equals(exp), reason: '${c.$1} ($r,$col)');
          }
        }
        await Simulator.endSimulation();
      });
    }
  });
}
