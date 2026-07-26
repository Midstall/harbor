import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 temporal motion-vector projection (libaom
/// `get_mv_projection`, av1/common/mvref_common.c, SW: tile_decode.dart
/// `_getMvProjection`). Combinational.
///
/// Scales a source motion vector `(mv_row, mv_col)` by the temporal ratio
/// `num/den` using a reciprocal LUT, then rounds half away from zero and clamps
/// to the AV1 MV range. Both `mv_row` and `mv_col` share the same `num`/`den`
/// (the temporal distances), so one `divMult[den]` lookup feeds both lanes.
///
/// Operation (per lane, exactly as the SW):
///   den = (den >= 31) ? 31 : den                 // _maxFrameDistance clamp
///   num = clamp(num, -31, 31)                     // _maxFrameDistance clamp
///   p   = mv * num * divMult[den]                 // signed product
///   r   = roundHalfAwayFromZero(p, 14)            // _roundSigned(p, 14)
///   out = clamp(r, -16383, +16383)                // [-(1<<14)+1, (1<<14)-1]
///
/// `divMult[den] = 2^14 / den` (`divMult[0] = 0`), a 32-entry table indexed by
/// the clamped temporal distance `den` (0..31).
///
/// Ports (all two's-complement signed except `den`):
///   mv_row, mv_col : [mvWidth]   source MV components (int16 range)
///   num            : [numWidth]  signed temporal distance to current frame
///   den            : [denWidth]  unsigned denominator distance / LUT index
///   proj_row, proj_col : [projWidth]  projected MV components (signed)
///
/// Worst-case magnitude: |mv|<=2^15, |num|<=31, divMult<=16384 gives a product
/// |p| <= 2^15 * 31 * 2^14 ~= 1.66e10 (<2^34), so the signed working width
/// [_w]=48 holds it with wide margin and the low-w product slice is exact.
class HarborMvProjection extends BridgeModule {
  /// Signed width of the source MV components (int16 range).
  static const int mvWidth = 16;

  /// Signed width of the `num` temporal distance.
  static const int numWidth = 8;

  /// Unsigned width of `den` (LUT index, clamped to 31 internally).
  static const int denWidth = 6;

  /// Signed width of the projected MV outputs.
  static const int projWidth = 16;

  /// Internal signed working width for the `mv * num * divMult` product.
  static const int _w = 48;

  /// `_maxFrameDistance`: (1 << FRAME_OFFSET_BITS) - 1.
  static const int _maxFrameDistance = 31;

  /// Round-half-away-from-zero shift amount.
  static const int _roundBits = 14;

  /// Output clamp bound: cMax = (1<<14)-1, cMin = -cMax.
  static const int _clampMax = (1 << 14) - 1;

  /// div_mult[den] = 2^14 / den (mvref_common.c). 32 entries, index 0..31.
  static const List<int> divMult = [
    0, 16384, 8192, 5461, 4096, 3276, 2730, 2340, 2048, 1820, 1638, 1489, //
    1365, 1260, 1170, 1092, 1024, 963, 910, 862, 819, 780, 744, 712, 682, //
    655, 630, 606, 585, 564, 546, 528,
  ];

  HarborMvProjection({String? name})
    : super('HarborMvProjection', name: name ?? 'mv_projection') {
    createPort('mv_row', PortDirection.input, width: mvWidth);
    createPort('mv_col', PortDirection.input, width: mvWidth);
    createPort('num', PortDirection.input, width: numWidth);
    createPort('den', PortDirection.input, width: denWidth);
    addOutput('proj_row', width: projWidth);
    addOutput('proj_col', width: projWidth);

    Logic constW(int v) => Const(BigInt.from(v).toUnsigned(_w), width: _w);
    Logic mulW(Logic a, Logic b) => (a * b).getRange(0, _w);

    // den clamp: den = (den >= 31) ? 31 : den. den is unsigned 0..2^denWidth-1.
    final den = input('den');
    final denC = mux(
      den.gte(Const(_maxFrameDistance, width: denWidth)),
      Const(_maxFrameDistance, width: denWidth),
      den,
    );

    // ROM mux: divMult[denC]. Built as a signed-W constant (always positive).
    Logic dm = constW(divMult[0]);
    for (var i = 1; i < divMult.length; i++) {
      dm = mux(denC.eq(Const(i, width: denWidth)), constW(divMult[i]), dm);
    }

    // num clamp to [-31, 31] on the signed value.
    final numW = input('num').signExtend(_w);
    final numHi = constW(_maxFrameDistance);
    final numLo = constW(-_maxFrameDistance);
    // Signed compares via sign-of-difference: a > b iff (b - a) is negative.
    Logic gtSigned(Logic a, Logic b) => (b - a).getRange(0, _w)[_w - 1];
    final numClamped = mux(
      gtSigned(numW, numHi),
      numHi,
      mux(gtSigned(numLo, numW), numLo, numW),
    );

    // Round half away from zero by [_roundBits], then clamp to [-cMax, cMax].
    final half = constW(1 << (_roundBits - 1));
    final maxV = constW(_clampMax);
    final minV = constW(-_clampMax);

    Logic project(Logic mv) {
      final p = mulW(mulW(mv.signExtend(_w), numClamped), dm);
      final neg = p[_w - 1];
      // magnitude = neg ? -p : p
      final mag = mux(neg, (~p + constW(1)).getRange(0, _w), p);
      // (|p| + 2^13) >> 14 (logical: mag is non-negative here)
      final rounded = (mag + half).getRange(0, _w) >>> _roundBits;
      // reapply sign
      final signed = mux(neg, (~rounded + constW(1)).getRange(0, _w), rounded);
      // final clamp to [minV, maxV]
      final clamped = mux(
        gtSigned(signed, maxV),
        maxV,
        mux(gtSigned(minV, signed), minV, signed),
      );
      return clamped.getRange(0, projWidth);
    }

    output('proj_row') <= project(input('mv_row'));
    output('proj_col') <= project(input('mv_col'));
  }
}
