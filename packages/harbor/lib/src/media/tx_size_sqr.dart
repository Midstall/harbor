import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `Tx_Size_Sqr` / `Tx_Size_Sqr_Up` lookups.
///
/// Coefficient and transform context derivation reduce a (possibly rectangular)
/// transform size to a square one: `sqr` is the largest square that fits (the
/// smaller dimension), `sqr_up` is the smallest square that contains it (the
/// larger dimension). These are libaom `txsize_sqr_map` / `txsize_sqr_up_map`.
/// Combinational.
class HarborTxSizeSqr extends BridgeModule {
  static const _sqr = [
    0, 1, 2, 3, 4, // square 4..64
    0, 0, // 4x8, 8x4
    1, 1, // 8x16, 16x8
    2, 2, // 16x32, 32x16
    3, 3, // 32x64, 64x32
    0, 0, // 4x16, 16x4
    1, 1, // 8x32, 32x8
    2, 2, // 16x64, 64x16
  ];
  static const _sqrUp = [
    0, 1, 2, 3, 4,
    1, 1, // 4x8, 8x4 -> 8x8
    2, 2, // 8x16, 16x8 -> 16x16
    3, 3, // 16x32, 32x16 -> 32x32
    4, 4, // 32x64, 64x32 -> 64x64
    2, 2, // 4x16, 16x4 -> 16x16
    3, 3, // 8x32, 32x8 -> 32x32
    4, 4, // 16x64, 64x16 -> 64x64
  ];

  HarborTxSizeSqr({String? name})
    : super('HarborTxSizeSqr', name: name ?? 'tx_size_sqr') {
    createPort('tx_size', PortDirection.input, width: 5);
    addOutput('tx_size_sqr', width: 5);
    addOutput('tx_size_sqr_up', width: 5);

    final tx = input('tx_size');
    Logic lut(List<int> table) {
      Logic out = Const(0, width: 5);
      for (var i = table.length - 1; i >= 0; i--) {
        out = mux(tx.eq(Const(i, width: 5)), Const(table[i], width: 5), out);
      }
      return out;
    }

    output('tx_size_sqr') <= lut(_sqr);
    output('tx_size_sqr_up') <= lut(_sqrUp);
  }
}
