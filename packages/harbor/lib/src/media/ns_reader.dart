import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `ns(n)` reader (non-symmetric unsigned code).
///
/// `ns(n)` encodes a value in `[0, n)` using either `w-1` or `w` bits, where
/// `w = FloorLog2(n) + 1`. It reads `v = f(w-1)`. If `v < m` (with
/// `m = (1 << w) - n`) the value is `v`, otherwise it reads one more bit and the
/// value is `(v << 1) - m + extra_bit`. This keeps short codes for the low
/// values. AV1 uses it in `tile_info()` and similar. This composes two
/// [HarborBitReader]s (the `f(w-1)` read and the conditional `f(1)`), deriving
/// `w` from the alphabet size `n` with a combinational FloorLog2. Combinational.
class HarborNsReader extends BridgeModule {
  HarborNsReader({int maxBytes = 16, String? name})
    : super('HarborNsReader', name: name ?? 'ns_reader') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('bit_offset', PortDirection.input, width: offW);
    createPort('n', PortDirection.input, width: 16); // alphabet size, >= 1
    addOutput('value', width: 32);
    addOutput('next_offset', width: offW);

    final n = input('n');

    // FloorLog2(n) = index of the highest set bit (n >= 1). w = that + 1.
    Logic fl = Const(0, width: 5);
    for (var k = 1; k < 16; k++) {
      fl = mux(n[k], Const(k, width: 5), fl);
    }
    final w = (fl.zeroExtend(6) + Const(1, width: 6)).getRange(
      0,
      6,
    ); // FloorLog2+1
    // m = (1 << w) - n.
    final m =
        ((Const(1, width: 32) << w.zeroExtend(32)).getRange(0, 32) -
                n.zeroExtend(32))
            .getRange(0, 32);

    // First read: f(w-1) = f(fl).
    final r1 = HarborBitReader(maxBytes: maxBytes, name: 'fn_wm1');
    addSubModule(r1);
    r1.input('bytes').srcConnection! <= input('bytes');
    r1.input('bit_offset').srcConnection! <= input('bit_offset');
    r1.input('n').srcConnection! <= fl.zeroExtend(6);
    final v = r1.output('value');

    // Conditional extra bit: f(1) at r1.next_offset.
    final r2 = HarborBitReader(maxBytes: maxBytes, name: 'fn_extra');
    addSubModule(r2);
    r2.input('bytes').srcConnection! <= input('bytes');
    r2.input('bit_offset').srcConnection! <= r1.output('next_offset');
    r2.input('n').srcConnection! <= Const(1, width: 6);
    final extra = r2.output('value').getRange(0, 1);

    final cond = v.lt(m); // v < m -> short code
    final long =
        (((v << 1).getRange(0, 32) - m).getRange(0, 32) + extra.zeroExtend(32))
            .getRange(0, 32);

    output('value') <= mux(cond, v, long);
    output('next_offset') <=
        mux(cond, r1.output('next_offset'), r2.output('next_offset'));
  }
}
