import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// libaom default_scan_4x4 (raster indices).
const _scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];

List<List<int>> _scan(int n) {
  final order = <List<int>>[];
  for (var d = 0; d < 2 * n - 1; d++) {
    final lo = (d - n + 1) < 0 ? 0 : d - n + 1;
    final hi = d < n - 1 ? d : n - 1;
    if (d.isEven) {
      for (var row = hi; row >= lo; row--) {
        order.add([row, d - row]);
      }
    } else {
      for (var row = lo; row <= hi; row++) {
        order.add([row, d - row]);
      }
    }
  }
  return order;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborScanOrder', () {
    late HarborScanOrder p;
    late Logic clk, pos, log2size;

    Future<void> setUpDut() async {
      p = HarborScanOrder();
      clk = SimpleClockGenerator(10).clk;
      pos = Logic(name: 'pos', width: 10);
      log2size = Logic(name: 'log2size', width: 3);
      p.input('pos').srcConnection! <= pos;
      p.input('log2size').srcConnection! <= log2size;
      await p.build();
      pos.inject(0);
      log2size.inject(2);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('4x4 matches libaom default_scan_4x4', () async {
      await setUpDut();
      log2size.inject(2);
      for (var i = 0; i < 16; i++) {
        pos.inject(i);
        await clk.nextPosedge;
        final r = p.output('row').value.toInt();
        final c = p.output('col').value.toInt();
        expect(r * 4 + c, equals(_scan4[i]), reason: 'pos $i');
      }
      await Simulator.endSimulation();
    });

    test('8x8 and 16x16 match the generated zigzag scan', () async {
      await setUpDut();
      for (final l in [3, 4]) {
        final n = 1 << l;
        final order = _scan(n);
        log2size.inject(l);
        for (var i = 0; i < n * n; i++) {
          pos.inject(i);
          await clk.nextPosedge;
          expect(
            p.output('row').value.toInt(),
            equals(order[i][0]),
            reason: 'size $n pos $i row',
          );
          expect(
            p.output('col').value.toInt(),
            equals(order[i][1]),
            reason: 'size $n pos $i col',
          );
        }
      }
      await Simulator.endSimulation();
    });
  });
}
