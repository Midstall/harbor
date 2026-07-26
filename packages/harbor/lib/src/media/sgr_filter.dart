import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor self-guided restoration (SGR) filter, per-pixel box-guided core.
///
/// SGR is AV1's second loop-restoration type (alongside Wiener). It is a
/// self-guided box filter: over a `(2r+1)x(2r+1)` window it measures the local
/// mean and variance, derives a per-pixel gain `a = var / (var + eps)` that is
/// near 1 on edges (keep detail) and near 0 on flat noise (smooth), and outputs
/// `a*center + (1-a)*mean`. The variance-driven gain follows libaom's structure:
/// `z = (var_num * s) >> mtableBits`, then `a` comes from an `x/(x+1)` table in
/// Q8 (so no hardware divider). `s` (the noise parameter) is signalled at run
/// time.
///
/// `window` packs the `(2r+1)^2` pixels row-major, LSB-first (pixel 0 at bit 0).
/// The centre pixel sits at the middle index. Combinational, output 8-bit.
///
/// SIMPLIFICATIONS vs libaom SGR: a single radius (no two-pass r0/r1 mix), no
/// 3x3 cross-pixel A/B normalisation, and a self-consistent `x/(x+1)` / `1/n`
/// fixed-point (the structure is exact, the exact libaom LUT/param tables are a
/// follow-up). The reference in the test mirrors this fixed-point bit-for-bit.
class HarborSgrFilter extends BridgeModule {
  /// [radius] sets the box to `(2*radius+1)^2`, 1 -> 3x3, 2 -> 5x5.
  HarborSgrFilter({int radius = 1, String? name})
    : super('HarborSgrFilter', name: name ?? 'sgr') {
    final side = 2 * radius + 1;
    final n = side * side;
    final centre = n ~/ 2;
    const recipBits = 12;
    const mtableBits = 20;
    const w = 40; // signed-safe working width

    final oneOverN = ((1 << recipBits) + n ~/ 2) ~/ n; // round(2^12 / n)

    createPort('window', PortDirection.input, width: n * 8);
    createPort('s', PortDirection.input, width: 8); // noise parameter
    addOutput('out', width: 8);

    final win = input('window');
    Logic px(int i) => win.getRange(i * 8, i * 8 + 8);

    // sum and sum-of-squares over the box.
    Logic sum = Const(0, width: 16);
    Logic sumsq = Const(0, width: 24);
    for (var i = 0; i < n; i++) {
      final p = px(i);
      sum = (sum + p.zeroExtend(16)).getRange(0, 16);
      final sq = (p.zeroExtend(16) * p.zeroExtend(16)).getRange(0, 16);
      sumsq = (sumsq + sq.zeroExtend(24)).getRange(0, 24);
    }

    // var_num = sumsq*n - sum*sum  (>= 0 by Cauchy-Schwarz).
    final sumsqN = (sumsq.zeroExtend(w) * Const(n, width: w)).getRange(0, w);
    final sumSq = (sum.zeroExtend(w) * sum.zeroExtend(w)).getRange(0, w);
    final varNum = (sumsqN - sumSq).getRange(0, w);

    // z = (var_num * s) >> mtableBits, clamped to the table range [0, 255].
    final s = input('s').zeroExtend(w);
    final zFull = ((varNum * s).getRange(0, w) >>> mtableBits).getRange(0, w);
    final zOver = zFull.gt(Const(255, width: w));
    final z = mux(zOver, Const(255, width: 8), zFull.getRange(0, 8));

    // a2 = x_by_xplus1[z]  (Q8: 256*z/(z+1)). Built as a mux tree over a baked
    // 256-entry table so no divider is synthesised.
    final table = <Logic>[
      for (var i = 0; i < 256; i++)
        Const(((256 * i + (i + 1) ~/ 2) ~/ (i + 1)), width: 9),
    ];
    Logic treeSel(List<Logic> items, Logic idx) {
      var level = items;
      var bit = 0;
      while (level.length > 1) {
        final next = <Logic>[];
        for (var k = 0; k + 1 < level.length; k += 2) {
          next.add(mux(idx[bit], level[k + 1], level[k]));
        }
        if (level.length.isOdd) next.add(level.last);
        level = next;
        bit++;
      }
      return level.first;
    }

    final a2 = treeSel(table, z); // 9-bit, 0..256

    // mean = round(sum / n) via the Q12 reciprocal.
    final mean =
        (((sum.zeroExtend(24) * Const(oneOverN, width: 24)).getRange(0, 24) +
                        Const(1 << (recipBits - 1), width: 24))
                    .getRange(0, 24) >>>
                recipBits)
            .getRange(0, 24);

    // out = (a2*centre + (256 - a2)*mean + 128) >> 8, clamped to a pixel.
    final invA = (Const(256, width: 9) - a2).getRange(0, 9);
    final blend =
        ((a2.zeroExtend(24) * px(centre).zeroExtend(24)).getRange(0, 24) +
                (invA.zeroExtend(24) * mean.getRange(0, 8).zeroExtend(24))
                    .getRange(0, 24))
            .getRange(0, 24);
    final outVal = ((blend + Const(128, width: 24)).getRange(0, 24) >>> 8)
        .getRange(0, 24);
    final tooBig = outVal.gt(Const(255, width: 24));
    output('out') <= mux(tooBig, Const(255, width: 8), outVal.getRange(0, 8));
  }
}
