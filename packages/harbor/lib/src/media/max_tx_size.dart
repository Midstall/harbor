import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `Max_Tx_Size_Rect` lookup: block size -> largest transform size.
///
/// Each coded block has a maximum (rectangular) transform size derived from its
/// dimensions, and the transform-size syntax and the coefficient decode start
/// from it. This is the AV1 `max_txsize_rect_lookup` table. Combinational.
///
/// TX_SIZE enum: 4X4=0,8X8=1,16X16=2,32X32=3,64X64=4,4X8=5,8X4=6,8X16=7,16X8=8,
/// 16X32=9,32X16=10,32X64=11,64X32=12,4X16=13,16X4=14,8X32=15,32X8=16,16X64=17,
/// 64X16=18.
class HarborMaxTxSize extends BridgeModule {
  // BLOCK_SIZE index -> TX_SIZE.
  static const _table = [
    0, // 4x4   -> TX_4X4
    5, // 4x8   -> TX_4X8
    6, // 8x4   -> TX_8X4
    1, // 8x8   -> TX_8X8
    7, // 8x16  -> TX_8X16
    8, // 16x8  -> TX_16X8
    2, // 16x16 -> TX_16X16
    9, // 16x32 -> TX_16X32
    10, // 32x16 -> TX_32X16
    3, // 32x32 -> TX_32X32
    11, // 32x64 -> TX_32X64
    12, // 64x32 -> TX_64X32
    4, // 64x64 -> TX_64X64
    4, // 64x128 -> TX_64X64
    4, // 128x64 -> TX_64X64
    4, // 128x128 -> TX_64X64
    13, // 4x16  -> TX_4X16
    14, // 16x4  -> TX_16X4
    15, // 8x32  -> TX_8X32
    16, // 32x8  -> TX_32X8
    17, // 16x64 -> TX_16X64
    18, // 64x16 -> TX_64X16
  ];

  HarborMaxTxSize({String? name})
    : super('HarborMaxTxSize', name: name ?? 'max_tx_size') {
    createPort('bsize', PortDirection.input, width: 5);
    addOutput('tx_size', width: 5);

    final bsize = input('bsize');
    Logic out = Const(0, width: 5);
    for (var b = _table.length - 1; b >= 0; b--) {
      out = mux(bsize.eq(Const(b, width: 5)), Const(_table[b], width: 5), out);
    }
    output('tx_size') <= out;
  }
}
