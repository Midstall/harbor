import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';

/// Harbor end-to-end AV1 keyframe intra decode for ONE 32x32 superblock ROOT
/// (BLOCK_32X32, `rootBsize` 9) that is a SINGLE PARTITION_NONE leaf decoded as
/// one TX_32X32 transform block: coded bytes -> reconstructed 32x32 luma via the
/// SEQUENTIAL recon walk (row-by-row predict + transform), the build-scalable
/// path that replaces the flat recon walk at 32x32.
///
/// This is the end-to-end coeff->pixel proof for a TX_32X32 leaf: the mode walk
/// decodes the 1024-coeff block inline (maxTxN 1024 / tx32), and
/// [HarborIntraReconWalkSeq] (sbSize 32, one 32x32 leaf, maxLog2 3) reconstructs
/// it. Mirrors [HarborKeyframeDecodeRoot32] but single-leaf, TX_32X32, and the
/// sequential recon walk.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (32*32*8). Scope: a 32x32 SB that is a NONE TX_32X32 leaf, mono luma.
class HarborKeyframeDecodeSb32 extends BridgeModule {
  final int maxBytes;

  HarborKeyframeDecodeSb32({this.maxBytes = 384, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super('HarborKeyframeDecodeSb32', name: name ?? 'keyframe_decode_sb32') {
    const sbSize = 32;
    const nPix = sbSize * sbSize;
    const leafCoeffN = 1024; // TX_32X32

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('frame', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    final walk = HarborKeyframeModeWalk(
      rootBsize: 9,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 1024,
      maxLeafOut: 1,
      qband: 0,
      name: 'walk',
    );
    addSubModule(walk);
    final recon = HarborIntraReconWalkSeq(
      sbSize: sbSize,
      maxLeaves: 1,
      maxLog2: 3,
      name: 'recon',
    );
    addSubModule(recon);

    final walkStart = Logic(name: 'walk_start');
    final reconStart = Logic(name: 'recon_start');

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // latched leaf outputs (one leaf).
    final ymCap = Logic(name: 'ym_cap', width: 4);
    final ttCap = Logic(name: 'tt_cap', width: 4);
    final coeffCap = Logic(name: 'coeff_cap', width: leafCoeffN * 16);

    // walk log2 for 32x32 = 5 (pixel), recon convention 3.
    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <=
        Const(1, width: recon.input('leaf_count').width);
    recon.input('positions').srcConnection! <=
        Const(0, width: recon.input('positions').width); // MI (0,0)
    recon.input('log2sizes').srcConnection! <= Const(3, width: 2);
    recon.input('y_modes').srcConnection! <= ymCap;
    recon.input('tx_types').srcConnection! <= ttCap;
    recon.input('coeffs').srcConnection! <= coeffCap;

    output('frame') <= recon.output('frame');

    const sIdle = 0,
        sRunMode = 1,
        sLatch = 2,
        sRunRecon = 3,
        sReconWait = 4,
        sDone = 5;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));

    Combinational([
      walkStart < Const(0),
      reconStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        CaseItem(Const(sRunRecon, width: 3), [reconStart < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          ymCap < Const(0, width: 4),
          ttCap < Const(0, width: 4),
          coeffCap < Const(0, width: leafCoeffN * 16),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            CaseItem(Const(sLatch, width: 3), [
              ymCap < walk.output('leaf_ymodes').getRange(0, 4),
              ttCap < walk.output('leaf_txtypes').getRange(0, 4),
              coeffCap <
                  walk.output('leaf_coeffs').getRange(0, leafCoeffN * 16),
              st < Const(sRunRecon, width: 3),
            ]),
            CaseItem(Const(sRunRecon, width: 3), [
              st < Const(sReconWait, width: 3),
            ]),
            CaseItem(Const(sReconWait, width: 3), [
              If(recon.output('done'), then: [st < Const(sDone, width: 3)]),
            ]),
            CaseItem(Const(sDone, width: 3), [
              If(~input('start'), then: [st < Const(sIdle, width: 3)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
