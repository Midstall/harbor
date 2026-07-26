import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/mv_projection.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// --- Golden: verbatim copy of the AV1 SW temporal MV projection ---
// (tile_decode.dart: _divMult, _roundSigned, _getMvProjection clamps).

// div_mult[den]: 2^14 / den for the MV projection (mvref_common.c).
const _divMult = [
  0, 16384, 8192, 5461, 4096, 3276, 2730, 2340, 2048, 1820, 1638, 1489, //
  1365, 1260, 1170, 1092, 1024, 963, 910, 862, 819, 780, 744, 712, 682, //
  655, 630, 606, 585, 564, 546, 528,
];
const _maxFrameDistance = 31; // (1 << FRAME_OFFSET_BITS) - 1

// round-half-away-from-zero of a signed value by n bits.
int _roundSigned(int v, int n) =>
    v >= 0 ? (v + (1 << (n - 1))) >> n : -((-v + (1 << (n - 1))) >> n);

// get_mv_projection: scale [row,col] by num/den (1/8-pel), clamp to MV range.
List<int> _getMvProjection(int row, int col, int num, int den) {
  den = den < _maxFrameDistance ? den : _maxFrameDistance;
  num = num > 0
      ? (num < _maxFrameDistance ? num : _maxFrameDistance)
      : (num > -_maxFrameDistance ? num : -_maxFrameDistance);
  final mvRow = _roundSigned(row * num * _divMult[den], 14);
  final mvCol = _roundSigned(col * num * _divMult[den], 14);
  const cMax = (1 << 14) - 1, cMin = -(1 << 14) + 1;
  return [
    mvRow < cMin ? cMin : (mvRow > cMax ? cMax : mvRow),
    mvCol < cMin ? cMin : (mvCol > cMax ? cMax : mvCol),
  ];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborMvProjection matches SW get_mv_projection', () async {
    final dut = HarborMvProjection();
    const mw = HarborMvProjection.mvWidth;
    const nw = HarborMvProjection.numWidth;
    const dw = HarborMvProjection.denWidth;
    const ow = HarborMvProjection.projWidth;

    final mvRow = Logic(name: 'mv_row_drv', width: mw);
    final mvCol = Logic(name: 'mv_col_drv', width: mw);
    final num = Logic(name: 'num_drv', width: nw);
    final den = Logic(name: 'den_drv', width: dw);
    dut.input('mv_row').srcConnection! <= mvRow;
    dut.input('mv_col').srcConnection! <= mvCol;
    dut.input('num').srcConnection! <= num;
    dut.input('den').srcConnection! <= den;
    await dut.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    // Convert a signed result back from a width-w unsigned register.
    int asSigned(LogicValue v, int w) {
      final u = v.toBigInt();
      final big = u >= (BigInt.one << (w - 1)) ? u - (BigInt.one << w) : u;
      return big.toInt();
    }

    final clk = SimpleClockGenerator(10).clk;
    final rng = Random(0x4D560151);

    // Directed corner cases: zero, max/min source MV, num at clamp bounds,
    // den at table edges, and the divMult[0]=0 path.
    final directed = <List<int>>[
      [0, 0, 0, 0],
      [4095, 4095, 31, 1],
      [-4095, -4095, -31, 1],
      [4095, -4095, 31, 31],
      [32767, -32768, 50, 0], // num over-clamp, den=0 -> divMult 0
      [-32768, 32767, -50, 40], // num under-clamp, den over-clamp
      [1, -1, 1, 2],
      [12345, -23456, 7, 7],
      [255, -255, -1, 15],
      [16383, -16383, 31, 31],
    ];

    var iters = 0;
    Future<void> run(int mvR, int mvC, int n, int d) async {
      mvRow.put(BigInt.from(mvR).toUnsigned(mw));
      mvCol.put(BigInt.from(mvC).toUnsigned(mw));
      num.put(BigInt.from(n).toUnsigned(nw));
      den.put(BigInt.from(d).toUnsigned(dw));
      await clk.nextPosedge;
      final gold = _getMvProjection(mvR, mvC, n, d);
      final gotR = asSigned(dut.output('proj_row').value, ow);
      final gotC = asSigned(dut.output('proj_col').value, ow);
      expect(
        gotR,
        equals(gold[0]),
        reason: 'proj_row mv=($mvR,$mvC) num=$n den=$d',
      );
      expect(
        gotC,
        equals(gold[1]),
        reason: 'proj_col mv=($mvR,$mvC) num=$n den=$d',
      );
      iters++;
    }

    for (final v in directed) {
      await run(v[0], v[1], v[2], v[3]);
    }

    // Random sweep: signed mv in int16 range, num across [-50,50] (exercises
    // both the clamp tails and the in-range band), den across full table index.
    for (var i = 0; i < 2500; i++) {
      final mvR = rng.nextInt(1 << 16) - (1 << 15);
      final mvC = rng.nextInt(1 << 16) - (1 << 15);
      final n = rng.nextInt(101) - 50;
      final d = rng.nextInt(1 << dw); // 0 .. 2^denWidth-1, covers >=31 clamp
      await run(mvR, mvC, n, d);
    }

    expect(iters, greaterThanOrEqualTo(2000));
    await Simulator.endSimulation();
  });
}
