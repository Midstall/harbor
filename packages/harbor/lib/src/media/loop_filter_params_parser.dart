import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';
import 'su_reader.dart';

/// Harbor AV1 `loop_filter_params()` parser.
///
/// The frame header's deblock section: it yields the loop-filter levels and
/// sharpness that [HarborDeblockLimits] / [HarborDeblockEdge] consume, plus the
/// per-reference and per-mode delta tables. Structure:
///   loop_filter_level[0..1]            f(6) each
///   loop_filter_level[2..3]            f(6) each, only if chroma and a level is set
///   loop_filter_sharpness              f(3)
///   loop_filter_delta_enabled          f(1)
///   if enabled: delta_update f(1), then if update, 8 ref + 2 mode su(7) deltas
/// When `coded_lossless` is set the whole function is skipped (levels 0). Ref
/// deltas default to AV1's {1,0,0,0,-1,0,-1,-1} and mode deltas to {0,0} when
/// not updated. Built with the conditional-read idiom over the descriptor
/// readers. Combinational.
class HarborLoopFilterParamsParser extends BridgeModule {
  HarborLoopFilterParamsParser({int maxBytes = 16, String? name})
    : super('HarborLoopFilterParamsParser', name: name ?? 'lf_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('coded_lossless', PortDirection.input, width: 1);
    for (var i = 0; i < 4; i++) {
      addOutput('loop_filter_level_$i', width: 6);
    }
    addOutput('sharpness', width: 3);
    addOutput('delta_enabled', width: 1);
    addOutput('delta_update', width: 1);
    for (var i = 0; i < 8; i++) {
      addOutput('ref_delta_$i', width: 8); // signed
    }
    for (var i = 0; i < 2; i++) {
      addOutput('mode_delta_$i', width: 8); // signed
    }
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final planesGt1 = input('num_planes').gt(Const(1, width: 2));
    final notLossless = ~input('coded_lossless');

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

    final z = Const(0, width: 32);
    Logic d32(int v) => Const(v & 0xFFFFFFFF, width: 32);
    final off0 = Const(0, width: totalBits.bitLength);

    final (l0, o1) = condFn(off0, notLossless, 6, z);
    final (l1, o2) = condFn(o1, notLossless, 6, z);
    final anyLevel = l0.getRange(0, 6).or() | l1.getRange(0, 6).or();
    final chromaGate = notLossless & planesGt1 & anyLevel;
    final (l2, o3) = condFn(o2, chromaGate, 6, z);
    final (l3, o4) = condFn(o3, chromaGate, 6, z);

    final (sh, o5) = condFn(o4, notLossless, 3, z);
    final (deV, o6) = condFn(o5, notLossless, 1, z);
    final deEn = deV.getRange(0, 1);
    final (duV, o7) = condFn(o6, notLossless & deEn, 1, z);
    final duUp = duV.getRange(0, 1);
    final loopGate = notLossless & deEn & duUp;

    // 8 ref deltas, then 2 mode deltas, threading the offset.
    const refDefaults = [1, 0, 0, 0, -1, 0, -1, -1];
    var off = o7;
    final refDeltas = <Logic>[];
    for (var i = 0; i < 8; i++) {
      final (ufV, on) = condFn(off, loopGate, 1, z);
      final upd = ufV.getRange(0, 1);
      final (dv, on2) = condSu(on, loopGate & upd, 7, d32(refDefaults[i]));
      refDeltas.add(dv);
      off = on2;
    }
    final modeDeltas = <Logic>[];
    for (var i = 0; i < 2; i++) {
      final (ufV, on) = condFn(off, loopGate, 1, z);
      final upd = ufV.getRange(0, 1);
      final (dv, on2) = condSu(on, loopGate & upd, 7, z);
      modeDeltas.add(dv);
      off = on2;
    }

    output('loop_filter_level_0') <= l0.getRange(0, 6);
    output('loop_filter_level_1') <= l1.getRange(0, 6);
    output('loop_filter_level_2') <= l2.getRange(0, 6);
    output('loop_filter_level_3') <= l3.getRange(0, 6);
    output('sharpness') <= sh.getRange(0, 3);
    output('delta_enabled') <= deEn;
    output('delta_update') <= duUp;
    for (var i = 0; i < 8; i++) {
      output('ref_delta_$i') <= refDeltas[i].getRange(0, 8);
    }
    for (var i = 0; i < 2; i++) {
      output('mode_delta_$i') <= modeDeltas[i].getRange(0, 8);
    }
    output('bits_consumed') <= off.getRange(0, 8);
  }
}
