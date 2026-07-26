import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock_filter.dart';
import 'deblock_limits.dart';

/// Harbor deblock edge unit: filter-level interface over one block edge.
///
/// This is the realistic AV1 deblock primitive: an edge carries a `filter_level`
/// (derived from qindex/segment/mode) and the frame `sharpness`, not raw
/// thresholds. It composes [HarborDeblockLimits] (level/sharpness ->
/// blimit/limit/thresh) with [HarborDeblockFilter] (the filter4/filter8 line
/// filter), so a caller just supplies the 8-pixel line, the level, the sharpness
/// and the flat threshold. Combinational. Output is the six filtered inner
/// pixels op2,op1,op0,oq0,oq1,oq2 (LSB-first), same as [HarborDeblockFilter].
class HarborDeblockEdge extends BridgeModule {
  HarborDeblockEdge({String? name})
    : super('HarborDeblockEdge', name: name ?? 'deblock_edge') {
    createPort('line', PortDirection.input, width: 64); // 8 pixels, LSB first
    createPort('filter_level', PortDirection.input, width: 6);
    createPort('sharpness', PortDirection.input, width: 3);
    createPort('flat_thresh', PortDirection.input, width: 8);
    addOutput('filtered', width: 48);

    final limits = HarborDeblockLimits(name: 'lim');
    addSubModule(limits);
    limits.input('filter_level').srcConnection! <= input('filter_level');
    limits.input('sharpness').srcConnection! <= input('sharpness');

    final filt = HarborDeblockFilter(name: 'flt');
    addSubModule(filt);
    filt.input('line').srcConnection! <= input('line');
    filt.input('blimit').srcConnection! <= limits.output('blimit');
    filt.input('limit').srcConnection! <= limits.output('limit');
    filt.input('thresh').srcConnection! <= limits.output('thresh');
    filt.input('flat_thresh').srcConnection! <= input('flat_thresh');

    output('filtered') <= filt.output('filtered');
  }
}
