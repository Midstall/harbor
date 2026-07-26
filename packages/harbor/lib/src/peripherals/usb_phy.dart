import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../clock/cdc.dart';

/// Full-speed USB line receiver.
///
/// Runs in the USB clock domain. Synchronizes the raw async D+/D- pads
/// through a 2-flop synchronizer, decodes the USB line state, and times
/// a bus reset (SE0 held for at least [resetTicks] clock cycles).
///
/// Line-state encoding (line_state = {dp_sync, dm_sync}, bit1=dp bit0=dm):
///   J (idle) = 0b10, K = 0b01, SE0 = 0b00, SE1 = 0b11
///
/// Bus reset detection: SE0 held for >= [resetTicks] ticks at 48 MHz.
/// Default of 120 ticks corresponds to ~2.5 us at 48 MHz.
class HarborUsbLineRx extends BridgeModule {
  /// Number of SE0 ticks required to declare a bus reset (48 MHz oversample).
  /// Must be in the range 1..0xFFFF.
  final int resetTicks;

  HarborUsbLineRx({this.resetTicks = 120, String? name})
    : super('HarborUsbLineRx', name: name ?? 'usb_linerx') {
    assert(resetTicks > 0 && resetTicks <= 0xFFFF, 'resetTicks out of range');
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    addOutput('line_state', width: 2);
    addOutput('is_j');
    addOutput('is_k');
    addOutput('is_se0');
    addOutput('bus_reset');

    final clk = input('clk');
    final reset = input('reset');

    // Two-flop synchronizers for each pad.
    // BridgeModule createPort inputs are pre-connected to a mergeable dummy
    // signal, wire external drivers via srcConnection on that dummy.
    final dpCdc = HarborCdcSync(name: 'dp_sync');
    addSubModule(dpCdc);
    dpCdc.input('async_in').srcConnection! <= input('dp');
    dpCdc.input('dst_clk').srcConnection! <= clk;
    dpCdc.input('dst_reset').srcConnection! <= reset;
    final dpSync = dpCdc.syncOut;

    final dmCdc = HarborCdcSync(name: 'dm_sync');
    addSubModule(dmCdc);
    dmCdc.input('async_in').srcConnection! <= input('dm');
    dmCdc.input('dst_clk').srcConnection! <= clk;
    dmCdc.input('dst_reset').srcConnection! <= reset;
    final dmSync = dmCdc.syncOut;

    // Decode line state: bit1 = dp, bit0 = dm.
    final ls = [dpSync, dmSync].swizzle();
    output('line_state') <= ls;

    // Local signals for combinational decodes (used both for outputs and
    // the counter, to avoid referencing an output net inside Sequential).
    final isJ = ls.eq(Const(0x2, width: 2));
    final isK = ls.eq(Const(0x1, width: 2));
    final isSe0 = ls.eq(Const(0x0, width: 2));

    output('is_j') <= isJ;
    output('is_k') <= isK;
    output('is_se0') <= isSe0;

    // SE0 hold counter: increments every tick SE0 is active, clears otherwise.
    // Counter width is derived from resetTicks so the two cannot drift apart.
    final cntWidth = max(1, (resetTicks + 1).bitLength);
    final cnt = Logic(name: 'se0_cnt', width: cntWidth);
    final atMax = cnt.gte(Const(resetTicks, width: cntWidth));

    Sequential(clk, [
      If(
        reset,
        then: [cnt < Const(0, width: cntWidth)],
        orElse: [
          If(
            isSe0,
            then: [
              If(~atMax, then: [cnt < cnt + 1]),
            ],
            orElse: [cnt < Const(0, width: cntWidth)],
          ),
        ],
      ),
    ]);

    // bus_reset is a registered level: high while SE0 has been held past the
    // threshold. Downstream consumers should treat it as a level, not an edge.
    output('bus_reset') <= atMax;
  }
}

/// 4x-oversample bit-clock recovery for full-speed USB (48 MHz / 12 Mbps).
///
/// Runs in the 48 MHz clock domain. Accepts an already-synchronized
/// [line_state] (2-bit: bit1=D+, bit0=D-) and recovers a per-bit strobe
/// using an edge-aligned DLL:
///
///   - A 2-bit phase counter free-runs 0->1->2->3->0...
///   - On ANY line-state transition the counter is re-centered to 3.
///     With the combinational strobe on the registered phase, the strobe
///     then lands at oversample 2 (bit center) two cycles after the boundary:
///       boundary cycle N  -> phase becomes 3
///       N+1               -> phase 3->0, strobe=0
///       N+2               -> phase 0->1, strobe=1  (bit center)
///   - [strobe] pulses high for one cycle when phase==1 (combinational on the
///     registered phase, no extra cycle of latency). [symbol] holds the
///     registered line_state captured at that strobe cycle.
///
/// Line-state encoding (same as [HarborUsbLineRx]):
///   J (idle) = 0b10, K = 0b01, SE0 = 0b00, SE1 = 0b11
class HarborUsbBitRecover extends BridgeModule {
  /// When true, an extra `idle` input port is created. While `idle` is high the
  /// bit-recovery state (phase counter, last-line-state edge register, captured
  /// symbol) is HELD at its idle reset seed (phase=0, lastLs=J, symReg=J) so the
  /// DLL starts FRESH on the first transition after `idle` deasserts. This is the
  /// squelch-recovery hook: a bidirectional PHY drives `idle` from its transmit
  /// squelch so the receiver re-locks cleanly on the next packet's SYNC after the
  /// device's own TX, instead of carrying a stale DLL phase across the
  /// turnaround. DEFAULT false leaves the module byte-for-byte identical (no
  /// port, behavior unchanged) for every existing instantiation.
  final bool idleResettable;

  HarborUsbBitRecover({this.idleResettable = false, String? name})
    : super('HarborUsbBitRecover', name: name ?? 'usb_bitrec') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('line_state', PortDirection.input, width: 2);
    if (idleResettable) {
      createPort('idle', PortDirection.input);
    }
    addOutput('symbol', width: 2);
    addOutput('strobe');

    final clk = input('clk');
    final reset = input('reset');
    final ls = input('line_state');
    final idle = idleResettable ? input('idle') : Const(0);

    // Register holding the previous line_state for edge detection.
    final lastLs = Logic(name: 'last_ls', width: 2);
    // 2-bit phase counter (0..3).
    final phase = Logic(name: 'phase', width: 2);
    // Registered symbol: latched line_state at each strobe (bit-center sample).
    final symReg = Logic(name: 'sym_reg', width: 2);

    // Edge: combinational, detects any change in line_state this cycle.
    final edge = ~ls.eq(lastLs);

    // Strobe: combinational on the registered phase (no extra cycle of
    // latency). Fires when phase==1, which is bit center after re-centering
    // to 3 on a boundary transition.
    final strobeLocal = phase.eq(Const(1, width: 2));

    Sequential(clk, [
      If(
        reset | idle,
        then: [
          // On reset OR while squelched (idle): phase=0, lastLs seeded to J (0b10)
          // to avoid a spurious edge on the first active cycle when the line idles
          // at J. Holding this seed for the whole squelch means the DLL re-locks
          // FRESH on the first transition after squelch deasserts, exactly as it
          // would after a hardware reset.
          phase < Const(0, width: 2),
          lastLs < Const(0x2, width: 2),
          symReg < Const(0x2, width: 2),
        ],
        orElse: [
          lastLs < ls,
          If(
            edge,
            then: [
              // Re-center on transition: phase -> 3 so that the combinational
              // strobe (phase==1) lands at oversample 2 (bit center), two cycles
              // after the boundary. The steady free-run cadence (strobe once per
              // 4 cycles) is unchanged because 3->0->1 takes two steps, matching
              // the two cycles skipped versus an ordinary 1->2->3->0->1 wrap.
              phase < Const(3, width: 2),
            ],
            orElse: [phase < phase + 1],
          ),
          // Latch line_state into symReg on the bit-center cycle. strobe is
          // combinational on the registered phase and fires AFTER the posedge
          // that advances phase to 1. Inside Sequential the pre-posedge phase
          // is 0 (no-edge path) when the post-posedge strobe will fire, so
          // capture ls here: pre-posedge phase==0 with no edge means this
          // posedge will advance phase 0->1 and strobe goes high immediately.
          If(phase.eq(Const(0, width: 2)) & ~edge, then: [symReg < ls]),
        ],
      ),
    ]);

    output('symbol') <= symReg;
    output('strobe') <= strobeLocal;
  }
}

/// NRZI decoder and bit de-stuffer for full-speed USB.
///
/// Runs in the USB 48 MHz domain. Consumes strobed line symbols from
/// [HarborUsbBitRecover] and emits clean decoded data bits.
///
/// NRZI rule (USB spec): a data 1 is encoded as NO transition on the line,
/// a data 0 is encoded as a TRANSITION. So:
///   decoded bit = 1  when symbol == previous strobed symbol (same)
///   decoded bit = 0  when symbol != previous strobed symbol (changed)
///
/// Bit de-stuffing: after six consecutive decoded 1s the transmitter inserts
/// a stuffed 0. The receiver must detect and DROP that extra bit (valid stays
/// low for the dropped bit). A 7th consecutive 1 where a stuffed 0 was
/// expected is a protocol error and asserts [stuff_err] for one cycle.
///
/// [lastSym] is registered and seeded to J (0b10) on reset, matching the
/// USB idle state. On the first strobe after reset, decoded compares the
/// incoming symbol against the J seed.
///
/// OUTPUT CONTRACT (REGISTERED): [data], [valid], and [stuff_err] are all
/// registered outputs. They assert ONE clock after the strobe that produced
/// them. [valid] is a single-cycle pulse that self-clears, it does NOT stay
/// high across idle cycles. [data] holds the last decoded bit (gated: only
/// updates when a real non-stuffed bit is emitted). Task 4 must sample [data]
/// on the cycle [valid] is high, one clock after each valid strobe.
class HarborUsbNrziDestuff extends BridgeModule {
  /// When true, an extra `idle` input port is created. While `idle` is high the
  /// NRZI/de-stuff state (last-symbol register seeded to J, the consecutive-1s
  /// run counter, and the registered data/valid/stuff_err outputs) is HELD at its
  /// idle reset seed, so the first symbol after `idle` deasserts compares against
  /// a clean J seed (matching a real device idle line) and emits no stale valid.
  /// This is the squelch-recovery hook (see [HarborUsbBitRecover.idleResettable]).
  /// DEFAULT false leaves the module byte-for-byte identical.
  final bool idleResettable;

  HarborUsbNrziDestuff({this.idleResettable = false, String? name})
    : super('HarborUsbNrziDestuff', name: name ?? 'usb_destuff') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('symbol', PortDirection.input, width: 2);
    createPort('strobe', PortDirection.input);
    if (idleResettable) {
      createPort('idle', PortDirection.input);
      // Held high by the framer while it is NOT inside a packet (idle line and
      // SYNC search). Bit de-stuffing applies only WITHIN a packet body, so
      // while [no_stuff] is high the run counter is pinned to 0 and no bit is
      // ever dropped as a stuffed bit. Without this, a long idle-J line (a
      // continuous NRZI 1-run) drives [ones] to 6 and the very next line bit is
      // sacrificed as a phantom stuff bit. When that bit is the first 0 of an
      // arriving SYNC, one SYNC bit is lost, the SYNC window lands on 0x81
      // instead of 0x80 and the packet is never framed (the host's ACK after a
      // device IN-data turnaround is then missed and the control transfer wedges
      // waiting for it). The SYNC field and any valid PID never contain a
      // six-1 run, so pinning the counter across them is exact.
      createPort('no_stuff', PortDirection.input);
    }
    addOutput('data');
    addOutput('valid');
    addOutput('stuff_err');

    final clk = input('clk');
    final reset = input('reset');
    final strobe = input('strobe');
    final sym = input('symbol');
    final idle = idleResettable ? input('idle') : Const(0);
    final noStuff = idleResettable ? input('no_stuff') : Const(0);

    // Registered last-symbol seen at a strobe, seeded to J (0x2) on reset.
    final lastSym = Logic(name: 'last_sym', width: 2);
    // Consecutive decoded-1 counter (0..6), 3 bits wide.
    final ones = Logic(name: 'ones', width: 3);

    // NRZI decode: same symbol as last = data 1 (no transition), different = 0.
    // This is combinational on the PRE-posedge lastSym register. Registering
    // the outputs is a deliberate design choice giving clean synchronous pulses
    // one cycle after each strobe. The combinational form would also be correct
    // in hardware, registering is preferred here for clean downstream sampling.
    final decoded = sym.eq(lastSym);
    final isStuff = ones.eq(Const(6, width: 3));

    // Registered outputs: captured at the strobe posedge so they are stable
    // and readable AFTER the posedge (where lastSym has already updated).
    final dataReg = Logic(name: 'data_reg');
    final validReg = Logic(name: 'valid_reg');
    final stuffErrReg = Logic(name: 'stuff_err_reg');

    Sequential(clk, [
      If(
        reset | idle,
        then: [
          // On reset OR while squelched (idle): seed lastSym to J so the first
          // symbol after squelch deasserts compares correctly (a real device idle
          // line is J), and clear the run counter + all pulse outputs so no stale
          // valid leaks out of the turnaround.
          lastSym < Const(0x2, width: 2),
          ones < Const(0, width: 3),
          dataReg < Const(0),
          validReg < Const(0),
          stuffErrReg < Const(0),
        ],
        orElse: [
          // While the framer is not yet in a packet (no_stuff): pass every
          // strobed bit and pin the run counter to 0 so an idle-J 1-run cannot
          // manufacture a phantom stuff bit that eats the SYNC's leading 0.
          // Otherwise: normal de-stuff (drop the bit after six 1s).
          validReg < strobe & (noStuff | ~isStuff),
          stuffErrReg < strobe & ~noStuff & isStuff & decoded,
          If(
            strobe,
            then: [
              lastSym < sym,
              If(
                ~noStuff & isStuff,
                then: [
                  // Drop the stuffed bit: reset the run counter.
                  ones < Const(0, width: 3),
                ],
                orElse: [
                  // dataReg holds the last valid bit, only update on a real bit.
                  dataReg < decoded,
                  // Count consecutive decoded 1s (pinned to 0 while no_stuff),
                  // clear on a 0.
                  If(
                    decoded & ~noStuff,
                    then: [ones < ones + 1],
                    orElse: [ones < Const(0, width: 3)],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('data') <= dataReg;
    output('valid') <= validReg;
    output('stuff_err') <= stuffErrReg;
  }
}

/// Full-speed USB receive PHY: line receiver -> bit recovery -> NRZI/de-stuff
/// plus a packet-framing FSM.
///
/// Composes [HarborUsbLineRx], [HarborUsbBitRecover] and [HarborUsbNrziDestuff]
/// into a single receive datapath and adds packet boundary detection.
///
/// Ports:
///   in:  clk, reset, dp, dm
///   out: data, valid, active, sop, eop, bus_reset
///
/// Framing behavior:
///   - [bus_reset] passes straight through from the line receiver.
///   - SYNC detect: a USB packet opens with a SYNC field that NRZI-decodes to
///     the data byte 0x80 (LSB-first on the wire: seven 0s then a single 1).
///     The framer shifts every decoded data bit (sampled when destuff `valid`
///     is high) into an 8-bit window. While not [active], when that window
///     holds the SYNC pattern, [active] asserts and [sop] pulses for one cycle.
///     The matching (8th) SYNC bit is NOT emitted as packet data.
///   - Packet body: while [active], decoded (data, valid) bits AFTER the SYNC
///     match are forwarded to the [data]/[valid] outputs.
///   - EOP detect: end-of-packet is SE0 held for ~2 bit-times. SE0 is neither
///     J nor K, so EOP is detected from the line-state path: the framer counts
///     bit-strobes (from [HarborUsbBitRecover]) during which the line is SE0.
///     After two such strobes while [active], [eop] pulses for one cycle,
///     [active] deasserts and data forwarding stops.
///   - While not [active], [data]/[valid] are suppressed.
///
/// SYNC-window orientation: decoded bits arrive LSB-first in time. New bits
/// shift into the MSB of the window and older bits fall toward the LSB, so a
/// full SYNC field (0,0,0,0,0,0,0,1 in arrival order) leaves the window reading
/// 0b1000_0000 = 0x80 (newest=MSB=1, oldest=LSB=0) at the match cycle.
class HarborUsbFsPhyRx extends BridgeModule {
  /// Number of SE0 ticks the line receiver requires to declare a bus reset.
  final int resetTicks;

  /// When true, an extra `squelch` input port is created. A real full-speed PHY
  /// isolates its receiver from its own transmitter: while it is driving the
  /// line (oe high) the receiver must NOT decode the device's OWN outgoing
  /// packet as an incoming one. On a true BIDIRECTIONAL pad (the real OrangeCrab
  /// inout: dp = oe?dp_out:host, and the device always reads back the resolved
  /// pad) an un-squelched receiver self-receives every packet it transmits,
  /// fires a spurious sop/pkt_done and corrupts the control FSM (the IN-DATA
  /// stage then never starts -> the host sees "device descriptor read/64, error
  /// -32"). Drive `squelch` from the transmit oe. DEFAULT false leaves the
  /// module byte-for-byte identical to the original (no port, no mux), so every
  /// existing instantiation and unidirectional harness is unchanged.
  final bool squelchable;

  HarborUsbFsPhyRx({
    this.resetTicks = 120,
    this.squelchable = false,
    String? name,
  }) : super('HarborUsbFsPhyRx', name: name ?? 'usb_fsphy_rx') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('dp', PortDirection.input);
    createPort('dm', PortDirection.input);
    if (squelchable) {
      createPort('squelch', PortDirection.input);
    }
    addOutput('data');
    addOutput('valid');
    addOutput('active');
    addOutput('sop');
    addOutput('eop');
    addOutput('bus_reset');

    final clk = input('clk');
    final reset = input('reset');

    // RX squelch (TX self-receive isolation). When squelchable and `squelch` is
    // high (the device is driving the line, oe high) the line the receiver sees
    // is forced to idle-J so the device never self-receives its own outgoing
    // packet (no false sop/pkt_done, no control-FSM corruption). On the real
    // OrangeCrab the D+/D- pads are a single BIDIRECTIONAL ball each (the LoomTop
    // inout shim: dp = oe?dp_out:host, the device always reads back the resolved
    // pad), so without this the receiver self-decodes every packet it transmits
    // and the host sees "device descriptor read/64, error -32". When not
    // squelchable, squelch is constant 0 and the raw pads pass straight through
    // (original behavior, byte-for-byte).
    // While squelched, force the line the receiver sees to idle-J (dp=1, dm=0).
    // This is the HARDWARE-PROVEN squelch: the OrangeCrab enumerates with it.
    final squelch = squelchable ? input('squelch') : Const(0);
    final rxDp = mux(squelch, Const(1), input('dp'));
    final rxDm = mux(squelch, Const(0), input('dm'));

    final lineRx = HarborUsbLineRx(
      resetTicks: resetTicks,
      name: 'fsphy_linerx',
    );
    addSubModule(lineRx);
    lineRx.input('clk').srcConnection! <= clk;
    lineRx.input('reset').srcConnection! <= reset;
    lineRx.input('dp').srcConnection! <= rxDp;
    lineRx.input('dm').srcConnection! <= rxDm;

    // idleResettable is unconditionally true so every HarborUsbFsPhyRx builds an
    // identical HarborUsbBitRecover port list under the one definition name. idle
    // is wired from squelch, which is Const(0) on a non-squelchable instance, so
    // the idle-hold is a no-op there and behavior is unchanged apart from that.
    final bitRec = HarborUsbBitRecover(
      idleResettable: true,
      name: 'fsphy_bitrec',
    );
    addSubModule(bitRec);
    bitRec.input('clk').srcConnection! <= clk;
    bitRec.input('reset').srcConnection! <= reset;
    bitRec.input('line_state').srcConnection! <= lineRx.output('line_state');
    // Squelch-recovery: while we drive the line, HOLD the bit-recovery DLL at its
    // idle seed so it re-locks fresh on the next packet's SYNC (forcing the RX
    // line to idle-J is not enough, the DLL phase must also be reset).
    bitRec.input('idle').srcConnection! <= squelch;

    // idleResettable is unconditionally true so the de-stuffer always carries
    // the [no_stuff] framing gate below. [idle] (the squelch-recovery seed) is
    // wired from [squelch], which is Const(0) on a non-squelchable instance, so
    // the squelch reset is a no-op there and the module is unchanged apart from
    // the framing-gated stuff pin.
    final destuff = HarborUsbNrziDestuff(
      idleResettable: true,
      name: 'fsphy_destuff',
    );
    addSubModule(destuff);
    destuff.input('clk').srcConnection! <= clk;
    destuff.input('reset').srcConnection! <= reset;
    destuff.input('symbol').srcConnection! <= bitRec.output('symbol');
    destuff.input('strobe').srcConnection! <= bitRec.output('strobe');
    // Squelch-recovery: hold the NRZI/de-stuff state at its J-seeded idle so the
    // first symbol after a TX turnaround decodes against a clean seed (Const(0)
    // = never, on a non-squelchable instance).
    destuff.input('idle').srcConnection! <= squelch;

    // bus_reset passes straight through.
    output('bus_reset') <= lineRx.output('bus_reset');

    final dData = destuff.output('data');
    final dValid = destuff.output('valid');
    final strobe = bitRec.output('strobe');
    final isSe0 = lineRx.output('is_se0');

    // States: idle/sync_search (active=0) and packet (active=1). They are
    // distinguished by the registered `active` flag, so a single bit suffices.
    final active = Logic(name: 'active_reg');

    // Bit de-stuffing runs only inside a packet body. While the framer is not
    // active (idle line and SYNC search), pin the de-stuffer's run counter so an
    // idle-J 1-run cannot drop the SYNC's leading 0 as a phantom stuff bit. This
    // applies to every RX instance, not just squelchable ones: any idle gap long
    // enough drives the free-running counter to six and eats the next SYNC's
    // first bit, so both the device RX (after its own TX turnaround) and a host
    // RX (between the packets it receives) need it.
    destuff.input('no_stuff').srcConnection! <= ~active;

    // 8-bit SYNC detection window (newest bit in MSB).
    final syncWin = Logic(name: 'sync_win', width: 8);
    // Combinational next-window: the value after shifting in the current
    // decoded bit. Matching on winNext (rather than the registered syncWin)
    // makes SYNC detection fire on the SAME cycle the 8th SYNC bit's `valid`
    // is high, so the very next valid bit is the first packet-body bit (the
    // 8th SYNC bit itself is never emitted as data).
    final winNext = [dData, syncWin.slice(7, 1)].swizzle();
    // SYNC pattern: 0x80 (see orientation note above).
    final syncMatch = dValid & winNext.eq(Const(0x80, width: 8)) & ~active;

    // SE0 bit-strobe counter for EOP. Counts CONSECUTIVE SE0 strobes while
    // active: it increments on an SE0 strobe and is cleared by any qualified
    // (non-SE0) data strobe, so an isolated SE0 glitch cannot accumulate toward
    // a false EOP (B1). A real EOP is SE0 for two consecutive bit-times.
    final se0Strobes = Logic(name: 'se0_strobes', width: 2);
    // A strobe during which the line is SE0 (qualified bit-time of SE0).
    final se0Strobe = strobe & isSe0;
    // A qualified bit-strobe where the line is NOT SE0 (a real data bit-time).
    final dataStrobe = strobe & ~isSe0;
    // EOP fires once two SE0 bit-times have been observed while active.
    final eopHit = active & se0Strobe & se0Strobes.gte(Const(1, width: 2));

    // Forwarding-stop latch (I1): set the instant the FIRST EOP SE0 strobe is
    // seen so the registered destuff bit that SE0 produces one cycle later is
    // NOT forwarded as a spurious body bit. It is cleared at eop, at sop and by
    // any real data strobe (glitch recovery), and is decoupled from `eopHit`
    // (which still needs the SECOND consecutive SE0 to actually end the packet).
    final eopHold = Logic(name: 'eop_hold');

    // Registered outputs.
    final dataReg = Logic(name: 'rx_data_reg');
    final validReg = Logic(name: 'rx_valid_reg');
    final sopReg = Logic(name: 'sop_reg');
    final eopReg = Logic(name: 'eop_reg');

    Sequential(clk, [
      If(
        reset | squelch,
        then: [
          // On reset OR while squelched (the device is driving the line): hold the
          // framing FSM at its idle seed so it re-locks FRESH on the next packet's
          // SYNC after our own TX. Forcing the RX line to idle-J during squelch is
          // not enough on the real bidirectional pad: the SYNC-detect window, the
          // active flag and the EOP/SE0 counters must also be returned to idle, or
          // a partially-shifted window / stale active flag survives the turnaround
          // and the next host token's PID is misdecoded (ep0 then wedges in
          // _stInWaitToken). squelch is constant 0 when not squelchable, so this is
          // byte-for-byte the original behavior for unidirectional instances.
          active < Const(0),
          // Seed the window to all-1s: idle J NRZI-decodes to a stream of 1s,
          // so an idle line holds the window at 0xFF and never false-matches the
          // SYNC pattern (0x80). Only a real SYNC (seven 0s then a 1) drives it
          // to 0x80.
          syncWin < Const(0xFF, width: 8),
          se0Strobes < Const(0, width: 2),
          eopHold < Const(0),
          dataReg < Const(0),
          validReg < Const(0),
          sopReg < Const(0),
          eopReg < Const(0),
        ],
        orElse: [
          // Default: single-cycle pulses self-clear.
          validReg < Const(0),
          sopReg < Const(0),
          eopReg < Const(0),

          // Shift each decoded data bit into the SYNC window (newest -> MSB).
          If(dValid, then: [syncWin < winNext]),

          If(
            ~active,
            then: [
              // SYNC search: on a match, enter packet, pulse sop. The matching
              // (8th SYNC) bit is consumed by the detector, not emitted as data.
              If(
                syncMatch,
                then: [
                  active < Const(1),
                  sopReg < Const(1),
                  se0Strobes < Const(0, width: 2),
                  eopHold < Const(0),
                  // Reset window to the idle pattern (all 1s) so it cannot re-match.
                  syncWin < Const(0xFF, width: 8),
                ],
              ),
            ],
            orElse: [
              // In packet: forward decoded data bits to the outputs, but ONLY while
              // no EOP SE0 has been seen yet (eopHold low). Once the first EOP SE0
              // strobe latches eopHold, the registered destuff bit it produces a
              // cycle later is suppressed instead of leaking as a body bit (I1).
              If(
                dValid & ~eopHold,
                then: [dataReg < dData, validReg < Const(1)],
              ),
              // A real (non-SE0) data bit-time breaks any SE0 run: clear the
              // consecutive-SE0 counter and the forwarding-stop latch so an
              // isolated SE0 glitch cannot accumulate toward a false EOP (B1).
              If(
                dataStrobe,
                then: [se0Strobes < Const(0, width: 2), eopHold < Const(0)],
              ),
              // EOP: count CONSECUTIVE SE0 bit-times, the second one ends the
              // packet. The first one stops forwarding (eopHold) without ending it.
              If(
                se0Strobe,
                then: [
                  eopHold < Const(1),
                  If(
                    eopHit,
                    then: [
                      active < Const(0),
                      eopReg < Const(1),
                      se0Strobes < Const(0, width: 2),
                      eopHold < Const(0),
                      syncWin < Const(0xFF, width: 8),
                      // Suppress any data that a garbage SE0 bit may have queued.
                      validReg < Const(0),
                    ],
                    orElse: [se0Strobes < se0Strobes + 1],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('data') <= dataReg;
    output('valid') <= validReg;
    output('active') <= active;
    output('sop') <= sopReg;
    output('eop') <= eopReg;
  }
}

/// Full-speed USB transmit PHY: NRZI encode + bit stuff + EOP at 4x timing.
///
/// Runs in the 48 MHz domain. Serializes a host-supplied stream of data bits
/// onto the D+/D- line. The host frames its own packet (it must supply the
/// SYNC field bits then the body bits, exactly as the receive side expects),
/// then requests an EOP. This module owns only the wire-level encoding: NRZI,
/// bit-stuffing and the EOP symbol, each paced to a 4-cycle full-speed bit
/// time.
///
/// Line-state encoding (line = {dp, dm}, bit1=dp bit0=dm), same as the Rx side:
///   J (idle) = 0b10, K = 0b01, SE0 = 0b00.
/// NRZI: a data 1 HOLDS the line, a data 0 TOGGLES it (J<->K).
///
/// HANDSHAKE (per-bit pull, TX is the timing master):
///   - The TX paces everything with a 2-bit [_phase] counter (0..3). Each line
///     symbol is driven for a full 4-cycle bit time.
///   - [ready] means "I will accept a new bit on the next posedge". INSIDE a
///     packet it is a single-cycle pulse on the LAST cycle (phase==3) of a data
///     bit time. AT IDLE, however, [ready] is held LEVEL-HIGH every cycle (the
///     TX is continuously willing to start a packet). So [ready] is NOT a pure
///     one-shot: a host must only treat it as a consume when it is itself
///     presenting a bit (i.e. qualify the accept with its own [data_valid], and
///     in tests gate on `ready & oe` to ignore idle-level ready). The host must
///     present [data] and assert [data_valid] stable across the accepting
///     posedge.
///   - On that posedge: if [data_valid] is high, the presented [data] bit is
///     consumed and encoded as the next bit time. If [eop_req] is high (and no
///     more data is offered) the TX runs an EOP instead. If neither, the TX
///     parks at idle (drives J, oe low) and keeps pulsing [ready] until the
///     host has something.
///   - [ready] is SUPPRESSED during a stuffed bit time and during the EOP,
///     because those symbols are generated by the TX itself, not pulled from
///     the host.
///   - [busy] is high whenever the TX is actively driving the line for a packet
///     or an EOP (it mirrors [oe]), it is low at idle.
///
/// BIT STUFFING:
///   The TX counts consecutive transmitted 1s (HOLDs). After six 1s it inserts
///   one stuffed 0 (a forced toggle) as an EXTRA bit time before accepting the
///   next host bit, then clears the run counter. The host is unaware of the
///   stuffed bit: [ready] does not pulse for it, so the host's bit stream stays
///   aligned.
///
/// EOP:
///   On an accepted [eop_req], after the current data bits the TX drives SE0
///   for two bit times then J for one bit time, then deasserts [oe]/[busy] and
///   returns to idle. EOP cannot be split by a stuff (it is line-state SE0/J,
///   not an encoded data bit), so the run counter is irrelevant during it.
///
/// FSM STATES (2-bit [_state]):
///   idle (0)     : parked at J, oe low. Pulses ready. On a posedge with
///                  data_valid -> sending, with eop_req -> eop.
///   sending (1)  : driving a host data bit's NRZI symbol for 4 cycles. At
///                  phase==3 decides the next bit time: stuff (if ones hit 6),
///                  another host bit (data_valid), an EOP (eop_req) or idle.
///   stuffing (2) : driving the forced-toggle stuffed 0 for 4 cycles. ready is
///                  suppressed. At phase==3 it resumes like sending's decision.
///   eop (3)      : driving SE0, SE0, J across three bit times, then idle.
class HarborUsbFsPhyTx extends BridgeModule {
  // State encodings.
  static const int _sIdle = 0;
  static const int _sSend = 1;
  static const int _sStuff = 2;
  static const int _sEop = 3;

  HarborUsbFsPhyTx({String? name})
    : super('HarborUsbFsPhyTx', name: name ?? 'usb_fsphy_tx') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('data', PortDirection.input);
    createPort('data_valid', PortDirection.input);
    createPort('eop_req', PortDirection.input);
    addOutput('dp_out');
    addOutput('dm_out');
    addOutput('oe');
    addOutput('ready');
    addOutput('busy');
    // High only while driving encoded NRZI DATA (sending/stuffing), low at idle
    // AND during the EOP (SE0/SE0/J). Drive a receiver's squelch from this rather
    // than [oe]: it isolates the receiver from our own data (the part that could
    // be self-decoded as a packet) but RELEASES the receiver the instant the EOP
    // begins, so a host that starts its next packet during our bus-turnaround
    // (oe still high through the EOP) is not blanked. The EOP itself is SE0/J and
    // can never be mistaken for a SYNC, so un-squelching during it is safe.
    addOutput('tx_data_active');

    final clk = input('clk');
    final reset = input('reset');
    final data = input('data');
    final dataValid = input('data_valid');
    final eopReq = input('eop_req');

    final state = Logic(name: 'tx_state', width: 2);
    // Bit-time phase: each driven symbol is held 4 cycles (phase 0->3).
    final phase = Logic(name: 'tx_phase', width: 2);
    // Current NRZI line state (J/K/SE0). Seeded to J (idle) on reset.
    final line = Logic(name: 'tx_line', width: 2);
    // oe register: high while driving a packet/EOP (low at idle).
    final oeReg = Logic(name: 'tx_oe', width: 1);
    // Consecutive transmitted-1 (HOLD) run counter (0..6), 3 bits.
    final ones = Logic(name: 'tx_ones', width: 3);
    // EOP sub-phase: 0 = first SE0, 1 = second SE0, 2 = J terminator.
    final eopPhase = Logic(name: 'tx_eop_phase', width: 2);

    // Line-state constants.
    final jLine = Const(0x2, width: 2); // dp=1 dm=0
    final kLine = Const(0x1, width: 2); // dp=0 dm=1
    final se0 = Const(0x0, width: 2);

    // Toggle helper: J<->K. dp and dm swap. (J=10 <-> K=01 == bit-reverse of a
    // 2-bit one-hot, equivalently XOR with 0b11 maps 10<->01 and 00<->11, but
    // we only ever toggle from J or K so a swap is exact.)
    Logic toggled(Logic l) => [l.slice(0, 0), l.slice(1, 1)].swizzle();

    // End-of-bit-time marker: the last oversample cycle of the current symbol.
    final atBitEnd = phase.eq(Const(3, width: 2));

    // ready pulses on the last cycle of a HOST-pulled bit time so the host can
    // present the next bit for the upcoming posedge. It is suppressed at the
    // end of a stuffed bit (TX-generated) and during the EOP. At idle the TX
    // also offers ready every cycle so a host can start a packet.
    final readyLocal = Logic(name: 'tx_ready');
    // busy mirrors oe (driving the line for a packet or EOP).
    // (declared as outputs below.)

    // The next host bit is accepted only when the host offers it.
    final takeData = dataValid;
    // A stuff is due when six consecutive 1s have been transmitted.
    final stuffDue = ones.eq(Const(6, width: 3));
    // EOP requested (only honored when no more data is offered, so a host can
    // keep streaming and tail an EOP by dropping data_valid and raising
    // eop_req on the same accept edge).
    final eopDue = eopReq;

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(_sIdle, width: 2),
          phase < Const(0, width: 2),
          line < jLine,
          oeReg < Const(0, width: 1),
          ones < Const(0, width: 3),
          eopPhase < Const(0, width: 2),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(_sIdle, width: 2), [
              phase < Const(0, width: 2),
              line < jLine,
              oeReg < Const(0, width: 1),
              ones < Const(0, width: 3),
              eopPhase < Const(0, width: 2),
              // Start a packet on a host bit, honor an EOP request only if the
              // host explicitly asks while idle (degenerate empty EOP).
              If(
                takeData,
                then: [
                  // Encode the first host bit: data 1 holds J, data 0 toggles to K.
                  If(
                    data,
                    then: [line < jLine, ones < Const(1, width: 3)],
                    orElse: [
                      line < kLine, // toggle from idle J
                      ones < Const(0, width: 3),
                    ],
                  ),
                  oeReg < Const(1, width: 1),
                  phase < Const(0, width: 2),
                  state < Const(_sSend, width: 2),
                ],
                orElse: [
                  If(
                    eopDue,
                    then: [
                      // Begin EOP from idle: drive SE0 (sub-phase 0).
                      line < se0,
                      oeReg < Const(1, width: 1),
                      eopPhase < Const(0, width: 2),
                      phase < Const(0, width: 2),
                      state < Const(_sEop, width: 2),
                    ],
                  ),
                ],
              ),
            ]),

            CaseItem(Const(_sSend, width: 2), [
              If(
                ~atBitEnd,
                then: [phase < phase + 1],
                orElse: [
                  // Bit time complete: decide the next symbol.
                  phase < Const(0, width: 2),
                  If(
                    stuffDue,
                    then: [
                      // Insert a forced-toggle stuffed 0, host bit deferred.
                      line < toggled(line),
                      ones < Const(0, width: 3),
                      oeReg < Const(1, width: 1),
                      state < Const(_sStuff, width: 2),
                    ],
                    orElse: [
                      If(
                        takeData,
                        then: [
                          // Next host bit: 1 holds, 0 toggles.
                          If(
                            data,
                            then: [
                              // hold line, bump ones (saturating logic handled by stuffDue)
                              ones < ones + 1,
                            ],
                            orElse: [
                              line < toggled(line),
                              ones < Const(0, width: 3),
                            ],
                          ),
                          oeReg < Const(1, width: 1),
                          state < Const(_sSend, width: 2),
                        ],
                        orElse: [
                          If(
                            eopDue,
                            then: [
                              line < se0,
                              oeReg < Const(1, width: 1),
                              eopPhase < Const(0, width: 2),
                              state < Const(_sEop, width: 2),
                            ],
                            orElse: [
                              // No more data and no EOP: park at idle.
                              line < jLine,
                              oeReg < Const(0, width: 1),
                              ones < Const(0, width: 3),
                              state < Const(_sIdle, width: 2),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            CaseItem(Const(_sStuff, width: 2), [
              If(
                ~atBitEnd,
                then: [phase < phase + 1],
                orElse: [
                  phase < Const(0, width: 2),
                  // After the stuffed bit, resume with the deferred host decision.
                  If(
                    takeData,
                    then: [
                      If(
                        data,
                        then: [ones < ones + 1],
                        orElse: [
                          line < toggled(line),
                          ones < Const(0, width: 3),
                        ],
                      ),
                      oeReg < Const(1, width: 1),
                      state < Const(_sSend, width: 2),
                    ],
                    orElse: [
                      If(
                        eopDue,
                        then: [
                          line < se0,
                          oeReg < Const(1, width: 1),
                          eopPhase < Const(0, width: 2),
                          state < Const(_sEop, width: 2),
                        ],
                        orElse: [
                          line < jLine,
                          oeReg < Const(0, width: 1),
                          ones < Const(0, width: 3),
                          state < Const(_sIdle, width: 2),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            CaseItem(Const(_sEop, width: 2), [
              If(
                ~atBitEnd,
                then: [phase < phase + 1],
                orElse: [
                  phase < Const(0, width: 2),
                  If(
                    eopPhase.eq(Const(0, width: 2)),
                    then: [
                      // First SE0 done -> second SE0.
                      line < se0,
                      eopPhase < Const(1, width: 2),
                    ],
                    orElse: [
                      If(
                        eopPhase.eq(Const(1, width: 2)),
                        then: [
                          // Second SE0 done -> J terminator.
                          line < jLine,
                          eopPhase < Const(2, width: 2),
                        ],
                        orElse: [
                          // J terminator done -> back to idle, stop driving.
                          line < jLine,
                          oeReg < Const(0, width: 1),
                          eopPhase < Const(0, width: 2),
                          ones < Const(0, width: 3),
                          state < Const(_sIdle, width: 2),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // ready: combinational on the registered state/phase. It pulses on exactly
    // the edges where the FSM CONSUMES a host data bit, so the host's bit
    // pointer stays in lock-step with what the wire actually carries.
    //   - idle: offer ready every cycle (host may start a packet, the consume
    //     happens on the first idle edge with data_valid).
    //   - sending: pulse at phase==3 (consumes the next host bit), UNLESS a
    //     stuff is due on that edge. Then the stuffed bit is inserted and the
    //     host bit is deferred to the END of the stuffing bit time instead.
    //   - stuffing: pulse at phase==3, where the deferred host bit is consumed.
    //   - eop: never (TX-owned symbol).
    readyLocal <=
        state.eq(Const(_sIdle, width: 2)) |
            (state.eq(Const(_sSend, width: 2)) & atBitEnd & ~stuffDue) |
            (state.eq(Const(_sStuff, width: 2)) & atBitEnd);

    output('ready') <= readyLocal;
    output('busy') <= oeReg;
    output('oe') <= oeReg;
    // Driving encoded data (NOT idle, NOT EOP): high in sending/stuffing only.
    output('tx_data_active') <=
        oeReg &
            (state.eq(Const(_sSend, width: 2)) |
                state.eq(Const(_sStuff, width: 2)));
    // Drive the line: dp = bit1, dm = bit0 of the line state.
    output('dp_out') <= line.slice(1, 1);
    output('dm_out') <= line.slice(0, 0);
  }
}
