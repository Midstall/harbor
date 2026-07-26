import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `su(n)` reader (signed, two's-complement of width `n`).
///
/// `su(n)` reads `n` bits as an unsigned `f(n)` then reinterprets them as a
/// two's-complement signed value: if the top (sign) bit is set, subtract
/// `2^n`. AV1 uses it for deltas (loop-filter ref/mode deltas, CDEF, global
/// motion params, ...). This composes [HarborBitReader] for the raw read and
/// applies the sign correction, sign-extending into a 32-bit `value`.
class HarborSuReader extends BridgeModule {
  HarborSuReader({int maxBytes = 16, String? name})
    : super('HarborSuReader', name: name ?? 'su_reader') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('bit_offset', PortDirection.input, width: offW);
    createPort('n', PortDirection.input, width: 6); // 1..32
    addOutput('value', width: 32); // signed, two's complement
    addOutput('next_offset', width: offW);

    final reader = HarborBitReader(maxBytes: maxBytes, name: 'fn');
    addSubModule(reader);
    reader.input('bytes').srcConnection! <= input('bytes');
    reader.input('bit_offset').srcConnection! <= input('bit_offset');
    reader.input('n').srcConnection! <= input('n');

    final raw = reader.output('value'); // 32-bit, top bits zero
    final n = input('n');

    // signBit = raw bit (n-1). Subtract 2^n when set.
    final signMask =
        (Const(1, width: 32) << (n - Const(1, width: 6)).getRange(0, 6))
            .getRange(0, 32);
    final signBit = (raw & signMask).or();
    final pow2n = (Const(1, width: 33) << n.zeroExtend(33)).getRange(0, 33);
    final signed = (raw.zeroExtend(33) - pow2n).getRange(0, 32); // raw - 2^n

    output('value') <= mux(signBit, signed, raw);
    output('next_offset') <= reader.output('next_offset');
  }
}
