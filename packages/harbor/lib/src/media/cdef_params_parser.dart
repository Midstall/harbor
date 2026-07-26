import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `cdef_params()` parser.
///
/// The frame header's CDEF section, feeding the CDEF filter (HarborCdefBlock):
/// the damping, the number of strength sets (`cdef_bits`), and per-set luma /
/// chroma primary+secondary strengths. The strength loop runs `1 << cdef_bits`
/// times (up to 8). Each iteration reads y_pri f(4), y_sec f(2) (the AV1 quirk:
/// a coded secondary strength of 3 becomes 4), and the same for chroma when
/// `num_planes > 1`. A `cdef_disabled` input (CodedLossless || allow_intrabc ||
/// !enable_cdef) collapses everything to the defaults (damping 3, all strengths
/// 0). Built with the conditional-read idiom. Eight iterations are instantiated
/// and gated by `i < (1 << cdef_bits)`. Combinational.
class HarborCdefParamsParser extends BridgeModule {
  HarborCdefParamsParser({int maxBytes = 16, String? name})
    : super('HarborCdefParamsParser', name: name ?? 'cdef_params') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('num_planes', PortDirection.input, width: 2);
    createPort('cdef_disabled', PortDirection.input, width: 1);
    addOutput('cdef_damping', width: 4); // 3..6
    addOutput('cdef_bits', width: 2);
    for (var i = 0; i < 8; i++) {
      addOutput('y_pri_$i', width: 4);
      addOutput('y_sec_$i', width: 3);
      addOutput('uv_pri_$i', width: 4);
      addOutput('uv_sec_$i', width: 3);
    }
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final planesGt1 = input('num_planes').gt(Const(1, width: 2));
    final gateBase = ~input('cdef_disabled');

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

    final (dampV, o1) = condFn(off0, gateBase, 2, z);
    final (cbV, o2) = condFn(o1, gateBase, 2, z);
    final cdefBits = cbV.getRange(0, 2);
    // numStrengths = 1 << cdef_bits (1..8).
    final numStr = (Const(1, width: 5) << cdefBits.zeroExtend(5)).getRange(
      0,
      5,
    );

    // y_sec / uv_sec: a coded value of 3 maps to 4.
    Logic secAdjust(Logic raw) {
      final r2 = raw.getRange(0, 2);
      return mux(
        r2.eq(Const(3, width: 2)),
        Const(4, width: 3),
        r2.zeroExtend(3),
      );
    }

    var off = o2;
    final yPri = <Logic>[],
        ySec = <Logic>[],
        uvPri = <Logic>[],
        uvSec = <Logic>[];
    for (var i = 0; i < 8; i++) {
      final active = gateBase & Const(i, width: 5).lt(numStr);
      final (yp, a1) = condFn(off, active, 4, z);
      final (ys, a2) = condFn(a1, active, 2, z);
      final (up, a3) = condFn(a2, active & planesGt1, 4, z);
      final (us, a4) = condFn(a3, active & planesGt1, 2, z);
      yPri.add(yp.getRange(0, 4));
      ySec.add(secAdjust(ys));
      uvPri.add(up.getRange(0, 4));
      uvSec.add(secAdjust(us));
      off = a4;
    }

    output('cdef_damping') <=
        (dampV.getRange(0, 4) + Const(3, width: 4)).getRange(0, 4);
    output('cdef_bits') <= cdefBits;
    for (var i = 0; i < 8; i++) {
      output('y_pri_$i') <= yPri[i];
      output('y_sec_$i') <= ySec[i];
      output('uv_pri_$i') <= uvPri[i];
      output('uv_sec_$i') <= uvSec[i];
    }
    output('bits_consumed') <= off.getRange(0, 8);
  }
}
