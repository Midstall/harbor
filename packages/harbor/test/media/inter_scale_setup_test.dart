@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/inter_scale_setup.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 inter-prediction sub-pixel position / scale setup, UNSCALED
// (1:1) path. Mirrors the software decoder's _motionComp / _obmcStrip /
// _subBlockChroma setup arithmetic in the SW reference tile decode:
//
//   final mvq = mv << (1 - subsampling)    // 1/8-pel -> 1/16-pel (luma: <<1)
//   final base = (pos * 16 + mvq) >> 4     // arithmetic shift, integer source px
//   final frac = mvq & 15                  // 1/16-pel phase 0..15
//
// MV is signed 1/8-pel (3 fractional bits), SUBPEL_BITS = 4 (1/16-pel),
// SUBPEL_MASK = 15. pos*16 == pos<<SUBPEL_BITS contributes nothing to the low 4
// bits, so frac == mvq & 15 == (pos*16 + mvq) & 15.

({int base, int frac}) _goldenAxis(int mv, int pos, int subsampling) {
  final mvq = mv << (1 - subsampling);
  final p = pos * 16 + mvq;
  // Dart >> on int is an arithmetic (sign-propagating) shift, matching the SW.
  final base = p >> 4;
  final frac = mvq & 15;
  return (base: base, frac: frac);
}

// Reinterpret an unsigned width-bit value read from a two's-complement port.
int _signed(int v, int width) {
  final sign = 1 << (width - 1);
  return (v & sign) != 0 ? v - (1 << width) : v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final subsampling in [0, 1]) {
    test(
      'HarborInterScaleSetup unscaled matches SW (subsampling=$subsampling)',
      () async {
        const mvWidth = 16;
        const posWidth = 16;
        final dut = HarborInterScaleSetup(
          subsampling: subsampling,
          mvWidth: mvWidth,
          posWidth: posWidth,
        );
        final coordWidth = dut.coordWidth;

        final clk = SimpleClockGenerator(10).clk;
        final mvRow = Logic(name: 'mv_row', width: mvWidth);
        final mvCol = Logic(name: 'mv_col', width: mvWidth);
        final posX = Logic(name: 'pos_x', width: posWidth);
        final posY = Logic(name: 'pos_y', width: posWidth);
        dut.input('mv_row').srcConnection! <= mvRow;
        dut.input('mv_col').srcConnection! <= mvCol;
        dut.input('pos_x').srcConnection! <= posX;
        dut.input('pos_y').srcConnection! <= posY;
        await dut.build();
        Simulator.setMaxSimTime(600000000);
        unawaited(Simulator.run());

        final rng = Random(0xA1 + subsampling);
        // Full signed MV range incl negatives, positions 0..65535.
        for (var iter = 0; iter < 1500; iter++) {
          // MV in full 16b signed range: -32768..32767.
          final mvR = rng.nextInt(1 << mvWidth) - (1 << (mvWidth - 1));
          final mvC = rng.nextInt(1 << mvWidth) - (1 << (mvWidth - 1));
          final px = rng.nextInt(1 << posWidth);
          final py = rng.nextInt(1 << posWidth);

          mvRow.put(BigInt.from(mvR).toUnsigned(mvWidth));
          mvCol.put(BigInt.from(mvC).toUnsigned(mvWidth));
          posX.put(BigInt.from(px).toUnsigned(posWidth));
          posY.put(BigInt.from(py).toUnsigned(posWidth));

          await clk.nextPosedge;

          final gx = _goldenAxis(mvC, px, subsampling);
          final gy = _goldenAxis(mvR, py, subsampling);

          final x0 = _signed(dut.output('x0').value.toInt(), coordWidth);
          final y0 = _signed(dut.output('y0').value.toInt(), coordWidth);
          final fx = dut.output('frac_x').value.toInt();
          final fy = dut.output('frac_y').value.toInt();

          expect(x0, equals(gx.base), reason: 'x0 iter=$iter mvC=$mvC px=$px');
          expect(y0, equals(gy.base), reason: 'y0 iter=$iter mvR=$mvR py=$py');
          expect(
            fx,
            equals(gx.frac),
            reason: 'frac_x iter=$iter mvC=$mvC px=$px',
          );
          expect(
            fy,
            equals(gy.frac),
            reason: 'frac_y iter=$iter mvR=$mvR py=$py',
          );
        }
        await Simulator.endSimulation();
      },
    );
  }

  test(
    'HarborInterScaleSetup boundary MVs and positions (subsampling=0)',
    () async {
      const mvWidth = 16, posWidth = 16, subsampling = 0;
      final dut = HarborInterScaleSetup(
        subsampling: subsampling,
        mvWidth: mvWidth,
        posWidth: posWidth,
      );
      final coordWidth = dut.coordWidth;

      final clk = SimpleClockGenerator(10).clk;
      final mvRow = Logic(name: 'mv_row', width: mvWidth);
      final mvCol = Logic(name: 'mv_col', width: mvWidth);
      final posX = Logic(name: 'pos_x', width: posWidth);
      final posY = Logic(name: 'pos_y', width: posWidth);
      dut.input('mv_row').srcConnection! <= mvRow;
      dut.input('mv_col').srcConnection! <= mvCol;
      dut.input('pos_x').srcConnection! <= posX;
      dut.input('pos_y').srcConnection! <= posY;
      await dut.build();
      Simulator.setMaxSimTime(60000000);
      unawaited(Simulator.run());

      final cases = <(int, int, int, int)>[
        (0, 0, 0, 0),
        (-1, -1, 0, 0),
        (32767, 32767, 65535, 65535),
        (-32768, -32768, 0, 0),
        (-32768, -32768, 65535, 65535),
        (7, -7, 100, 200),
        (-15, 15, 1, 2),
        (8, -8, 0, 0), // exactly +/- 1 pel (8 in 1/8-pel)
      ];
      for (final (mvR, mvC, px, py) in cases) {
        mvRow.put(BigInt.from(mvR).toUnsigned(mvWidth));
        mvCol.put(BigInt.from(mvC).toUnsigned(mvWidth));
        posX.put(BigInt.from(px).toUnsigned(posWidth));
        posY.put(BigInt.from(py).toUnsigned(posWidth));
        await clk.nextPosedge;

        final gx = _goldenAxis(mvC, px, subsampling);
        final gy = _goldenAxis(mvR, py, subsampling);
        final x0 = _signed(dut.output('x0').value.toInt(), coordWidth);
        final y0 = _signed(dut.output('y0').value.toInt(), coordWidth);
        final fx = dut.output('frac_x').value.toInt();
        final fy = dut.output('frac_y').value.toInt();
        expect(x0, equals(gx.base), reason: 'x0 mvC=$mvC px=$px');
        expect(y0, equals(gy.base), reason: 'y0 mvR=$mvR py=$py');
        expect(fx, equals(gx.frac), reason: 'frac_x mvC=$mvC px=$px');
        expect(fy, equals(gy.frac), reason: 'frac_y mvR=$mvR py=$py');
      }
      await Simulator.endSimulation();
    },
  );
}
