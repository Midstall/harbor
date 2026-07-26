import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

(int, int, int, int, int) _ref(
  int r,
  int c,
  int miRows,
  int miCols,
  int bsl,
  int aboveCtx,
  int leftCtx,
) {
  final num4x4 = 1 << bsl;
  final half = num4x4 >> 1;
  final hasRows = (r + half) < miRows ? 1 : 0;
  final hasCols = (c + half) < miCols ? 1 : 0;
  final availU = r > 0 ? 1 : 0;
  final availL = c > 0 ? 1 : 0;
  final aboveP = (aboveCtx >> bsl) & 1;
  final leftP = (leftCtx >> bsl) & 1;
  final ctx = leftP * 2 + aboveP;
  return (ctx, hasRows, hasCols, availU, availL);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPartitionContext', () {
    late HarborPartitionContext p;
    late Logic clk;
    final sig = <String, Logic>{};

    Future<void> setUpDut() async {
      p = HarborPartitionContext();
      clk = SimpleClockGenerator(10).clk;
      for (final spec in [
        ('r', 16),
        ('c', 16),
        ('mi_rows', 16),
        ('mi_cols', 16),
        ('bsl', 3),
        ('above_ctx', 8),
        ('left_ctx', 8),
      ]) {
        final l = Logic(name: spec.$1, width: spec.$2);
        sig[spec.$1] = l;
        p.input(spec.$1).srcConnection! <= l;
      }
      await p.build();
      sig.forEach((_, l) => l.inject(0));
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    // (r, c, miRows, miCols, bsl, aboveCtx, leftCtx)
    final cases = <List<int>>[
      [0, 0, 270, 480, 4, 0, 0], // top-left 64x64
      [4, 4, 270, 480, 4, 0xFF, 0xFF], // both ctx bits set
      [16, 32, 270, 480, 3, 0x08, 0x00], // bsl=3 above bit set
      [268, 4, 270, 480, 4, 0x10, 0x10], // near bottom: has_rows false
      [4, 478, 270, 480, 4, 0x00, 0x10], // near right: has_cols false
      [268, 478, 270, 480, 4, 0xFF, 0x00], // corner: both false
      [8, 8, 270, 480, 2, 0x04, 0x04], // bsl=2 (16x16)
      [0, 16, 270, 480, 0, 0x01, 0x01], // bsl=0 (4x4), avail_u false
    ];

    for (var idx = 0; idx < cases.length; idx++) {
      final t = cases[idx];
      test('case $idx', () async {
        await setUpDut();
        sig['r']!.inject(t[0]);
        sig['c']!.inject(t[1]);
        sig['mi_rows']!.inject(t[2]);
        sig['mi_cols']!.inject(t[3]);
        sig['bsl']!.inject(t[4]);
        sig['above_ctx']!.inject(t[5]);
        sig['left_ctx']!.inject(t[6]);
        await clk.nextPosedge;
        final exp = _ref(t[0], t[1], t[2], t[3], t[4], t[5], t[6]);
        expect(p.output('ctx').value.toInt(), equals(exp.$1), reason: 'ctx');
        expect(
          p.output('has_rows').value.toInt(),
          equals(exp.$2),
          reason: 'has_rows',
        );
        expect(
          p.output('has_cols').value.toInt(),
          equals(exp.$3),
          reason: 'has_cols',
        );
        expect(
          p.output('avail_u').value.toInt(),
          equals(exp.$4),
          reason: 'avail_u',
        );
        expect(
          p.output('avail_l').value.toInt(),
          equals(exp.$5),
          reason: 'avail_l',
        );
        await Simulator.endSimulation();
      });
    }
  });
}
