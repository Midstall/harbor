import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `render_size()` parser.
///
/// Reads the display (render) dimensions: `render_and_frame_size_different`
/// f(1). When set, `render_width_minus_1`/`render_height_minus_1` f(16) each
/// (RenderWidth = value + 1), otherwise the render size equals the upscaled
/// frame size. Combinational.
class HarborRenderSizeParser extends BridgeModule {
  HarborRenderSizeParser({int maxBytes = 16, String? name})
    : super('HarborRenderSizeParser', name: name ?? 'render_size') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('upscaled_width', PortDirection.input, width: 17);
    createPort('frame_height', PortDirection.input, width: 17);
    addOutput('render_width', width: 17);
    addOutput('render_height', width: 17);
    addOutput('render_different', width: 1);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
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

    final z = Const(0, width: 32);
    final off0 = Const(0, width: totalBits.bitLength);

    final (diffV, o1) = condFn(off0, one, 1, z);
    final diff = diffV.getRange(0, 1);
    final (rwV, o2) = condFn(o1, diff, 16, z);
    final (rhV, o3) = condFn(o2, diff, 16, z);

    final rw = (rwV.getRange(0, 17) + Const(1, width: 17)).getRange(0, 17);
    final rh = (rhV.getRange(0, 17) + Const(1, width: 17)).getRange(0, 17);

    output('render_width') <= mux(diff, rw, input('upscaled_width'));
    output('render_height') <= mux(diff, rh, input('frame_height'));
    output('render_different') <= diff;
    output('bits_consumed') <= o3.getRange(0, 8);
  }
}
