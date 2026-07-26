import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 directional intra prediction angle.
///
/// The eight directional intra modes (V, H, D45, D135, D113, D157, D203, D67)
/// have a base angle. The actual prediction angle is `base + angle_delta *
/// ANGLE_STEP` (ANGLE_STEP = 3, angle_delta in -3..3). The non-directional modes
/// (DC, SMOOTH, SMOOTH_V, SMOOTH_H, PAETH) have no angle. This returns the
/// prediction angle and an `is_directional` flag. Combinational.
///
/// Mode_To_Angle (DC,V,H,D45,D135,D113,D157,D203,D67,SMOOTH,SMOOTH_V,SMOOTH_H,
/// PAETH) = {0,90,180,45,135,113,157,203,67,0,0,0,0}.
class HarborIntraAngle extends BridgeModule {
  static const _base = [0, 90, 180, 45, 135, 113, 157, 203, 67, 0, 0, 0, 0];

  HarborIntraAngle({String? name})
    : super('HarborIntraAngle', name: name ?? 'intra_angle') {
    createPort('mode', PortDirection.input, width: 4);
    createPort('angle_delta', PortDirection.input, width: 3); // signed -3..3
    addOutput('angle', width: 9);
    addOutput('is_directional', width: 1);

    final mode = input('mode');
    Logic base = Const(0, width: 9);
    for (var m = _base.length - 1; m >= 0; m--) {
      base = mux(mode.eq(Const(m, width: 4)), Const(_base[m], width: 9), base);
    }

    // angle = base + angle_delta * 3 (signed delta).
    final delta = input('angle_delta').signExtend(9);
    final scaled = (delta * Const(3, width: 9)).getRange(0, 9);
    final dir = mode.gte(Const(1, width: 4)) & mode.lte(Const(8, width: 4));
    final angle = (base + scaled).getRange(0, 9);

    output('angle') <= mux(dir, angle, Const(0, width: 9));
    output('is_directional') <= dir;
  }
}
