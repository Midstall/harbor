import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';
import 'partition_tree.dart';

/// Harbor AV1 bitstream-driven partition walk: tree + od_ec.
///
/// Wraps [HarborPartitionTree] and decodes each partition symbol from a shared
/// od_ec window, so the superblock's partition tree is driven by the entropy
/// stream (not external decisions). When the tree presents a block on `query_*`
/// (its sDecode wait state), this decodes one partition symbol and answers with
/// `partition_valid`. The leaf-emit interface passes straight through.
///
/// The partition CDF (one adaptive context here, AV1's per-block-size symbol
/// counts + above/left context are loaded as data / a follow-up) is a runtime
/// default (uniform 10-symbol). `bytes_in` (3 bytes) feeds the coder. The
/// environment advances by `byte_pop`. The whole point is that the partition
/// recursion and the entropy decode share one window: the tile-decode pattern.
class HarborPartitionDecode extends BridgeModule {
  HarborPartitionDecode({int depth = 32, String? name})
    : super('HarborPartitionDecode', name: name ?? 'partition_decode') {
    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('sb_r', PortDirection.input, width: 16);
    createPort('sb_c', PortDirection.input, width: 16);
    createPort('sb_size', PortDirection.input, width: 5);
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort('bytes_in', PortDirection.input, width: 24);
    addOutput('byte_pop', width: 2);
    addOutput('emit_valid', width: 1);
    addOutput('emit_r', width: 16);
    addOutput('emit_c', width: 16);
    addOutput('emit_bsize', width: 5);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

    BigInt packIcdf(List<int> icdf) {
      var v = BigInt.zero;
      for (var s = 0; s < 16; s++) {
        v |= BigInt.from((s < icdf.length ? icdf[s] : 0) & 0xFFFF) << (s * 16);
      }
      return v;
    }

    final partCdf = [
      for (var i = 0; i < 10; i++) 32768 - ((i + 1) * 32768 / 10).round(),
    ];

    final state = Logic(name: 'w_state', width: 3);
    const wIdle = 0,
        wLoad = 1,
        wStart = 2,
        wRun = 3,
        wIssue = 4,
        wCap = 5,
        wDone = 6;

    final od = HarborOdEcDecoder(name: 'od');
    addSubModule(od);

    final tree = HarborPartitionTree(depth: depth, name: 'pt');
    addSubModule(tree);

    final queryValid = tree.output('query_valid');
    final treeDone = tree.output('done');

    od.input('clk').srcConnection! <= clk;
    od.input('reset').srcConnection! <= reset;
    od.input('init').srcConnection! <= state.eq(Const(wLoad, width: 3));
    od.input('load').srcConnection! <= state.eq(Const(wLoad, width: 3));
    od.input('decode').srcConnection! <= state.eq(Const(wIssue, width: 3));
    od.input('ctx').srcConnection! <= Const(0, width: od.input('ctx').width);
    od.input('cdf').srcConnection! <= Const(packIcdf(partCdf), width: 256);
    od.input('num_syms').srcConnection! <= Const(10, width: 5);
    od.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= od.output('byte_pop');

    tree.input('clk').srcConnection! <= clk;
    tree.input('reset').srcConnection! <= reset;
    tree.input('start').srcConnection! <= state.eq(Const(wStart, width: 3));
    tree.input('sb_r').srcConnection! <= input('sb_r');
    tree.input('sb_c').srcConnection! <= input('sb_c');
    tree.input('sb_size').srcConnection! <= input('sb_size');
    tree.input('mi_rows').srcConnection! <= input('mi_rows');
    tree.input('mi_cols').srcConnection! <= input('mi_cols');
    tree.input('partition_in').srcConnection! <=
        od.output('symbol').getRange(0, 4);
    tree.input('partition_valid').srcConnection! <=
        state.eq(Const(wCap, width: 3));
    tree.input('emit_ack').srcConnection! <=
        Const(1); // partition-only: no block decode stall

    Sequential(clk, [
      If(
        reset,
        then: [state < Const(wIdle, width: 3)],
        orElse: [
          Case(state, [
            CaseItem(Const(wIdle, width: 3), [
              If(input('start'), then: [state < Const(wLoad, width: 3)]),
            ]),
            CaseItem(Const(wLoad, width: 3), [state < Const(wStart, width: 3)]),
            CaseItem(Const(wStart, width: 3), [state < Const(wRun, width: 3)]),
            CaseItem(Const(wRun, width: 3), [
              If(
                treeDone,
                then: [state < Const(wDone, width: 3)],
                orElse: [
                  If(queryValid, then: [state < Const(wIssue, width: 3)]),
                ],
              ),
            ]),
            CaseItem(Const(wIssue, width: 3), [state < Const(wCap, width: 3)]),
            CaseItem(Const(wCap, width: 3), [state < Const(wRun, width: 3)]),
            CaseItem(Const(wDone, width: 3), [state < Const(wDone, width: 3)]),
          ]),
        ],
      ),
    ]);

    output('emit_valid') <= tree.output('emit_valid');
    output('emit_r') <= tree.output('emit_r');
    output('emit_c') <= tree.output('emit_c');
    output('emit_bsize') <= tree.output('emit_bsize');
    output('done') <= state.eq(Const(wDone, width: 3));
  }
}
