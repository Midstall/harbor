import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'partition_tree.dart';

/// Harbor AV1 tile-decode driver (`decode_tile` superblock loop).
///
/// Iterates superblocks in raster order across the tile (`mi_rows` x `mi_cols`,
/// stepping `sb_step` mode-info units per superblock) and runs the partition
/// walker ([HarborPartitionTree]) on each, so the emitted leaf-block stream
/// covers the whole tile. The partition-decision (`query_*`/`partition_in`) and
/// leaf-emit (`emit_*`) interfaces pass straight through from the inner walker.
/// The driver only sequences the superblock cursor and restarts the walker for
/// each. `done` asserts when the last superblock finishes.
///
/// SCOPE: a single tile spanning the whole frame, per-tile boundaries and the
/// reconstruct hookup (feeding each leaf to mode/coeff decode) are the next
/// integration steps.
class HarborTileDecodeDriver extends BridgeModule {
  HarborTileDecodeDriver({int depth = 32, String? name})
    : super('HarborTileDecodeDriver', name: name ?? 'tile_driver') {
    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('sb_size', PortDirection.input, width: 5);
    createPort('sb_step', PortDirection.input, width: 16); // mi units per SB
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort('partition_in', PortDirection.input, width: 4);
    createPort('partition_valid', PortDirection.input, width: 1);
    createPort('emit_ack', PortDirection.input, width: 1);
    addOutput('query_valid', width: 1);
    addOutput('query_r', width: 16);
    addOutput('query_c', width: 16);
    addOutput('query_bsize', width: 5);
    addOutput('emit_valid', width: 1);
    addOutput('emit_r', width: 16);
    addOutput('emit_c', width: 16);
    addOutput('emit_bsize', width: 5);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');
    final step = input('sb_step');
    final miRows = input('mi_rows');
    final miCols = input('mi_cols');

    final state = Logic(name: 'd_state', width: 2);
    final sbR = Logic(name: 'sb_r_cur', width: 16);
    final sbC = Logic(name: 'sb_c_cur', width: 16);

    const dIdle = 0, dKick = 1, dRun = 2, dDone = 3;

    // Inner partition walker.
    final pt = HarborPartitionTree(depth: depth, name: 'pt');
    addSubModule(pt);
    pt.input('clk').srcConnection! <= clk;
    pt.input('reset').srcConnection! <= reset;
    pt.input('start').srcConnection! <= state.eq(Const(dKick, width: 2));
    pt.input('sb_r').srcConnection! <= sbR;
    pt.input('sb_c').srcConnection! <= sbC;
    pt.input('sb_size').srcConnection! <= input('sb_size');
    pt.input('mi_rows').srcConnection! <= miRows;
    pt.input('mi_cols').srcConnection! <= miCols;
    pt.input('partition_in').srcConnection! <= input('partition_in');
    pt.input('partition_valid').srcConnection! <= input('partition_valid');
    pt.input('emit_ack').srcConnection! <= input('emit_ack');

    final ptDone = pt.output('done');

    // Next superblock cursor.
    final nextC = (sbC + step).getRange(0, 16);
    final wrap = nextC.gte(miCols);
    final nextR = (sbR + step).getRange(0, 16);
    final lastSb = wrap & nextR.gte(miRows);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(dIdle, width: 2),
          sbR < Const(0, width: 16),
          sbC < Const(0, width: 16),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(dIdle, width: 2), [
              If(
                input('start'),
                then: [
                  sbR < Const(0, width: 16),
                  sbC < Const(0, width: 16),
                  state < Const(dKick, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(dKick, width: 2), [state < Const(dRun, width: 2)]),
            CaseItem(Const(dRun, width: 2), [
              If(
                ptDone,
                then: [
                  If(
                    lastSb,
                    then: [state < Const(dDone, width: 2)],
                    orElse: [
                      sbC < mux(wrap, Const(0, width: 16), nextC),
                      sbR < mux(wrap, nextR, sbR),
                      state < Const(dKick, width: 2),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(dDone, width: 2), [state < Const(dDone, width: 2)]),
          ]),
        ],
      ),
    ]);

    output('query_valid') <= pt.output('query_valid');
    output('query_r') <= pt.output('query_r');
    output('query_c') <= pt.output('query_c');
    output('query_bsize') <= pt.output('query_bsize');
    output('emit_valid') <= pt.output('emit_valid');
    output('emit_r') <= pt.output('emit_r');
    output('emit_c') <= pt.output('emit_c');
    output('emit_bsize') <= pt.output('emit_bsize');
    output('done') <= state.eq(Const(dDone, width: 2));
  }
}
