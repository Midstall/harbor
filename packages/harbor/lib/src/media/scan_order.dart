import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 up-right diagonal coefficient scan order (`default_scan`).
///
/// Coefficients are decoded in a scan order. The default is the zigzag diagonal
/// (libaom `default_scan_NxN`). Given a scan position `pos` (0..N*N-1) and
/// `log2size`, this returns the raster row/column of that scan position. The
/// order visits anti-diagonals `d = row + col` from 0 upward. The walk direction
/// alternates per diagonal (even d: row high->low, odd d: row low->high), which
/// reproduces default_scan_4x4 = {0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15}.
/// Combinational. Precomputed per square size (4x4..32x32) and selected by size.
class HarborScanOrder extends BridgeModule {
  HarborScanOrder({String? name})
    : super('HarborScanOrder', name: name ?? 'scan_order') {
    createPort('pos', PortDirection.input, width: 10); // up to 32x32 = 1024
    createPort('log2size', PortDirection.input, width: 3); // 2..5 (square)
    addOutput('row', width: 5);
    addOutput('col', width: 5);

    final pos = input('pos');
    final log2size = input('log2size');

    // Zigzag diagonal scan order for an n x n block (AV1 default_scan).
    List<List<int>> scan(int n) {
      final order = <List<int>>[];
      for (var d = 0; d < 2 * n - 1; d++) {
        final lo = (d - n + 1) < 0 ? 0 : d - n + 1;
        final hi = d < n - 1 ? d : n - 1;
        if (d.isEven) {
          for (var row = hi; row >= lo; row--) {
            order.add([row, d - row]);
          }
        } else {
          for (var row = lo; row <= hi; row++) {
            order.add([row, d - row]);
          }
        }
      }
      return order;
    }

    Logic rowOut = Const(0, width: 5);
    Logic colOut = Const(0, width: 5);
    for (final l in [2, 3, 4, 5]) {
      final n = 1 << l;
      final order = scan(n);
      // pos-indexed row/col for this size.
      Logic rSel = Const(0, width: 5);
      Logic cSel = Const(0, width: 5);
      for (var p = order.length - 1; p >= 0; p--) {
        final isP = pos.eq(Const(p, width: 10));
        rSel = mux(isP, Const(order[p][0], width: 5), rSel);
        cSel = mux(isP, Const(order[p][1], width: 5), cSel);
      }
      final sizeMatch = log2size.eq(Const(l, width: 3));
      rowOut = mux(sizeMatch, rSel, rowOut);
      colOut = mux(sizeMatch, cSel, colOut);
    }
    output('row') <= rowOut;
    output('col') <= colOut;
  }
}
