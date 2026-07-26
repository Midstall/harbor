import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 sequence-header parser (reduced_still_picture_header path).
///
/// First real syntax built on the descriptor readers: a combinational cascade of
/// [HarborBitReader] instances, each reading one `f(n)` field and threading its
/// `next_offset` into the next, so the whole header parses in one shot. This
/// covers the `reduced_still_picture_header == 1` path of `sequence_header_obu`
/// up through the max frame size:
///   seq_profile               f(3)
///   still_picture             f(1)
///   reduced_still_picture     f(1)
///   seq_level_idx[0]          f(5)
///   frame_width_bits_minus_1  f(4)
///   frame_height_bits_minus_1 f(4)
///   max_frame_width_minus_1   f(frame_width_bits_minus_1 + 1)
///   max_frame_height_minus_1  f(frame_height_bits_minus_1 + 1)
/// The last two reads use a width derived from earlier fields, which is exactly
/// what threading a runtime `n` into the reader buys. `frame_width`/`height` are
/// the decoded maxima (minus_1 + 1). `supported` mirrors reduced_still_picture
/// (the full operating-points path is iterative and a follow-up). Combinational.
class HarborSeqHeaderParser extends BridgeModule {
  HarborSeqHeaderParser({int maxBytes = 16, String? name})
    : super('HarborSeqHeaderParser', name: name ?? 'seq_header') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    addOutput('seq_profile', width: 3);
    addOutput('still_picture', width: 1);
    addOutput('reduced_still_picture', width: 1);
    addOutput('seq_level_idx', width: 5);
    addOutput('frame_width', width: 32);
    addOutput('frame_height', width: 32);
    addOutput('bits_consumed', width: 8);
    addOutput('supported', width: 1);

    final bytesIn = input('bytes');

    var idx = 0;
    // Read f(n) at [off]. n may be a constant or a runtime Logic. Returns the
    // reader so the caller can take value/next_offset.
    HarborBitReader read(Logic off, Logic n) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= n;
      return r;
    }

    Logic c(int v) => Const(v, width: 6);

    final off0 = Const(0, width: 8);
    final rProfile = read(off0, c(3));
    final rStill = read(rProfile.output('next_offset'), c(1));
    final rReduced = read(rStill.output('next_offset'), c(1));
    final rLevel = read(rReduced.output('next_offset'), c(5));
    final rWBits = read(rLevel.output('next_offset'), c(4));
    final rHBits = read(rWBits.output('next_offset'), c(4));

    // n for the max-size reads is (bits_minus_1 + 1), a runtime value.
    final wN = (rWBits.output('value').getRange(0, 6) + Const(1, width: 6))
        .getRange(0, 6);
    final hN = (rHBits.output('value').getRange(0, 6) + Const(1, width: 6))
        .getRange(0, 6);
    final rW = read(rHBits.output('next_offset'), wN);
    final rH = read(rW.output('next_offset'), hN);

    output('seq_profile') <= rProfile.output('value').getRange(0, 3);
    output('still_picture') <= rStill.output('value').getRange(0, 1);
    output('reduced_still_picture') <= rReduced.output('value').getRange(0, 1);
    output('seq_level_idx') <= rLevel.output('value').getRange(0, 5);
    output('frame_width') <=
        (rW.output('value') + Const(1, width: 32)).getRange(0, 32);
    output('frame_height') <=
        (rH.output('value') + Const(1, width: 32)).getRange(0, 32);
    output('bits_consumed') <= rH.output('next_offset');
    output('supported') <= rReduced.output('value').getRange(0, 1);
  }
}
