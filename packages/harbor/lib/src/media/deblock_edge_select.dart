import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 deblock edge filter-length selection, mirroring the
/// filter-length derivation in libaom `set_lpf_parameters`.
///
/// Given the current transform size `ts`, the across-edge (previous) transform
/// size `pv_ts`, the `plane` (0=luma, 1=chroma), the `edge_dir`
/// (0=vertical, 1=horizontal) and the edge filter `level`, it picks the kernel
/// width selector `filter_length`:
///   if (level == 0) filter_length = 0             // no filtering
///   else {
///     dim = min(unitLog2[ts], unitLog2[pv_ts])    // Wide for vert, High for horz
///     filter_length = chroma ? (dim==0 ? 4 : 6)
///                            : tx_dim_to_filter_length[dim] // {4,8,14,14,14}
///   }
/// `thresh` is passed straight through (the threshold the caller derived for the
/// chosen level). filter_length 0 means the edge is skipped.
///
/// Ports: inputs `ts` (5b), `pv_ts` (5b), `plane` (1b), `edge_dir` (1b),
/// `level` (6b), `thresh` (8b). Outputs `filter_length` (4b, one of 0/4/6/8/14)
/// and `thresh` (8b pass-through). Combinational.
class HarborDeblockEdgeSelect extends BridgeModule {
  HarborDeblockEdgeSelect({String? name})
    : super('HarborDeblockEdgeSelect', name: name ?? 'deblock_edge_select') {
    createPort('ts', PortDirection.input, width: 5);
    createPort('pv_ts', PortDirection.input, width: 5);
    createPort('plane', PortDirection.input, width: 1);
    createPort('edge_dir', PortDirection.input, width: 1);
    createPort('level', PortDirection.input, width: 6);
    createPort('thresh', PortDirection.input, width: 8);
    addOutput('filter_length', width: 4);
    addOutput('thresh_o', width: 8);

    // TX_SIZE -> width/height in log2 of 4x4 units (TX_SIZES_ALL = 19 entries).
    // Values are 0..4 (3b).
    const wideUnitLog2 = [
      0, 1, 2, 3, 4, 0, 1, 1, 2, 2, 3, 3, 4, 0, 2, 1, 3, 2, 4, //
    ];
    const highUnitLog2 = [
      0, 1, 2, 3, 4, 1, 0, 2, 1, 3, 2, 4, 3, 2, 0, 3, 1, 4, 2, //
    ];

    final ts = input('ts');
    final pvTs = input('pv_ts');
    final isChroma = input('plane')[0];
    final isHorz = input('edge_dir')[0];
    final level = input('level');

    // Combinational table lookup over a 5b index: select the matching entry.
    // Out-of-range indices (19..31) never occur for valid TX_SIZE. Default 0.
    Logic lookup(List<int> table, Logic idx) {
      Logic sel = Const(0, width: 3);
      for (var i = 0; i < table.length; i++) {
        sel = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: 3),
          sel,
        );
      }
      return sel;
    }

    // Pick Wide (vertical edge) or High (horizontal edge) log2 tables.
    final tsLog2 = mux(
      isHorz,
      lookup(highUnitLog2, ts),
      lookup(wideUnitLog2, ts),
    );
    final pvLog2 = mux(
      isHorz,
      lookup(highUnitLog2, pvTs),
      lookup(wideUnitLog2, pvTs),
    );

    // dim = min(tsLog2, pvLog2), in 0..4.
    final dim = mux(tsLog2.lt(pvLog2), tsLog2, pvLog2);

    // Luma: tx_dim_to_filter_length[dim] = {4, 8, 14, 14, 14}. dim is 0..4.
    Logic fl4(int v) => Const(v, width: 4);
    final lumaLen = mux(
      dim.eq(Const(0, width: 3)),
      fl4(4),
      mux(dim.eq(Const(1, width: 3)), fl4(8), fl4(14)),
    );
    // Chroma: dim==0 ? 4 : 6.
    final chromaLen = mux(dim.eq(Const(0, width: 3)), fl4(4), fl4(6));

    final lenWhenActive = mux(isChroma, chromaLen, lumaLen);
    // level == 0 disables the edge.
    final active = level.neq(Const(0, width: 6));
    output('filter_length') <= mux(active, lenWhenActive, fl4(0));
    output('thresh_o') <= input('thresh');
  }
}
