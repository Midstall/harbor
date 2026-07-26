import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'keyframe_mode_walk.dart';
import 'keyframe_recon_grid.dart';

/// AV1 keyframe intra decode for one 8x8 superblock: coded bytes -> an 8x8 luma
/// picture, joining the mode walk and recon grid on a sequencing FSM.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix) over
/// `bytes` with `dc_q`/`ac_q`. When the walk asserts done, the per-leaf
/// `leaf_ymodes` / `leaf_txtypes` / `leaf_coeffs` (DFS = raster order, already
/// dequantized) are latched and replayed into [HarborKeyframeReconGrid]
/// (gridN 2), whose done drives this module's `done` and the 8x8 luma `frame`.
///
/// The leaf -> recon mapping is the identity: the four 4x4 leaves of a SPLIT 8x8
/// SB come out in DFS order [(0,0),(0,1),(1,0),(1,1)] = recon raster index
/// b = row*2 + col, and the bit packings line up (block b: y_mode [b*4 +: 4],
/// tx_type [b*4 +: 4], 16 signed 16-bit coeffs [b*256 +: 256]).
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (512). Scope: one 8x8 SB splitting into four 4x4 luma leaves, mono.
class HarborKeyframeDecode extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  HarborKeyframeDecode({this.maxBytes = 48, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super('HarborKeyframeDecode', name: name ?? 'keyframe_decode') {
    const gridN = 2;
    const nBlk = gridN * gridN; // 4 leaves
    const f = 4 * gridN; // 8 pixels
    const nPix = f * f; // 64

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

    // sub-modules
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      name: 'walk',
    );
    addSubModule(walk);
    final grid = HarborKeyframeReconGrid(gridN: gridN, name: 'grid');
    addSubModule(grid);

    final walkStart = Logic(name: 'walk_start');
    final gridStart = Logic(name: 'grid_start');

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // captured per-leaf arrays (identity leaf to raster mapping).
    final ymCap = Logic(name: 'ym_cap', width: nBlk * 4);
    final ttCap = Logic(name: 'tt_cap', width: nBlk * 4);
    final coeffCap = Logic(name: 'coeff_cap', width: nBlk * 256);

    grid.input('clk').srcConnection! <= clk;
    grid.input('reset').srcConnection! <= reset;
    grid.input('start').srcConnection! <= gridStart;
    grid.input('y_modes').srcConnection! <= ymCap;
    grid.input('tx_types').srcConnection! <= ttCap;
    grid.input('coeffs').srcConnection! <= coeffCap;

    output('frame') <= grid.output('frame');

    // sequencing FSM
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
      gridStart < Const(0),
      Case(st, [
        // pulse the mode-walk start for one cycle leaving idle.
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // pulse the recon-grid start for one cycle in sRunRecon.
        CaseItem(Const(sRunRecon, width: 3), [gridStart < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          ymCap < Const(0, width: nBlk * 4),
          ttCap < Const(0, width: nBlk * 4),
          coeffCap < Const(0, width: nBlk * 256),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            // walk outputs are stable while it holds done, latch leaves.
            CaseItem(Const(sLatch, width: 3), [
              ymCap < walk.output('leaf_ymodes'),
              ttCap < walk.output('leaf_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
              st < Const(sRunRecon, width: 3),
            ]),
            CaseItem(Const(sRunRecon, width: 3), [
              st < Const(sReconWait, width: 3),
            ]),
            CaseItem(Const(sReconWait, width: 3), [
              If(grid.output('done'), then: [st < Const(sDone, width: 3)]),
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
