import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';
import 'su_reader.dart';

/// Harbor AV1 `quantization_params()` parser.
///
/// The frame header's quantizer section: `base_q_idx` (the frame quantizer that
/// feeds dequant) plus the per-plane DC/AC delta-Q values and the optional
/// quant-matrix indices. Built on the descriptor readers with the
/// conditional-read idiom (a reader sits at the running offset and only advances
/// / takes its value when its field is present). `read_delta_q()` is a gated
/// helper: `delta_coded = f(1)`, then `delta_q = su(7)` if coded, else 0.
///
/// Inputs `num_planes` and `separate_uv_delta_q` come from `color_config()`.
/// Delta-Q outputs are signed (two's complement, su(7) range -64..63). Outputs
/// `bits_consumed` for chaining. Combinational.
class HarborQuantParamsParser extends BridgeModule {
  HarborQuantParamsParser({int maxBytes = 16, String? name})
    : super('HarborQuantParamsParser', name: name ?? 'quant_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('separate_uv_delta_q', PortDirection.input, width: 1);
    addOutput('base_q_idx', width: 8);
    addOutput('delta_q_y_dc', width: 8);
    addOutput('delta_q_u_dc', width: 8);
    addOutput('delta_q_u_ac', width: 8);
    addOutput('delta_q_v_dc', width: 8);
    addOutput('delta_q_v_ac', width: 8);
    addOutput('using_qmatrix', width: 1);
    addOutput('qm_y', width: 4);
    addOutput('qm_u', width: 4);
    addOutput('qm_v', width: 4);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final planesGt1 = input('num_planes').gt(Const(1, width: 2));
    final separateUv = input('separate_uv_delta_q');
    final one = Const(1, width: 1);

    var idx = 0;
    (Logic, Logic) condFn(Logic off, Logic cond, int n, Logic dflt) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= Const(n, width: 6);
      return (
        mux(cond, r.output('value'), dflt),
        mux(cond, r.output('next_offset'), off),
      );
    }

    (Logic, Logic) condSu(Logic off, Logic cond, int n, Logic dflt) {
      final r = HarborSuReader(maxBytes: maxBytes, name: 'su${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= Const(n, width: 6);
      return (
        mux(cond, r.output('value'), dflt),
        mux(cond, r.output('next_offset'), off),
      );
    }

    final zero32 = Const(0, width: 32);
    final off0 = Const(0, width: input('bytes').width.bitLength);

    // read_delta_q(off, gate): f(1) + conditional su(7), all gated.
    (Logic, Logic) readDeltaQ(Logic off, Logic gate) {
      final (dcV, o1) = condFn(off, gate, 1, zero32);
      final dc = dcV.getRange(0, 1) & gate;
      final (dqV, o2) = condSu(o1, dc, 7, zero32);
      return (dqV, o2);
    }

    // base_q_idx f(8).
    final (bqV, o1) = condFn(off0, one, 8, zero32);

    // Luma delta-Q (always present).
    final (yDc, o2) = readDeltaQ(o1, one);

    // Chroma block when NumPlanes > 1.
    final (duvV, o3) = condFn(o2, planesGt1 & separateUv, 1, zero32);
    final diffUv = duvV.getRange(0, 1);
    final (uDc, o4) = readDeltaQ(o3, planesGt1);
    final (uAc, o5) = readDeltaQ(o4, planesGt1);
    final (vDc, o6) = readDeltaQ(o5, planesGt1 & diffUv);
    final (vAc, o7) = readDeltaQ(o6, planesGt1 & diffUv);
    // When diff_uv is 0, V deltas mirror U.
    final vDcFinal = mux(planesGt1 & ~diffUv, uDc, vDc);
    final vAcFinal = mux(planesGt1 & ~diffUv, uAc, vAc);

    // using_qmatrix f(1) and the qm indices.
    final (uqmV, o8) = condFn(o7, one, 1, zero32);
    final uqm = uqmV.getRange(0, 1);
    final (qmYv, o9) = condFn(o8, uqm, 4, zero32);
    final (qmUv, o10) = condFn(o9, uqm, 4, zero32);
    final (qmVv, o11) = condFn(o10, uqm & separateUv, 4, zero32);
    final qmVfinal = mux(uqm & ~separateUv, qmUv, qmVv);

    output('base_q_idx') <= bqV.getRange(0, 8);
    output('delta_q_y_dc') <= yDc.getRange(0, 8);
    output('delta_q_u_dc') <= uDc.getRange(0, 8);
    output('delta_q_u_ac') <= uAc.getRange(0, 8);
    output('delta_q_v_dc') <= vDcFinal.getRange(0, 8);
    output('delta_q_v_ac') <= vAcFinal.getRange(0, 8);
    output('using_qmatrix') <= uqm;
    output('qm_y') <= qmYv.getRange(0, 4);
    output('qm_u') <= qmUv.getRange(0, 4);
    output('qm_v') <= qmVfinal.getRange(0, 4);
    output('bits_consumed') <= o11.getRange(0, 8);
  }
}
