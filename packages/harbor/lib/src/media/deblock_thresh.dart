import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 deblock threshold derivation for a single filter level (libaom
/// `update_sharpness` + `av1_loop_filter_init`).
///
/// Given a per-edge filter `level` (0..63) and the frame `sharpness` (0..7) it
/// derives the triple driving the kernels:
///   bil    = level >> ((sharpness>0?1:0) + (sharpness>4?1:0))
///   if (sharpness>0 && bil > 9-sharpness) bil = 9-sharpness
///   if (bil < 1) bil = 1
///   lim    = bil
///   mblim  = 2*(level+2) + bil
///   hev    = level >> 4
///
/// Ports: inputs `level` (6b), `sharpness` (3b). Outputs `mblim` (8b),
/// `lim` (8b), `hev` (8b). Combinational.
class HarborDeblockThresh extends BridgeModule {
  HarborDeblockThresh({String? name})
    : super('HarborDeblockThresh', name: name ?? 'deblock_thresh') {
    createPort('level', PortDirection.input, width: 6);
    createPort('sharpness', PortDirection.input, width: 3);
    addOutput('mblim', width: 8);
    addOutput('lim', width: 8);
    addOutput('hev', width: 8);

    // Work in 8b: max mblim = 2*(63+2)+63 = 193 < 256.
    const w = 8;
    Logic kc(int v) => Const(v, width: w);

    final level = input('level').zeroExtend(w);
    final sharp = input('sharpness'); // 3b, 0..7

    final shGt0 = sharp.gt(Const(0, width: 3)); // sharpness > 0
    final shGt4 = sharp.gt(Const(4, width: 3)); // sharpness > 4

    // shamt = (sharpness>0?1:0) + (sharpness>4?1:0)  in {0,1,2}.
    // bil = level >> shamt (logical right shift, level is non-negative).
    final shr1 = level >>> 1;
    final shr2 = level >>> 2;
    var bil = mux(shGt4, shr2, mux(shGt0, shr1, level));

    // Upper clamp to (9 - sharpness) only when sharpness > 0.
    final nine = kc(9);
    final upper = (nine - sharp.zeroExtend(w)).getRange(0, w); // 9 - sharpness
    final tooHigh = shGt0 & bil.gt(upper);
    bil = mux(tooHigh, upper, bil);

    // Lower clamp to 1.
    bil = mux(bil.lt(kc(1)), kc(1), bil);

    final lim = bil;
    // mblim = 2*(level+2) + bil = 2*level + 4 + bil.
    final mblim = (((level + kc(2)).getRange(0, w) << 1).getRange(0, w) + bil)
        .getRange(0, w);
    // hev = level >> 4 (level is 0..63 so this is 0..3).
    final hev = level >>> 4;

    output('mblim') <= mblim;
    output('lim') <= lim;
    output('hev') <= hev;
  }
}
