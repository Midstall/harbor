import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `read_golomb` (coefficient level exp-Golomb tail).
///
/// AV1 codes coefficient levels above the base+range cap with an exp-Golomb
/// tail: count leading zero bits (the run), read the terminating 1, then read
/// that many value bits into `x` (starting at 1), the value is `x - 1`. This FSM
/// drives that over a one-bit-per-cycle interface: it asserts `bit_req` while
/// consuming, the environment presents `bit_in` (these bits come from the
/// arithmetic coder's literal/bypass path in a full decoder). `value` and `done`
/// hold when the tail is complete.
///
/// The run length is capped at 19 (AV1 breaks at 20) to bound the FSM.
class HarborGolombReader extends BridgeModule {
  HarborGolombReader({String? name})
    : super('HarborGolombReader', name: name ?? 'golomb') {
    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('bit_in', PortDirection.input, width: 1);
    addOutput('bit_req', width: 1);
    addOutput('value', width: 24);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');
    final bitIn = input('bit_in');

    final state = Logic(name: 'state', width: 2);
    final length = Logic(name: 'length', width: 5);
    final valRem = Logic(name: 'val_rem', width: 5);
    final x = Logic(name: 'x', width: 24);

    const sIdle = 0, sCount = 1, sValue = 2, sDone = 3;

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 2),
          length < Const(0, width: 5),
          valRem < Const(0, width: 5),
          x < Const(1, width: 24),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                input('start'),
                then: [
                  length < Const(0, width: 5),
                  x < Const(1, width: 24),
                  state < Const(sCount, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(sCount, width: 2), [
              // Consuming bit_in this cycle (bit_req asserted).
              If(
                bitIn | length.gte(Const(19, width: 5)),
                then: [
                  // Terminating 1 (or cap): value bits = run length.
                  If(
                    length.eq(Const(0, width: 5)) &
                        ~length.gte(Const(19, width: 5)),
                    then: [state < Const(sDone, width: 2)],
                    orElse: [
                      valRem < length,
                      x < Const(1, width: 24),
                      state < Const(sValue, width: 2),
                    ],
                  ),
                ],
                orElse: [length < (length + Const(1, width: 5)).getRange(0, 5)],
              ),
            ]),
            CaseItem(Const(sValue, width: 2), [
              x <
                  ((x << 1).getRange(0, 24) | bitIn.zeroExtend(24)).getRange(
                    0,
                    24,
                  ),
              valRem < (valRem - Const(1, width: 5)).getRange(0, 5),
              If(
                valRem.eq(Const(1, width: 5)),
                then: [state < Const(sDone, width: 2)],
              ),
            ]),
            CaseItem(Const(sDone, width: 2), [state < Const(sDone, width: 2)]),
          ]),
        ],
      ),
    ]);

    output('bit_req') <=
        state.eq(Const(sCount, width: 2)) | state.eq(Const(sValue, width: 2));
    output('value') <= (x - Const(1, width: 24)).getRange(0, 24);
    output('done') <= state.eq(Const(sDone, width: 2));
  }
}
