import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Encode value with the read_golomb scheme: `zeros` leading 0s (= floor(log2
// (value+1))), a 1, then `zeros` value bits of (value+1).
List<int> _encode(int value) {
  final v = value + 1;
  final zeros = v.bitLength - 1;
  final bits = <int>[];
  for (var i = 0; i < zeros; i++) {
    bits.add(0);
  }
  bits.add(1);
  for (var i = zeros - 1; i >= 0; i--) {
    bits.add((v >> i) & 1);
  }
  return bits;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborGolombReader', () {
    Future<int> decode(List<int> bits) async {
      final g = HarborGolombReader();
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bitIn = Logic(name: 'bit_in');
      g.input('clk').srcConnection! <= clk;
      g.input('reset').srcConnection! <= reset;
      g.input('start').srcConnection! <= start;
      g.input('bit_in').srcConnection! <= bitIn;
      await g.build();

      reset.inject(1);
      start.inject(0);
      bitIn.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      var p = 0;
      for (var cyc = 0; cyc < 80; cyc++) {
        bitIn.inject(p < bits.length ? bits[p] : 0);
        final req = g.output('bit_req').value.toInt() == 1;
        if (g.output('done').value.toInt() == 1) break;
        await clk.nextPosedge;
        if (req) p++;
      }
      final v = g.output('value').value.toInt();
      await Simulator.endSimulation();
      return v;
    }

    for (final value in [0, 1, 2, 3, 4, 7, 8, 15, 16, 100, 1000, 65535]) {
      test('decodes golomb value $value', () async {
        final got = await decode(_encode(value));
        expect(got, equals(value));
      });
    }
  });
}
