import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `frame_size()` + `superres_params()` + `compute_image_size()`.
///
/// Produces the frame dimensions and the mode-info grid (`MiCols`/`MiRows`) that
/// tile layout and the per-block decode loop are built on. When
/// `frame_size_override` is set the width/height are read with `f(n)` using the
/// bit widths from the sequence header (`frame_width_bits_minus_1 + 1`),
/// otherwise they come from the sequence header maxima. `superres_params()`
/// reads `use_superres` (gated on `enable_superres`) and the coded denominator
/// (`SuperresDenom = coded_denom + 9`). `MiCols = 2*((FrameWidth+7)>>3)`,
/// likewise `MiRows`. Combinational.
///
/// SCOPE: the superres horizontal DOWNSCALE (FrameWidth = round(UpscaledWidth*8
/// / SuperresDenom)) needs a variable-divisor divider and is left as a follow-up
/// - here `frame_width == upscaled_width` and MiCols is computed from it, which
/// is exact for the common no-superres case.
class HarborFrameSizeParser extends BridgeModule {
  HarborFrameSizeParser({int maxBytes = 16, String? name})
    : super('HarborFrameSizeParser', name: name ?? 'frame_size') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('frame_size_override', PortDirection.input, width: 1);
    createPort('frame_width_bits_minus_1', PortDirection.input, width: 4);
    createPort('frame_height_bits_minus_1', PortDirection.input, width: 4);
    createPort('max_frame_width_minus_1', PortDirection.input, width: 16);
    createPort('max_frame_height_minus_1', PortDirection.input, width: 16);
    createPort('enable_superres', PortDirection.input, width: 1);
    addOutput('frame_width', width: 17);
    addOutput('frame_height', width: 17);
    addOutput('upscaled_width', width: 17);
    addOutput('superres_denom', width: 5);
    addOutput('mi_cols', width: 16);
    addOutput('mi_rows', width: 16);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final override = input('frame_size_override');
    final enableSr = input('enable_superres');

    var idx = 0;
    // f(n) with a runtime-width n.
    (Logic, Logic) condFnL(Logic off, Logic cond, Logic n, Logic dflt) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= n;
      return (
        mux(cond, r.output('value'), dflt),
        mux(cond, r.output('next_offset'), off),
      );
    }

    (Logic, Logic) condFn(Logic off, Logic cond, int n, Logic dflt) =>
        condFnL(off, cond, Const(n, width: 6), dflt);

    final z = Const(0, width: 32);
    final off0 = Const(0, width: totalBits.bitLength);

    final wN =
        (input('frame_width_bits_minus_1').zeroExtend(6) + Const(1, width: 6))
            .getRange(0, 6);
    final hN =
        (input('frame_height_bits_minus_1').zeroExtend(6) + Const(1, width: 6))
            .getRange(0, 6);

    final (fwV, o1) = condFnL(off0, override, wN, z);
    final (fhV, o2) = condFnL(o1, override, hN, z);
    // frame_width_minus_1 from the read (override) or the seq-header max.
    final wM1 = mux(
      override,
      fwV.getRange(0, 16),
      input('max_frame_width_minus_1'),
    );
    final hM1 = mux(
      override,
      fhV.getRange(0, 16),
      input('max_frame_height_minus_1'),
    );
    final fw = (wM1.zeroExtend(17) + Const(1, width: 17)).getRange(0, 17);
    final fh = (hM1.zeroExtend(17) + Const(1, width: 17)).getRange(0, 17);

    // superres_params.
    final (usV, o3) = condFn(o2, enableSr, 1, z);
    final useSr = usV.getRange(0, 1);
    final (cdV, o4) = condFn(o3, useSr, 3, z);
    final denom = mux(
      useSr,
      (cdV.getRange(0, 5) + Const(9, width: 5)).getRange(0, 5),
      Const(8, width: 5),
    );

    // MiCols = 2 * ((FrameWidth + 7) >> 3), MiRows similarly.
    Logic miOf(Logic dim) =>
        (((dim + Const(7, width: 17)).getRange(0, 17) >>> 3).getRange(0, 16) <<
                1)
            .getRange(0, 16);

    output('frame_width') <= fw;
    output('frame_height') <= fh;
    output('upscaled_width') <= fw;
    output('superres_denom') <= denom;
    output('mi_cols') <= miOf(fw);
    output('mi_rows') <= miOf(fh);
    output('bits_consumed') <= o4.getRange(0, 8);
  }
}
