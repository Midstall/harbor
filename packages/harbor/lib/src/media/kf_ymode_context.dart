import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 keyframe intra Y-mode CDF context.
///
/// On a key frame the luma intra mode is decoded with `kf_y_cdf[aboveCtx]
/// [leftCtx]`, where each neighbour's intra mode (0..12) is mapped through the
/// `Intra_Mode_Context` table to one of five buckets. This module performs that
/// mapping for the above and left neighbours (DC_PRED is used when a neighbour
/// is unavailable, which the caller substitutes). Combinational.
///
/// Intra_Mode_Context[INTRA_MODES] =
///   {0,1,2,3,4,4,4,4,3,0,1,2,0}  (DC,V,H,D45,D135,D113,D157,D203,D67,
///                                 SMOOTH,SMOOTH_V,SMOOTH_H,PAETH)
class HarborKfYModeContext extends BridgeModule {
  static const _ctx = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];

  HarborKfYModeContext({String? name})
    : super('HarborKfYModeContext', name: name ?? 'kf_ymode_ctx') {
    createPort('above_mode', PortDirection.input, width: 4);
    createPort('left_mode', PortDirection.input, width: 4);
    addOutput('above_ctx', width: 3);
    addOutput('left_ctx', width: 3);

    Logic mapMode(Logic mode) {
      Logic out = Const(0, width: 3);
      for (var m = _ctx.length - 1; m >= 0; m--) {
        out = mux(mode.eq(Const(m, width: 4)), Const(_ctx[m], width: 3), out);
      }
      return out;
    }

    output('above_ctx') <= mapMode(input('above_mode'));
    output('left_ctx') <= mapMode(input('left_mode'));
  }
}
