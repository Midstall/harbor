import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock_frame_pass.dart';
import 'deblock_limits.dart';
import 'decode_frame_intra.dart';

/// Harbor AV1 intra decoder: bitstream -> reconstructed + deblocked picture.
///
/// The complete intra-decode pipeline in one module: [HarborDecodeFrameIntra]
/// turns the entropy bitstream into a reconstructed `gridW x gridH` grid of 4x4
/// blocks (entropy decode -> dequant -> inverse DCT -> intra predict), then
/// [HarborDeblockFramePass] applies the in-loop deblocking filter over the block
/// edges. The deblock thresholds come from a `filter_level` + `sharpness` via
/// [HarborDeblockLimits], exactly as AV1 derives them.
///
/// Pulse `start`, feed the stream on `bytes_in` (advancing by `byte_pop`). When
/// `done` asserts, `frame` holds the final filtered picture (pixel (y,x) at
/// `[(y*W + x)*8 +: 8]`, W = gridW*4). This is a working (simplified-fidelity)
/// AV1 intra picture decoder, bitstream to pixels, end to end.
class HarborIntraDecoder extends BridgeModule {
  HarborIntraDecoder({int gridW = 4, int gridH = 4, String? name})
    : super('HarborIntraDecoder', name: name ?? 'intra_decoder') {
    final fw = gridW * 4;
    final fh = gridH * 4;

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('bytes_in', PortDirection.input, width: 24);
    createPort('dc_q', PortDirection.input, width: 8);
    createPort('ac_q', PortDirection.input, width: 8);
    createPort('filter_level', PortDirection.input, width: 6);
    createPort('sharpness', PortDirection.input, width: 3);
    addOutput('byte_pop', width: 2);
    addOutput('frame', width: fw * fh * 8);
    addOutput('recon_frame', width: fw * fh * 8); // pre-deblock (debug/inspect)
    addOutput('done', width: 1);

    // Decode + reconstruct.
    final dec = HarborDecodeFrameIntra(gridW: gridW, gridH: gridH, name: 'dec');
    addSubModule(dec);
    for (final port in ['clk', 'reset', 'start', 'bytes_in', 'dc_q', 'ac_q']) {
      dec.input(port).srcConnection! <= input(port);
    }
    output('byte_pop') <= dec.output('byte_pop');

    // Deblock thresholds from filter_level + sharpness.
    final lim = HarborDeblockLimits(name: 'lim');
    addSubModule(lim);
    lim.input('filter_level').srcConnection! <= input('filter_level');
    lim.input('sharpness').srcConnection! <= input('sharpness');

    // Deblock the reconstructed frame.
    final pass = HarborDeblockFramePass(width: fw, height: fh, name: 'deblock');
    addSubModule(pass);
    pass.input('frame').srcConnection! <= dec.output('frame');
    pass.input('blimit').srcConnection! <= lim.output('blimit');
    pass.input('limit').srcConnection! <= lim.output('limit');
    pass.input('thresh').srcConnection! <= lim.output('thresh');
    // flat_thresh 0 keeps the narrow filter4 (4x4 block granularity). The wide
    // filter8 would only engage on an exactly-constant region (where it matches).
    pass.input('flat_thresh').srcConnection! <= Const(0, width: 8);

    // While decoding the frame is partial. The deblocked output is meaningful
    // when `done` asserts (the reconstructed frame is then stable).
    output('frame') <= pass.output('out');
    output('recon_frame') <= dec.output('frame');
    output('done') <= dec.output('done');
  }
}
