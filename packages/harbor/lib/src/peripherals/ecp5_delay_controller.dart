import 'package:rohd/rohd.dart';

/// Drives an ECP5 [Ecp5Delayf] dynamic input-delay line to a programmable tap.
///
/// The DELAYF primitive steps its tap one position on each rising edge of MOVE
/// (in DIRECTION) and reloads its initial tap on LOADN, but it has NO tap
/// readback. This controller tracks the current tap in a register and emits the
/// LOADN / MOVE / DIRECTION sequence needed to reach a target tap, so a CPU/FSBL
/// can train the DDR read-sampling point at runtime (write a target, the
/// controller walks the delay line there). One controller fans its outputs to a
/// whole DQ group (all lanes share the same tap and move together).
///
/// Protocol:
///   - pulse [loadStrobe] -> LOADN reloads the DELAYF to [initialTap]. The
///     tracked tap returns to [initialTap].
///   - write [targetTap] and pulse [setStrobe] -> the controller issues one
///     MOVE per step (DIRECTION toward the target) until [currentTap] equals
///     [targetTap]. [busy] is high while walking.
/// Each MOVE is a clean two-cycle pulse (assert, deassert) so every step is a
/// distinct rising edge. [currentTap] updates in lockstep with the DELAYF tap.
class Ecp5DelayController extends Module {
  final int tapWidth;
  final int initialTap;

  Logic get loadn => output('loadn');
  Logic get move => output('move');
  Logic get direction => output('direction');
  Logic get currentTap => output('current_tap');
  Logic get busy => output('busy');

  Ecp5DelayController(
    Logic clk,
    Logic reset, {
    required Logic targetTap,
    required Logic setStrobe,
    required Logic loadStrobe,
    this.initialTap = 0,
    this.tapWidth = 7,
    super.name = 'ecp5_delay_controller',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    targetTap = addInput('target_tap', targetTap, width: tapWidth);
    setStrobe = addInput('set_strobe', setStrobe);
    loadStrobe = addInput('load_strobe', loadStrobe);

    final loadn = addOutput('loadn');
    final move = addOutput('move');
    final direction = addOutput('direction');
    final current = addOutput('current_tap', width: tapWidth);
    final busy = addOutput('busy');

    // st: 0 idle, 1 load (LOADN low), 2 move (MOVE high, step taken), 3 gap
    // (MOVE low, re-check). A move requires MOVE to fall between steps, so each
    // step is move(2) -> gap(3).
    const sIdle = 0, sLoad = 1, sMove = 2, sGap = 3;
    final st = Logic(name: 'st', width: 2);
    final target = Logic(name: 'target', width: tapWidth);
    final cur = Logic(name: 'cur', width: tapWidth);

    final dirDown = cur.gt(
      target,
    ); // current too long -> decrement toward target
    final step = mux(dirDown, cur - 1, cur + 1);

    Sequential(clk, [
      If(
        reset,
        then: [st < sIdle, cur < initialTap, target < initialTap],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                loadStrobe,
                then: [st < sLoad],
                orElse: [
                  If(
                    setStrobe,
                    then: [
                      target < targetTap,
                      // Only walk if the target differs from where we are.
                      If(~targetTap.eq(cur), then: [st < sMove]),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 2), [cur < initialTap, st < sIdle]),
            CaseItem(Const(sMove, width: 2), [
              // MOVE is high this cycle (rising edge from the prior gap/idle):
              // the DELAYF steps, so advance the tracked tap in lockstep.
              cur < step,
              st < sGap,
            ]),
            CaseItem(Const(sGap, width: 2), [
              If(cur.eq(target), then: [st < sIdle], orElse: [st < sMove]),
            ]),
          ]),
        ],
      ),
    ]);

    loadn <= ~st.eq(sLoad);
    move <= st.eq(sMove);
    direction <= dirDown;
    current <= cur;
    busy <= ~st.eq(sIdle);
  }
}
