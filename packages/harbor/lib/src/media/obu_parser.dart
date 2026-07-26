import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 OBU header parser, the entry point to bitstream parsing.
///
/// Every AV1 Open Bitstream Unit starts with a 1-byte `obu_header`, an optional
/// 1-byte extension header, and (when `obu_has_size_field`) a leb128-coded
/// `obu_size`. This module decodes that prefix from a packed byte window and
/// reports where the payload begins, so a stream walker can step OBU to OBU.
///
/// `bytes` packs the candidate header bytes LSB-first (byte 0 at bit 0). Ten
/// bytes cover the worst case (1 header + 1 extension + 8 leb128). Per the AV1
/// spec, in the header byte the MSB is the forbidden bit, then obu_type[3:0],
/// the extension flag, the has-size flag and a reserved bit. The extension byte
/// carries temporal_id[2:0] and spatial_id[1:0]. `obu_size` is the leb128 value,
/// `header_len` is the byte count to the payload (1 + ext + leb bytes), so
/// payload = bytes[header_len ..]. Combinational.
class HarborObuParser extends BridgeModule {
  HarborObuParser({int maxBytes = 10, String? name})
    : super('HarborObuParser', name: name ?? 'obu_parser') {
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    addOutput('obu_type', width: 4);
    addOutput('extension_flag', width: 1);
    addOutput('has_size', width: 1);
    addOutput('temporal_id', width: 3);
    addOutput('spatial_id', width: 2);
    addOutput('obu_size', width: 32);
    addOutput('header_len', width: 4); // bytes before the payload

    final bytes = input('bytes');
    Logic byte(int i) => bytes.getRange(i * 8, i * 8 + 8);

    final hdr = byte(0);
    final extFlag = hdr[2];
    final hasSize = hdr[1];
    output('obu_type') <= hdr.getRange(3, 7);
    output('extension_flag') <= extFlag;
    output('has_size') <= hasSize;

    // Extension byte (byte 1) is present only when extFlag.
    final extByte = byte(1);
    output('temporal_id') <=
        mux(extFlag, extByte.getRange(5, 8), Const(0, width: 3));
    output('spatial_id') <=
        mux(extFlag, extByte.getRange(3, 5), Const(0, width: 2));

    // leb128 starts at offset 1 + extFlag. Decode up to 8 bytes.
    Logic lebByte(int i) => mux(extFlag, byte(2 + i), byte(1 + i));

    const accW = 40;
    Logic acc = Const(0, width: accW);
    Logic active = Const(1, width: 1); // byte i is consumed while active
    Logic count = Const(0, width: 4); // number of leb bytes
    for (var i = 0; i < 8; i++) {
      final b = lebByte(i);
      final payload = b.getRange(0, 7); // low 7 bits
      final shifted = (payload.zeroExtend(accW) << (7 * i)).getRange(0, accW);
      acc = (acc | mux(active, shifted, Const(0, width: accW))).getRange(
        0,
        accW,
      );
      count = (count + active.zeroExtend(4)).getRange(0, 4);
      // Stay active into the next byte only if this byte had its MSB set.
      active = (active & b[7]).getRange(0, 1);
    }

    // obu_size is meaningful only when hasSize, else 0 (size to end of stream).
    output('obu_size') <=
        mux(hasSize, acc.getRange(0, 32), Const(0, width: 32));
    // header_len = 1 (header) + extFlag + (hasSize ? leb bytes : 0).
    final lebLen = mux(hasSize, count, Const(0, width: 4));
    output('header_len') <=
        ((Const(1, width: 4) + extFlag.zeroExtend(4)).getRange(0, 4) + lebLen)
            .getRange(0, 4);
  }
}
