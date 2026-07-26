import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';
import 'su_reader.dart';

/// Harbor AV1 `segmentation_params()` parser.
///
/// Decodes the per-segment feature table: for each of 8 segments and 8 features,
/// a `feature_enabled` bit and (for features with nonzero width) a value read at
/// the feature's fixed width and signedness, clipped to the feature's range. The
/// feature geometry is the AV1 constant tables Segmentation_Feature_Bits /
/// _Signed / _Max. Signed features use `su(1 + bits)` (so the only out-of-range
/// case is the most-negative value, which clips to -max, a single equality
/// check). The one unsigned feature (REF_FRAME, 3 bits) is already in range.
///
/// `segmentation_enabled` gates everything. When the frame has no primary
/// reference (`primary_ref_none`) the update flags are inferred (map+data = 1)
/// rather than read. Exposes the 8x8 enable/data grid plus the update flags.
/// Conditional-read idiom over the descriptor readers. Combinational.
class HarborSegmentationParamsParser extends BridgeModule {
  static const featBits = [8, 6, 6, 6, 6, 3, 0, 0];
  static const featSigned = [1, 1, 1, 1, 1, 0, 0, 0];
  static const featMax = [255, 63, 63, 63, 63, 7, 0, 0];

  HarborSegmentationParamsParser({int maxBytes = 64, String? name})
    : super('HarborSegmentationParamsParser', name: name ?? 'seg_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('primary_ref_none', PortDirection.input, width: 1);
    addOutput('segmentation_enabled', width: 1);
    addOutput('update_map', width: 1);
    addOutput('temporal_update', width: 1);
    addOutput('update_data', width: 1);
    for (var i = 0; i < 8; i++) {
      for (var j = 0; j < 8; j++) {
        addOutput('feature_enabled_${i}_$j', width: 1);
        addOutput('feature_data_${i}_$j', width: 16); // signed
      }
    }
    addOutput('bits_consumed', width: 16);

    final bytesIn = input('bytes');
    final primNone = input('primary_ref_none');
    final one = Const(1, width: 1);
    final offW = totalBits.bitLength;

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

    final (segEnV, o1) = condFn(Const(0, width: offW), one, 1, z);
    final segEn = segEnV.getRange(0, 1);
    final mapGate = segEn & ~primNone;
    final (umV, o2) = condFn(o1, mapGate, 1, z);
    final umRead = umV.getRange(0, 1);
    final updateMap = mux(
      segEn,
      mux(primNone, one, umRead),
      Const(0, width: 1),
    );
    final (tuV, o3) = condFn(o2, mapGate & umRead, 1, z);
    final temporal = mux(
      mapGate & umRead,
      tuV.getRange(0, 1),
      Const(0, width: 1),
    );
    final (udV, o4) = condFn(o3, mapGate, 1, z);
    final updateData = mux(
      segEn,
      mux(primNone, one, udV.getRange(0, 1)),
      Const(0, width: 1),
    );

    final loopGate = updateData;
    var off = o4;
    final feEnabled = <List<Logic>>[];
    final feData = <List<Logic>>[];
    for (var i = 0; i < 8; i++) {
      final enRow = <Logic>[];
      final dataRow = <Logic>[];
      for (var j = 0; j < 8; j++) {
        final (feV, on) = condFn(off, loopGate, 1, z);
        final fe = feV.getRange(0, 1);
        final enabled = loopGate & fe;
        off = on;
        Logic data = Const(0, width: 16);
        if (featBits[j] > 0) {
          if (featSigned[j] == 1) {
            final w = 1 + featBits[j];
            final (vV, on2) = condSu(off, enabled, w, z);
            final isMin = vV
                .getRange(0, w)
                .eq(Const(1 << featBits[j], width: w));
            final clipped = mux(
              isMin,
              Const((-featMax[j]) & 0xFFFF, width: 16),
              vV.getRange(0, 16),
            );
            data = mux(enabled, clipped, Const(0, width: 16));
            off = on2;
          } else {
            final (vV, on2) = condFn(off, enabled, featBits[j], z);
            data = mux(enabled, vV.getRange(0, 16), Const(0, width: 16));
            off = on2;
          }
        }
        enRow.add(enabled);
        dataRow.add(data);
      }
      feEnabled.add(enRow);
      feData.add(dataRow);
    }

    output('segmentation_enabled') <= segEn;
    output('update_map') <= updateMap;
    output('temporal_update') <= temporal;
    output('update_data') <= updateData;
    for (var i = 0; i < 8; i++) {
      for (var j = 0; j < 8; j++) {
        output('feature_enabled_${i}_$j') <= feEnabled[i][j];
        output('feature_data_${i}_$j') <= feData[i][j];
      }
    }
    output('bits_consumed') <= off.zeroExtend(16);
  }
}
