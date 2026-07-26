import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `delta_q_params()` + `delta_lf_params()` parser.
///
/// The frame header's delta-quantizer and delta-loop-filter signalling:
///   delta_q_present  f(1)  (only if base_q_idx > 0)
///   delta_q_res      f(2)  (if delta_q_present)
///   delta_lf_present f(1)  (if delta_q_present and not allow_intrabc)
///   delta_lf_res     f(2)  (if delta_lf_present)
///   delta_lf_multi   f(1)  (if delta_lf_present)
/// These enable per-superblock quantizer / loop-filter deltas in the tile data.
/// `base_q_idx` (from quantization_params) and `allow_intrabc` gate the reads.
/// Conditional-read idiom. Combinational.
class HarborDeltaParamsParser extends BridgeModule {
  HarborDeltaParamsParser({int maxBytes = 16, String? name})
    : super('HarborDeltaParamsParser', name: name ?? 'delta_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('base_q_idx', PortDirection.input, width: 8);
    createPort('allow_intrabc', PortDirection.input, width: 1);
    addOutput('delta_q_present', width: 1);
    addOutput('delta_q_res', width: 2);
    addOutput('delta_lf_present', width: 1);
    addOutput('delta_lf_res', width: 2);
    addOutput('delta_lf_multi', width: 1);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final baseQnz = input('base_q_idx').or();
    final notIntrabc = ~input('allow_intrabc');

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

    final z = Const(0, width: 32);
    final off0 = Const(0, width: totalBits.bitLength);

    final (dqpV, o1) = condFn(off0, baseQnz, 1, z);
    final dqp = dqpV.getRange(0, 1);
    final (dqrV, o2) = condFn(o1, dqp, 2, z);

    final lfGate = dqp & notIntrabc;
    final (dlpV, o3) = condFn(o2, lfGate, 1, z);
    final dlp = dlpV.getRange(0, 1);
    final (dlrV, o4) = condFn(o3, dlp, 2, z);
    final (dlmV, o5) = condFn(o4, dlp, 1, z);

    output('delta_q_present') <= dqp;
    output('delta_q_res') <= dqrV.getRange(0, 2);
    output('delta_lf_present') <= dlp;
    output('delta_lf_res') <= dlrV.getRange(0, 2);
    output('delta_lf_multi') <= dlmV.getRange(0, 1);
    output('bits_consumed') <= o5.getRange(0, 8);
  }
}
