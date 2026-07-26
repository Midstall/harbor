import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// HarborSbWalk emits the raster sequence of superblock MI positions within a
// tile. The golden is the same nested loop computed directly.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborSbWalk: superblock raster order matches the tile loop', () async {
    final p = HarborSbWalk();
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final nxt = Logic(name: 'next');
    final use128 = Logic(name: 'use128');
    final colStart = Logic(name: 'col_start', width: 12);
    final colEnd = Logic(name: 'col_end', width: 12);
    final rowStart = Logic(name: 'row_start', width: 12);
    final rowEnd = Logic(name: 'row_end', width: 12);

    p.input('clk').srcConnection! <= clk;
    p.input('reset').srcConnection! <= reset;
    p.input('start').srcConnection! <= start;
    p.input('next').srcConnection! <= nxt;
    p.input('use_128x128_superblock').srcConnection! <= use128;
    p.input('mi_col_start').srcConnection! <= colStart;
    p.input('mi_col_end').srcConnection! <= colEnd;
    p.input('mi_row_start').srcConnection! <= rowStart;
    p.input('mi_row_end').srcConnection! <= rowEnd;
    await p.build();

    reset.inject(1);
    start.inject(0);
    nxt.inject(0);
    use128.inject(0);
    colStart.inject(0);
    colEnd.inject(0);
    rowStart.inject(0);
    rowEnd.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;

    // (mi_cols, mi_rows, use128) cases.
    final cases = <(int, int, int, bool)>[
      (16, 16, 0, false), // single 64x64 SB
      (32, 32, 0, false), // 2x2 SBs
      (48, 16, 0, false), // 3x1 SBs
      (40, 56, 0, false), // 3x4 SBs (partial edges)
      (64, 32, 1, true), // 128x128 SBs: 2x1
      (96, 96, 1, true), // 3x3 128x128 SBs
    ];

    for (var ci = 0; ci < cases.length; ci++) {
      final (miCols, miRows, u128, _) = cases[ci];
      final sbMi = u128 == 1 ? 32 : 16;
      final expected = <(int, int)>[];
      for (var r = 0; r < miRows; r += sbMi) {
        for (var c = 0; c < miCols; c += sbMi) {
          expected.add((r, c));
        }
      }

      reset.inject(1);
      use128.inject(u128);
      colStart.inject(0);
      colEnd.inject(miCols);
      rowStart.inject(0);
      rowEnd.inject(miRows);
      await clk.nextPosedge;
      reset.inject(0);
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);

      final got = <(int, int)>[];
      var guard = 0;
      while (p.output('valid').value.toInt() == 1) {
        got.add((
          p.output('sb_mi_row').value.toInt(),
          p.output('sb_mi_col').value.toInt(),
        ));
        expect(
          p.output('sb_index').value.toInt(),
          equals(got.length - 1),
          reason: 'case $ci idx',
        );
        nxt.inject(1);
        await clk.nextPosedge;
        nxt.inject(0);
        await clk.nextPosedge;
        if (++guard > 2000) fail('case $ci runaway');
      }
      expect(
        p.output('done').value.toInt(),
        equals(1),
        reason: 'case $ci done',
      );
      expect(got, equals(expected), reason: 'case $ci sequence');
    }
    await Simulator.endSimulation();
  });
}
