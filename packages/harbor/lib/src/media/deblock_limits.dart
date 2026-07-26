import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor deblock threshold derivation (libaom `update_sharpness`).
///
/// Turns a per-edge `filter_level` (0..63) and the frame `sharpness` (0..7) into
/// the three thresholds that drive [HarborDeblockFilter]: `limit` (the inside
/// gradient limit), `blimit` (the edge/boundary limit) and `thresh` (the
/// high-edge-variance threshold). Exact libaom math:
///   bil = sharpness ? (filter_level >> (1 + (sharpness > 4))) : filter_level
///   bil = clamp(bil, 1, 9 - sharpness)
///   limit  = bil
///   blimit = 2 * (filter_level + 2) + bil
///   thresh = filter_level >> 4
/// A `filter_level` of 0 disables the edge (limit/blimit collapse, callers gate
/// on it). Combinational.
class HarborDeblockLimits extends BridgeModule {
  HarborDeblockLimits({String? name})
    : super('HarborDeblockLimits', name: name ?? 'deblock_limits') {
    const w = 12;

    createPort('filter_level', PortDirection.input, width: 6); // 0..63
    createPort('sharpness', PortDirection.input, width: 3); // 0..7
    addOutput('blimit', width: 8);
    addOutput('limit', width: 8);
    addOutput('thresh', width: 8);

    final lvl = input('filter_level').zeroExtend(w);
    final sharp = input('sharpness');
    final sharpW = sharp.zeroExtend(w);

    // shift = 0 if sharpness == 0, else 1 + (sharpness > 4).
    final sharpNZ = sharp.or();
    final sharpGt4 = sharp.gt(Const(4, width: 3));
    final shift = mux(
      sharpNZ,
      (Const(1, width: 2) + sharpGt4.zeroExtend(2)).getRange(0, 2),
      Const(0, width: 2),
    );
    // bilRaw = filter_level >> shift  (shift in {0,1,2}).
    final bilRaw = mux(
      shift.eq(Const(0, width: 2)),
      lvl,
      mux(shift.eq(Const(1, width: 2)), lvl >>> 1, lvl >>> 2),
    );

    // cap = 9 - sharpness  (>= 2), then bil = clamp(bilRaw, 1, cap).
    final cap = (Const(9, width: w) - sharpW).getRange(0, w);
    final cappedHi = mux(bilRaw.gt(cap), cap, bilRaw);
    final bil = mux(
      cappedHi.lt(Const(1, width: w)),
      Const(1, width: w),
      cappedHi,
    );

    output('limit') <= bil.getRange(0, 8);
    // blimit = 2*(filter_level + 2) + bil.
    final blimit =
        (((lvl + Const(2, width: w)).getRange(0, w) << 1).getRange(0, w) + bil)
            .getRange(0, w);
    output('blimit') <= blimit.getRange(0, 8);
    // thresh = filter_level >> 4.
    output('thresh') <= (lvl >>> 4).getRange(0, 8);
  }
}
