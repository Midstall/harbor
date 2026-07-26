import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _w = [
  4,
  8,
  16,
  32,
  64,
  4,
  8,
  8,
  16,
  16,
  32,
  32,
  64,
  4,
  16,
  8,
  32,
  16,
  64,
];
const _h = [
  4,
  8,
  16,
  32,
  64,
  8,
  4,
  16,
  8,
  32,
  16,
  64,
  32,
  16,
  4,
  32,
  8,
  64,
  16,
];

int _log2(int v) => v.bitLength - 1;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborTxSizeGeom', () {
    late HarborTxSizeGeom p;
    late Logic clk, tx;

    Future<void> setUpDut() async {
      p = HarborTxSizeGeom();
      clk = SimpleClockGenerator(10).clk;
      tx = Logic(name: 'tx_size', width: 5);
      p.input('tx_size').srcConnection! <= tx;
      await p.build();
      tx.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('maps every tx size to width/height/log2', () async {
      await setUpDut();
      for (var i = 0; i < _w.length; i++) {
        tx.inject(i);
        await clk.nextPosedge;
        expect(
          p.output('tx_width').value.toInt(),
          equals(_w[i]),
          reason: 'w $i',
        );
        expect(
          p.output('tx_height').value.toInt(),
          equals(_h[i]),
          reason: 'h $i',
        );
        expect(
          p.output('tx_width_log2').value.toInt(),
          equals(_log2(_w[i])),
          reason: 'wlog2 $i',
        );
        expect(
          p.output('tx_height_log2').value.toInt(),
          equals(_log2(_h[i])),
          reason: 'hlog2 $i',
        );
      }
      await Simulator.endSimulation();
    });
  });
}
