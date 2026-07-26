import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 transform-size geometry: `Tx_Width`/`Tx_Height` (+ log2s).
///
/// Maps a TX_SIZE (0..18) to the transform block's pixel width and height and
/// their log2s, the dimensions the scan tables, coefficient contexts and the
/// inverse transform all key off. Combinational.
class HarborTxSizeGeom extends BridgeModule {
  static const _w = [
    4,
    8,
    16,
    32,
    64,
    4,
    8,
    8,
    16,
    16,
    32,
    32,
    64,
    4,
    16,
    8,
    32,
    16,
    64,
  ];
  static const _h = [
    4,
    8,
    16,
    32,
    64,
    8,
    4,
    16,
    8,
    32,
    16,
    64,
    32,
    16,
    4,
    32,
    8,
    64,
    16,
  ];

  HarborTxSizeGeom({String? name})
    : super('HarborTxSizeGeom', name: name ?? 'tx_size_geom') {
    createPort('tx_size', PortDirection.input, width: 5);
    addOutput('tx_width', width: 8);
    addOutput('tx_height', width: 8);
    addOutput('tx_width_log2', width: 3);
    addOutput('tx_height_log2', width: 3);

    final tx = input('tx_size');
    int log2(int v) => v.bitLength - 1;

    Logic lookup(List<int> table, int width) {
      Logic out = Const(0, width: width);
      for (var i = table.length - 1; i >= 0; i--) {
        out = mux(
          tx.eq(Const(i, width: 5)),
          Const(table[i], width: width),
          out,
        );
      }
      return out;
    }

    output('tx_width') <= lookup(_w, 8);
    output('tx_height') <= lookup(_h, 8);
    output('tx_width_log2') <= lookup([for (final v in _w) log2(v)], 3);
    output('tx_height_log2') <= lookup([for (final v in _h) log2(v)], 3);
  }
}
