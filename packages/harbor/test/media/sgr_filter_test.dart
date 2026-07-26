import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Reference SGR self-guided box filter, mirroring the RTL fixed-point exactly.
int _sgr(List<int> win, int s, int radius) {
  final side = 2 * radius + 1;
  final n = side * side;
  final centre = n ~/ 2;
  const recipBits = 12;
  const mtableBits = 20;
  final oneOverN = ((1 << recipBits) + n ~/ 2) ~/ n;

  var sum = 0, sumsq = 0;
  for (final p in win) {
    sum += p;
    sumsq += p * p;
  }
  final varNum = sumsq * n - sum * sum;
  var z = (varNum * s) >> mtableBits;
  if (z > 255) z = 255;
  final a2 = (256 * z + (z + 1) ~/ 2) ~/ (z + 1);
  final mean = (sum * oneOverN + (1 << (recipBits - 1))) >> recipBits;
  final blend = a2 * win[centre] + (256 - a2) * mean;
  var out = (blend + 128) >> 8;
  if (out > 255) out = 255;
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSgrFilter (radius 1, 3x3)', () {
    late HarborSgrFilter sgr;
    late Logic clk, window, s;

    Future<void> setUpDut() async {
      sgr = HarborSgrFilter();
      clk = SimpleClockGenerator(10).clk;
      window = Logic(name: 'window', width: 9 * 8);
      s = Logic(name: 's', width: 8);
      sgr.input('window').srcConnection! <= window;
      sgr.input('s').srcConnection! <= s;
      await sgr.build();
      window.inject(0);
      s.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packWin(List<int> p) {
      var v = BigInt.zero;
      for (var i = 0; i < p.length; i++) {
        v |= BigInt.from(p[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    final cases = <(String, List<int>, int)>[
      ('flat field', [for (var i = 0; i < 9; i++) 128], 30),
      ('edge step', [40, 40, 40, 40, 200, 200, 40, 200, 200], 30),
      ('gentle ramp', [for (var i = 0; i < 9; i++) 100 + i * 5], 30),
      ('texture', [120, 60, 200, 30, 150, 90, 210, 45, 175], 50),
      ('low noise param', [70, 80, 75, 90, 85, 95, 60, 100, 88], 5),
      ('high noise param', [70, 80, 75, 90, 85, 95, 60, 100, 88], 200),
      ('bright clamp', [for (var i = 0; i < 9; i++) 250 + (i % 5)], 30),
    ];

    for (final c in cases) {
      test('matches the reference: ${c.$1}', () async {
        await setUpDut();
        window.inject(packWin(c.$2));
        s.inject(c.$3 & 0xFF);
        await clk.nextPosedge;
        final got = sgr.output('out').value.toInt();
        expect(got, equals(_sgr(c.$2, c.$3, 1)), reason: c.$1);
        await Simulator.endSimulation();
      });
    }
  });

  group('HarborSgrFilter (radius 2, 5x5)', () {
    late HarborSgrFilter sgr;
    late Logic clk, window, s;

    Future<void> setUpDut() async {
      sgr = HarborSgrFilter(radius: 2);
      clk = SimpleClockGenerator(10).clk;
      window = Logic(name: 'window', width: 25 * 8);
      s = Logic(name: 's', width: 8);
      sgr.input('window').srcConnection! <= window;
      sgr.input('s').srcConnection! <= s;
      await sgr.build();
      window.inject(0);
      s.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packWin(List<int> p) {
      var v = BigInt.zero;
      for (var i = 0; i < p.length; i++) {
        v |= BigInt.from(p[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    final cases = <(String, List<int>, int)>[
      ('flat field', [for (var i = 0; i < 25; i++) 96], 40),
      (
        'diagonal edge',
        [
          for (var r = 0; r < 5; r++)
            for (var c = 0; c < 5; c++) (r + c) < 4 ? 50 : 210,
        ],
        40,
      ),
      ('texture', [for (var i = 0; i < 25; i++) (i * 37 + 17) % 256], 60),
    ];

    for (final c in cases) {
      test('matches the reference: ${c.$1}', () async {
        await setUpDut();
        window.inject(packWin(c.$2));
        s.inject(c.$3 & 0xFF);
        await clk.nextPosedge;
        final got = sgr.output('out').value.toInt();
        expect(got, equals(_sgr(c.$2, c.$3, 2)), reason: c.$1);
        await Simulator.endSimulation();
      });
    }
  });
}
