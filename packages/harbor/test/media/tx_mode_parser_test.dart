import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborTxModeParser', () {
    late HarborTxModeParser p;
    late Logic clk, bytes, lossless;

    Future<void> setUpDut() async {
      p = HarborTxModeParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 16 * 8);
      lossless = Logic(name: 'coded_lossless', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('coded_lossless').srcConnection! <= lossless;
      await p.build();
      bytes.inject(0);
      lossless.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    // (name, firstBit, lossless, expTxMode, expConsumed)
    final cases = <(String, int, int, int, int)>[
      ('lossless -> ONLY_4X4', 1, 1, 0, 0),
      ('select -> TX_MODE_SELECT', 1, 0, 2, 1),
      ('largest -> TX_MODE_LARGEST', 0, 0, 1, 1),
    ];

    for (final c in cases) {
      test(c.$1, () async {
        await setUpDut();
        // Put the tx_mode_select bit at stream bit 0 (= byte0 bit7).
        bytes.inject(BigInt.from(c.$2 << 7));
        lossless.inject(c.$3);
        await clk.nextPosedge;
        expect(
          p.output('tx_mode').value.toInt(),
          equals(c.$4),
          reason: 'tx_mode',
        );
        expect(
          p.output('bits_consumed').value.toInt(),
          equals(c.$5),
          reason: 'bits_consumed',
        );
        await Simulator.endSimulation();
      });
    }
  });
}
