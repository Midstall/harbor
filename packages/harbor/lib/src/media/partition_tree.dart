import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'partition_subsize.dart';

/// Harbor AV1 recursive partition-tree walker (`decode_partition`).
///
/// Hardware can't recurse, so this FSM walks a superblock's partition tree with
/// an explicit stack, emitting the leaf blocks in decode (raster-within-split)
/// order. Each popped block that needs a partition is presented on the `query_*`
/// ports. The environment supplies the decoded `partition_in` (NONE/HORZ/VERT/
/// SPLIT) one cycle later. NONE emits the block, HORZ/VERT emit up to two
/// sub-blocks, SPLIT pushes the four quadrants (in reverse order so they pop in
/// raster order). Blocks at the minimum size (BLOCK_4X4) are emitted as NONE
/// without a query. Off-frame children are dropped.
///
/// Each emitted leaf appears on `emit_*` with `emit_valid` for one cycle.
/// `done` asserts when the stack drains. SCOPE: the four core partition types
/// (PARTITION_TYPES). The extended HORZ_A/B, VERT_A/B, HORZ_4, VERT_4 are a
/// follow-up.
class HarborPartitionTree extends BridgeModule {
  static const _halfOf = {3: 1, 6: 2, 9: 4, 12: 8, 15: 16}; // mi units

  HarborPartitionTree({int depth = 32, String? name})
    : super('HarborPartitionTree', name: name ?? 'partition_tree') {
    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('sb_r', PortDirection.input, width: 16);
    createPort('sb_c', PortDirection.input, width: 16);
    createPort('sb_size', PortDirection.input, width: 5);
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort(
      'partition_in',
      PortDirection.input,
      width: 4,
    ); // 0..9 (all types)
    createPort(
      'partition_valid',
      PortDirection.input,
      width: 1,
    ); // partition_in ready
    createPort(
      'emit_ack',
      PortDirection.input,
      width: 1,
    ); // leaf consumed (block decoded)
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
    final miRows = input('mi_rows');
    final miCols = input('mi_cols');

    final spW = (depth + 1).bitLength;
    final sp = Logic(name: 'sp', width: spW);
    final stackR = [
      for (var i = 0; i < depth; i++) Logic(name: 'sr$i', width: 16),
    ];
    final stackC = [
      for (var i = 0; i < depth; i++) Logic(name: 'sc$i', width: 16),
    ];
    final stackB = [
      for (var i = 0; i < depth; i++) Logic(name: 'sb$i', width: 5),
    ];

    final state = Logic(name: 'state', width: 3);
    final curR = Logic(name: 'cur_r', width: 16);
    final curC = Logic(name: 'cur_c', width: 16);
    final curB = Logic(name: 'cur_b', width: 5);
    final partReg = Logic(name: 'part_r', width: 4);
    final childIdx = Logic(name: 'child_i', width: 3);

    const sIdle = 0,
        sProcess = 1,
        sDecode = 2,
        sEmit = 3,
        sDone = 4,
        sLeafWait = 5;

    // half (mi units) of the current block size.
    Logic halfOf(Logic bsize) {
      Logic h = Const(0, width: 16);
      _halfOf.forEach((bs, hv) {
        h = mux(bsize.eq(Const(bs, width: 5)), Const(hv, width: 16), h);
      });
      return h;
    }

    final half = halfOf(curB);
    final quarter = (half >>> 1).getRange(0, 16);
    final isSplit = partReg.eq(Const(3, width: 4));

    // Two candidate child sizes: the partition's own subsize and the SPLIT
    // (quadrant) subsize. Extended types mix them.
    final subMainU = HarborPartitionSubsize(name: 'sub_main');
    addSubModule(subMainU);
    subMainU.input('partition').srcConnection! <= partReg;
    subMainU.input('bsize').srcConnection! <= curB;
    final subMain = subMainU.output('subsize');
    final subSplitU = HarborPartitionSubsize(name: 'sub_split');
    addSubModule(subSplitU);
    subSplitU.input('partition').srcConnection! <= Const(3, width: 4);
    subSplitU.input('bsize').srcConnection! <= curB;
    final subSplit = subSplitU.output('subsize');

    // childData[partition][child] = [offRh, offRq, offCh, offCq, useSplitSize].
    // Offset = h*half + q*quarter. SPLIT children are ordered BR,BL,TR,TL so the
    // last pushed (TL) pops first (raster order).
    const childData = {
      0: [
        [0, 0, 0, 0, 0],
      ], // NONE
      1: [
        [0, 0, 0, 0, 0],
        [1, 0, 0, 0, 0],
      ], // HORZ
      2: [
        [0, 0, 0, 0, 0],
        [0, 0, 1, 0, 0],
      ], // VERT
      3: [
        [1, 0, 1, 0, 1],
        [1, 0, 0, 0, 1],
        [0, 0, 1, 0, 1],
        [0, 0, 0, 0, 1],
      ], // SPLIT
      4: [
        [0, 0, 0, 0, 1],
        [0, 0, 1, 0, 1],
        [1, 0, 0, 0, 0],
      ], // HORZ_A
      5: [
        [0, 0, 0, 0, 0],
        [1, 0, 0, 0, 1],
        [1, 0, 1, 0, 1],
      ], // HORZ_B
      6: [
        [0, 0, 0, 0, 1],
        [1, 0, 0, 0, 1],
        [0, 0, 1, 0, 0],
      ], // VERT_A
      7: [
        [0, 0, 0, 0, 0],
        [0, 0, 1, 0, 1],
        [1, 0, 1, 0, 1],
      ], // VERT_B
      8: [
        [0, 0, 0, 0, 0],
        [0, 1, 0, 0, 0],
        [0, 2, 0, 0, 0],
        [0, 3, 0, 0, 0],
      ], // HORZ_4
      9: [
        [0, 0, 0, 0, 0],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 2, 0],
        [0, 0, 0, 3, 0],
      ], // VERT_4
    };
    const counts = [1, 2, 2, 4, 3, 3, 3, 3, 4, 4];

    // Field f (0..4) of child i, muxed over the partition.
    Logic fieldMux(int i, int f) {
      Logic out = Const(0, width: 3);
      childData.forEach((part, children) {
        if (i < children.length) {
          out = mux(
            partReg.eq(Const(part, width: 4)),
            Const(children[i][f], width: 3),
            out,
          );
        }
      });
      return out;
    }

    Logic childOffR(int i) =>
        ((fieldMux(i, 0).zeroExtend(16) * half).getRange(0, 16) +
                (fieldMux(i, 1).zeroExtend(16) * quarter).getRange(0, 16))
            .getRange(0, 16);
    Logic childOffC(int i) =>
        ((fieldMux(i, 2).zeroExtend(16) * half).getRange(0, 16) +
                (fieldMux(i, 3).zeroExtend(16) * quarter).getRange(0, 16))
            .getRange(0, 16);
    Logic childUseSplit(int i) => fieldMux(i, 4).getRange(0, 1);

    Logic childCount = Const(1, width: 3);
    for (var part = 0; part < 10; part++) {
      childCount = mux(
        partReg.eq(Const(part, width: 4)),
        Const(counts[part], width: 3),
        childCount,
      );
    }

    // Select the current child (by childIdx) and its absolute position/size.
    Logic sel4(Logic Function(int) f) => mux(
      childIdx.eq(Const(0, width: 3)),
      f(0),
      mux(
        childIdx.eq(Const(1, width: 3)),
        f(1),
        mux(childIdx.eq(Const(2, width: 3)), f(2), f(3)),
      ),
    );
    final thisR = (curR + sel4(childOffR)).getRange(0, 16);
    final thisC = (curC + sel4(childOffC)).getRange(0, 16);
    final thisSize = mux(sel4(childUseSplit), subSplit, subMain);
    final inFrame = thisR.lt(miRows) & thisC.lt(miCols);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          sp < Const(0, width: spW),
          childIdx < Const(0, width: 3),
          for (var i = 0; i < depth; i++) ...[
            stackR[i] < Const(0, width: 16),
            stackC[i] < Const(0, width: 16),
            stackB[i] < Const(0, width: 5),
          ],
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  stackR[0] < input('sb_r'),
                  stackC[0] < input('sb_c'),
                  stackB[0] < input('sb_size'),
                  sp < Const(1, width: spW),
                  state < Const(sProcess, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sProcess, width: 3), [
              If(
                sp.eq(Const(0, width: spW)),
                then: [state < Const(sDone, width: 3)],
                orElse: [
                  // Pop top of stack.
                  curR < stackR[0],
                  curC < stackC[0],
                  curB < stackB[0],
                  // Shift stack down (pop index 0, entries were stored 0=top).
                  for (var i = 0; i < depth - 1; i++) ...[
                    stackR[i] < stackR[i + 1],
                    stackC[i] < stackC[i + 1],
                    stackB[i] < stackB[i + 1],
                  ],
                  sp < (sp - Const(1, width: spW)).getRange(0, spW),
                  // Off-frame blocks (including the root SB) are dropped with NO
                  // entropy decode, matching the spec's is_inside early return, so
                  // the shared od_ec window never desyncs (rtl-review finding 1).
                  If(
                    ~(stackR[0].lt(miRows) & stackC[0].lt(miCols)),
                    then: [state < Const(sProcess, width: 3)],
                    orElse: [
                      // 4x4 (BLOCK_4X4 = 0) is a forced-NONE leaf: emit it through the
                      // same ack stall (so a block decode can run) via sLeafWait.
                      If(
                        stackB[0].eq(Const(0, width: 5)),
                        then: [state < Const(sLeafWait, width: 3)],
                        orElse: [state < Const(sDecode, width: 3)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sDecode, width: 3), [
              // Present the block on query_* and wait for the partition decision
              // (partition_valid): lets a multi-cycle od_ec decode drive it.
              If(
                input('partition_valid'),
                then: [
                  partReg < input('partition_in'),
                  childIdx < Const(0, width: 3),
                  state < Const(sEmit, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sEmit, width: 3), [
              If(
                childIdx.lt(childCount),
                then: [
                  // Split children push, leaf children emit. A leaf emit holds
                  // emit_valid and waits for emit_ack (so a block decode can run).
                  If(
                    inFrame & isSplit,
                    then: [
                      for (var i = depth - 1; i > 0; i--) ...[
                        stackR[i] < stackR[i - 1],
                        stackC[i] < stackC[i - 1],
                        stackB[i] < stackB[i - 1],
                      ],
                      stackR[0] < thisR,
                      stackC[0] < thisC,
                      stackB[0] < thisSize,
                      sp < (sp + Const(1, width: spW)).getRange(0, spW),
                    ],
                  ),
                  // (leaf emit is driven combinationally on emit_*)
                  // Advance unless waiting for the ack on a leaf emit.
                  If(
                    ~(inFrame & ~isSplit) | input('emit_ack'),
                    then: [
                      childIdx < (childIdx + Const(1, width: 3)).getRange(0, 3),
                    ],
                  ),
                ],
                orElse: [state < Const(sProcess, width: 3)],
              ),
            ]),
            CaseItem(Const(sLeafWait, width: 3), [
              // 4x4 leaf: emit (driven combinationally) and wait for the ack.
              If(input('emit_ack'), then: [state < Const(sProcess, width: 3)]),
            ]),
            CaseItem(Const(sDone, width: 3), [
              // Allow a fresh start (e.g. the next superblock) to re-run the walk.
              If(
                input('start'),
                then: [
                  stackR[0] < input('sb_r'),
                  stackC[0] < input('sb_c'),
                  stackB[0] < input('sb_size'),
                  sp < Const(1, width: spW),
                  state < Const(sProcess, width: 3),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // Query presents the popped block (held in cur) during sDecode while it
    // waits for the partition decision. The env decodes the partition symbol.
    output('query_valid') <= state.eq(Const(sDecode, width: 3));
    output('query_r') <= curR;
    output('query_c') <= curC;
    output('query_bsize') <= curB;
    // Emit is combinational so the consumer always sees the CURRENT child (no
    // registered lag across an ack). A leaf emit is an sEmit non-split in-frame
    // child, or the sLeafWait 4x4 (the popped block in cur).
    final leafEmit =
        state.eq(Const(sEmit, width: 3)) &
        childIdx.lt(childCount) &
        inFrame &
        ~isSplit;
    final isLeafWait = state.eq(Const(sLeafWait, width: 3));
    output('emit_valid') <= leafEmit | isLeafWait;
    output('emit_r') <= mux(isLeafWait, curR, thisR);
    output('emit_c') <= mux(isLeafWait, curC, thisC);
    output('emit_bsize') <= mux(isLeafWait, curB, thisSize);
    output('done') <= state.eq(Const(sDone, width: 3));
  }
}
