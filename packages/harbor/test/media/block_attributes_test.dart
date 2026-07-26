import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _maxTx = [
  0,
  5,
  6,
  1,
  7,
  8,
  2,
  9,
  10,
  3,
  11,
  12,
  4,
  4,
  4,
  4,
  13,
  14,
  15,
  16,
  17,
  18,
];
const _txW = [
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
const _txH = [
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
const _txType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];

int _log2(int v) => v.bitLength - 1;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborBlockAttributes', () {
    late HarborBlockAttributes p;
    late Logic clk, bsize, mode;

    Future<void> setUpDut() async {
      p = HarborBlockAttributes();
      clk = SimpleClockGenerator(10).clk;
      bsize = Logic(name: 'bsize', width: 5);
      mode = Logic(name: 'intra_mode', width: 4);
      p.input('bsize').srcConnection! <= bsize;
      p.input('intra_mode').srcConnection! <= mode;
      await p.build();
      bsize.inject(3);
      mode.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    test('derives tx size/geometry/type from block size + mode', () async {
      await setUpDut();
      for (final bs in [0, 3, 6, 9, 12, 4, 16, 21]) {
        for (final m in [0, 1, 4, 9, 12]) {
          bsize.inject(bs);
          mode.inject(m);
          await clk.nextPosedge;
          final ts = _maxTx[bs];
          expect(
            p.output('tx_size').value.toInt(),
            equals(ts),
            reason: 'bs $bs tx_size',
          );
          expect(
            p.output('tx_width').value.toInt(),
            equals(_txW[ts]),
            reason: 'bs $bs tx_w',
          );
          expect(
            p.output('tx_height').value.toInt(),
            equals(_txH[ts]),
            reason: 'bs $bs tx_h',
          );
          expect(
            p.output('tx_width_log2').value.toInt(),
            equals(_log2(_txW[ts])),
            reason: 'bs $bs tx_wlog2',
          );
          expect(
            p.output('tx_height_log2').value.toInt(),
            equals(_log2(_txH[ts])),
            reason: 'bs $bs tx_hlog2',
          );
          final tt = _txType[m];
          expect(
            p.output('tx_type').value.toInt(),
            equals(tt),
            reason: 'm $m tx_type',
          );
          expect(
            p.output('v_type').value.toInt(),
            equals(tt & 1),
            reason: 'm $m v_type',
          );
          expect(
            p.output('h_type').value.toInt(),
            equals((tt >> 1) & 1),
            reason: 'm $m h_type',
          );
        }
      }
      await Simulator.endSimulation();
    });
  });
}
