import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `color_config()` parser.
///
/// Decodes the colour section of the sequence header: bit depth, monochrome,
/// the optional colour description (primaries / transfer / matrix), colour
/// range, chroma subsampling and sample position. It is a combinational cascade
/// of [HarborBitReader]s using the conditional-read idiom: each reader sits at a
/// running offset, but the offset only advances (and the field is taken instead
/// of its default) when that field's presence condition holds, so optional
/// `f(n)` reads thread correctly.
///
/// `seq_profile` selects the branches exactly as the spec: bit depth comes from
/// high_bitdepth (+ twelve_bit for profile 2), profile 1 forces colour (no
/// monochrome), and subsampling is fixed for profiles 0/1 but coded for profile
/// 2 at 12-bit. The sRGB shortcut (BT.709 + sRGB transfer + identity matrix)
/// skips the colour-range/subsampling reads. `bits_consumed` is the bit length.
/// Combinational.
class HarborColorConfigParser extends BridgeModule {
  HarborColorConfigParser({int maxBytes = 16, String? name})
    : super('HarborColorConfigParser', name: name ?? 'color_config') {
    final totalBits = maxBytes * 8;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('seq_profile', PortDirection.input, width: 3);
    addOutput('bit_depth', width: 5);
    addOutput('mono_chrome', width: 1);
    addOutput('num_planes', width: 2);
    addOutput('color_primaries', width: 8);
    addOutput('transfer_characteristics', width: 8);
    addOutput('matrix_coefficients', width: 8);
    addOutput('color_range', width: 1);
    addOutput('subsampling_x', width: 1);
    addOutput('subsampling_y', width: 1);
    addOutput('chroma_sample_position', width: 2);
    addOutput('separate_uv_delta_q', width: 1);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final profile = input('seq_profile');
    final p1 = profile.eq(Const(1, width: 3));
    final p2 = profile.eq(Const(2, width: 3));
    final one = Const(1, width: 1);

    var idx = 0;
    // Read f(n) at [off], advance + take the value only when [cond] holds.
    (Logic, Logic) condRead(Logic off, Logic cond, int n, Logic dflt) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= Const(n, width: 6);
      final val = mux(cond, r.output('value'), dflt);
      final nxt = mux(cond, r.output('next_offset'), off);
      return (val, nxt);
    }

    Logic d(int v, int w) => Const(v, width: w);

    var off = Const(0, width: 8) as Logic;

    // high_bitdepth f(1), then twelve_bit f(1) only for profile 2.
    final (hbdV, o1) = condRead(off, one, 1, d(0, 32));
    final hbd = hbdV.getRange(0, 1);
    final twelveCond = p2 & hbd;
    final (twelveV, o2) = condRead(o1, twelveCond, 1, d(0, 32));
    final twelve = twelveV.getRange(0, 1);
    // BitDepth.
    final bd = mux(
      twelveCond,
      mux(twelve, d(12, 5), d(10, 5)),
      mux(hbd, d(10, 5), d(8, 5)),
    );

    // mono_chrome f(1) unless profile 1.
    final monoCond = ~p1;
    final (monoV, o3) = condRead(o2, monoCond, 1, d(0, 32));
    final mono = monoV.getRange(0, 1);

    // color_description_present_flag f(1), then optional 3 bytes.
    final (cdpV, o4) = condRead(o3, one, 1, d(0, 32));
    final cdp = cdpV.getRange(0, 1);
    final (cpV, o5) = condRead(o4, cdp, 8, d(2, 32)); // CP_UNSPECIFIED
    final (tcV, o6) = condRead(o5, cdp, 8, d(2, 32)); // TC_UNSPECIFIED
    final (mcV, o7) = condRead(o6, cdp, 8, d(2, 32)); // MC_UNSPECIFIED
    final cp = cpV.getRange(0, 8);
    final tc = tcV.getRange(0, 8);
    final mc = mcV.getRange(0, 8);

    // sRGB shortcut: BT.709 (1) + sRGB transfer (13) + identity matrix (0).
    final isSrgb = cp.eq(d(1, 8)) & tc.eq(d(13, 8)) & mc.eq(d(0, 8)) & ~mono;

    // color_range f(1): read for mono, or non-mono-non-sRGB, defaults to 1.
    final crCond = mono | (~isSrgb & ~mono);
    final (crV, o8) = condRead(o7, crCond, 1, d(1, 32));
    final colorRange = crV.getRange(0, 1);

    // subsampling: only profile-2/12-bit codes it, others are fixed.
    final p2sub = ~mono & ~isSrgb & p2 & bd.eq(d(12, 5));
    final (ssxV, o9) = condRead(o8, p2sub, 1, d(1, 32));
    final ssxRead = ssxV.getRange(0, 1);
    final ssyCond = p2sub & ssxRead;
    final (ssyV, o10) = condRead(o9, ssyCond, 1, d(0, 32));
    final ssyRead = ssyV.getRange(0, 1);

    // Resolve subsampling across all branches.
    final p0 = profile.eq(Const(0, width: 3));
    final ssx = mux(
      mono,
      one,
      mux(
        isSrgb,
        d(0, 1),
        mux(p0, one, mux(p1, d(0, 1), mux(bd.eq(d(12, 5)), ssxRead, one))),
      ),
    ); // profile 2: 12-bit coded else 1
    final ssy = mux(
      mono,
      one,
      mux(
        isSrgb,
        d(0, 1),
        mux(
          p0,
          one,
          mux(
            p1,
            d(0, 1),
            mux(bd.eq(d(12, 5)), mux(ssxRead, ssyRead, d(0, 1)), d(0, 1)),
          ),
        ),
      ),
    );

    // chroma_sample_position f(2) when non-mono, non-sRGB, and 4:2:0.
    final cspCond = ~mono & ~isSrgb & ssx & ssy;
    final (cspV, o11) = condRead(o10, cspCond, 2, d(0, 32));

    // separate_uv_delta_q f(1) always.
    final (suvV, o12) = condRead(o11, one, 1, d(0, 32));

    output('bit_depth') <= bd;
    output('mono_chrome') <= mono;
    output('num_planes') <= mux(mono, d(1, 2), d(3, 2));
    output('color_primaries') <= cp;
    output('transfer_characteristics') <= tc;
    output('matrix_coefficients') <= mc;
    output('color_range') <= colorRange;
    output('subsampling_x') <= ssx;
    output('subsampling_y') <= ssy;
    output('chroma_sample_position') <= cspV.getRange(0, 2);
    output('separate_uv_delta_q') <= suvV.getRange(0, 1);
    output('bits_consumed') <= o12;
  }
}
