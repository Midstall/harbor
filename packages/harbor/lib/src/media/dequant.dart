import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 coefficient dequantizer (libaom `read_coeffs` tail).
///
/// Reproduces the per-coefficient dequant the software decoder performs right
/// before the inverse transform: `dqv = is_dc ? dc_q : ac_q`,
/// `dq = (level * dqv) & 0xFFFFFF`, `dq >>= shift`, `if (sign) dq = -dq`,
/// `dq = clamp(dq, -(1<<(7+bd)), (1<<(7+bd))-1)`. The `& 0xFFFFFF` and the
/// `shift` (= `av1_get_tx_scale`: 0 for area <= 256, 1 for 512/1024, 2 above)
/// match libaom exactly.
///
/// [bitDepth] sets the clamp range (and the output width = bitDepth + 8). The
/// quantizer step `dc_q` / `ac_q` comes from the dc/ac qlookup tables for the
/// active bit depth (driven in as data). `level` is the unsigned coefficient
/// magnitude (already `& 0xFFFFF`), `sign` its sign bit, `is_dc` selects the DC
/// step, `shift` the tx-size dequant scale. Combinational.
class HarborDequant extends BridgeModule {
  /// Sample bit depth (8/10/12), sets the clamp range and output width.
  final int bitDepth;

  HarborDequant({this.bitDepth = 8, String? name})
    : super('HarborDequant', name: name ?? 'dequant') {
    final outW = bitDepth + 8; // signed, clamp range is +-(1<<(7+bd))

    createPort('level', PortDirection.input, width: 20); // magnitude & 0xFFFFF
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    createPort('is_dc', PortDirection.input);
    createPort('sign', PortDirection.input);
    createPort('shift', PortDirection.input, width: 2);
    addOutput('dq_coeff', width: outW);

    final dqv = mux(input('is_dc'), input('dc_q'), input('ac_q'));
    // (level * dqv) & 0xFFFFFF, then >> shift (logical, magnitude is positive).
    final prod = (input('level').zeroExtend(40) * dqv.zeroExtend(40)).getRange(
      0,
      24,
    );
    final shifted = (prod.zeroExtend(32) >>> input('shift')).getRange(0, 32);

    // Apply sign, then clamp to the signed (7+bd)-bit range.
    final maxV = (1 << (7 + bitDepth)) - 1;
    final minV = -(1 << (7 + bitDepth));
    final signed = mux(input('sign'), (Const(0, width: 32) - shifted), shifted);
    final maxC = Const(BigInt.from(maxV).toUnsigned(32), width: 32);
    final minC = Const(BigInt.from(minV).toUnsigned(32), width: 32);
    // signed > maxV  <=>  (maxV - signed) < 0, signed < minV similarly.
    final gtMax = (maxC - signed)[31];
    final ltMin = (signed - minC)[31];
    final clamped = mux(ltMin, minC, mux(gtMax, maxC, signed));

    output('dq_coeff') <= clamped.getRange(0, outW);
  }
}
