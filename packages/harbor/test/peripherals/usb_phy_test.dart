import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Host-side line encoder (ported/adapted from usb_test.dart). Builds the
// [dp, dm] line symbols for a packet (SYNC prepended) with bit-stuffing, NRZI
// and a trailing EOP (SE0 SE0 J).

// USB CRC5: reflected poly 0x14, init 0x1F, over `nbits` bits LSB first.
int _crc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

// USB CRC16: reflected poly 0xA001, init 0xFFFF, LSB first per byte.
int _crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

// Builds the two token bytes for addr/endp (11 data bits + CRC5).
List<int> _token(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (_crc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

// PID byte from a 4-bit PID nibble.
int _pid(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

// Encodes a packet (PID byte + body, SYNC 0x80 prepended here) into line
// symbols with bit stuffing, NRZI and an EOP. Each entry is [dp, dm].
List<List<int>> _encode(List<int> bytes) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = 1; // idle J
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line; // NRZI: 0 => transition
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]); // EOP SE0
  out.add([0, 0]); // EOP SE0
  out.add([1, 0]); // J
  return out;
}

// Composable encoder: emits the SYNC+body NRZI line symbols for `bytes`,
// starting from line state `startLine` (1 = J, 0 = K). Does NOT append an EOP.
// Returns the symbols and the final line state so packets can be chained with
// a real spec EOP (SE0 SE0 J) between them.
class _Body {
  final List<List<int>> syms;
  _Body(this.syms);
}

_Body _encodeBody(List<int> bytes, {int startLine = 1}) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = startLine;
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line; // NRZI: 0 => transition
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  return _Body(out);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbLineRx', () {
    test('J idle: is_j asserts after sync pipeline fills', () async {
      final dut = HarborUsbLineRx(name: 'rx_j_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;

      await dut.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Advance enough cycles for the 2-flop sync to propagate (3+ posedges).
      for (var i = 0; i < 6; i++) {
        await clk.nextPosedge;
      }

      expect(dut.output('is_j').value.toInt(), equals(1), reason: 'is_j');
      expect(
        dut.output('is_se0').value.toInt(),
        equals(0),
        reason: 'is_se0 low',
      );
      expect(
        dut.output('bus_reset').value.toInt(),
        equals(0),
        reason: 'no bus_reset on J',
      );

      await Simulator.endSimulation();
    });

    test('SE0 held long enough asserts bus_reset', () async {
      final dut = HarborUsbLineRx(name: 'rx_se0_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;

      await dut.build();

      reset.inject(1);
      dp.inject(0);
      dm.inject(0);
      Simulator.setMaxSimTime(30000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Hold SE0 for well over resetTicks (120) cycles.
      for (var i = 0; i < 130; i++) {
        await clk.nextPosedge;
      }

      expect(dut.output('is_se0').value.toInt(), equals(1), reason: 'is_se0');
      expect(
        dut.output('bus_reset').value.toInt(),
        equals(1),
        reason: 'bus_reset after 120+ SE0 ticks',
      );

      await Simulator.endSimulation();
    });

    test('bus_reset deasserts when line returns to J', () async {
      final dut = HarborUsbLineRx(name: 'rx_deassert_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;

      await dut.build();

      reset.inject(1);
      dp.inject(0);
      dm.inject(0);
      Simulator.setMaxSimTime(40000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Trigger bus reset.
      for (var i = 0; i < 130; i++) {
        await clk.nextPosedge;
      }
      expect(
        dut.output('bus_reset').value.toInt(),
        equals(1),
        reason: 'bus_reset asserted',
      );

      // Return to J (dp=1, dm=0), counter should clear.
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      expect(
        dut.output('bus_reset').value.toInt(),
        equals(0),
        reason: 'bus_reset deasserted after J',
      );

      await Simulator.endSimulation();
    });
  });

  group('HarborUsbBitRecover', () {
    test('steady J for 8 ticks yields exactly 2 strobes', () async {
      final dut = HarborUsbBitRecover(name: 'bitrec_steady_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final lineState = Logic(name: 'line_state', width: 2);

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('line_state').srcConnection! <= lineState;

      await dut.build();

      reset.inject(1);
      // J = 0b10
      lineState.inject(2);
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Count strobes over 8 posedges after reset deasserts.
      // After reset: phase=0, lastLs=J. Phase starts at 0 and increments each
      // cycle with no edge. strobe fires when phase==1 (combinational).
      // Cycle offsets (post-reset): phase=0 (no strobe), phase=1 (STROBE),
      // phase=2, phase=3, phase=0, phase=1 (STROBE), phase=2, phase=3.
      // -> exactly 2 strobes in 8 ticks.
      var strobeCount = 0;
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
        if (dut.output('strobe').value.toInt() == 1) strobeCount++;
      }

      expect(
        strobeCount,
        equals(2),
        reason: 'exactly 2 strobes per 2 bit-times',
      );
      await Simulator.endSimulation();
    });

    test(
      'J->K transition re-centers phase: strobe is LOW on edge cycle, HIGH 2 cycles later',
      () async {
        final dut = HarborUsbBitRecover(name: 'bitrec_edge_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final lineState = Logic(name: 'line_state', width: 2);

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('line_state').srcConnection! <= lineState;

        await dut.build();

        reset.inject(1);
        lineState.inject(2); // J
        Simulator.setMaxSimTime(5000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);

        // Phase cadence post-reset (strobe is combinational on the registered phase):
        //   Posedge 1: phase 0->1, strobe=1
        //   Posedge 2: phase 1->2, strobe=0
        //   Posedge 3: phase 2->3, strobe=0
        //   Posedge 4: phase 3->0, strobe=0
        // After 4 posedges phase is 0 and strobe is 0.
        for (var i = 0; i < 4; i++) {
          await clk.nextPosedge;
        }
        // phase=0 here. Strobe is 0.
        final strobeBeforeEdge = dut.output('strobe').value.toInt();

        // Switch to K (0b01). Inject fires between posedges so the next posedge
        // sees ls=K, lastLs=J and detects the edge.
        lineState.inject(1); // K

        // Posedge 5 (boundary cycle N): edge detected, phase re-centers to 3.
        // strobe is combinational on the registered phase, old phase was 0, new
        // phase is 3 -> strobe=0 (phase!=1). LOW on the boundary cycle.
        await clk.nextPosedge;
        final strobeAtEdge = dut.output('strobe').value.toInt(); // must be 0

        // Posedge N+1: no edge, phase 3->0. strobe=0 (phase!=1).
        await clk.nextPosedge;
        final strokeOnePastEdge = dut
            .output('strobe')
            .value
            .toInt(); // must be 0

        // Posedge N+2: no edge, phase 0->1. strobe=1 (bit center, oversample 2).
        await clk.nextPosedge;
        final strobeTwoPastEdge = dut
            .output('strobe')
            .value
            .toInt(); // must be 1

        // Posedge N+3: phase 1->2. strobe=0.
        await clk.nextPosedge;
        final strobeThreePastEdge = dut
            .output('strobe')
            .value
            .toInt(); // must be 0

        // No strobe before the edge (phase was 0).
        expect(
          strobeBeforeEdge,
          equals(0),
          reason: 'no strobe before edge (phase==0)',
        );
        // Strobe is LOW on the boundary cycle (re-center to 3, not 1).
        expect(
          strobeAtEdge,
          equals(0),
          reason: 'strobe LOW on boundary cycle after re-center to 3',
        );
        // Still LOW one cycle after the boundary (phase==0).
        expect(
          strokeOnePastEdge,
          equals(0),
          reason: 'strobe LOW one cycle after boundary (phase==0)',
        );
        // HIGH two cycles after the boundary (phase==1 = bit center).
        expect(
          strobeTwoPastEdge,
          equals(1),
          reason: 'strobe HIGH 2 cycles after boundary (bit center)',
        );
        // Back to LOW (phase advances past 1).
        expect(
          strobeThreePastEdge,
          equals(0),
          reason: 'strobe LOW after bit-center cycle',
        );

        await Simulator.endSimulation();
      },
    );

    test(
      'symbol latched at bit center: J->K then held, symbol==K at strobe',
      () async {
        // Verifies that after a J->K transition the strobe lands at oversample 2
        // (bit center) and the latched symbol equals K (0b01). Then mirrors K->J.
        final dut = HarborUsbBitRecover(name: 'bitrec_samplept_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final lineState = Logic(name: 'line_state', width: 2);

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('line_state').srcConnection! <= lineState;

        await dut.build();

        reset.inject(1);
        lineState.inject(2); // J = 0b10
        Simulator.setMaxSimTime(5000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);

        // Advance 4 cycles to get phase back to 0 (strobe fires at posedge 1
        // when phase goes 0->1, then free-runs, after 4 cycles phase==0 again).
        for (var i = 0; i < 4; i++) {
          await clk.nextPosedge;
        }

        // J->K transition. Phase is 0.
        lineState.inject(1); // K = 0b01

        // N (boundary): phase 0->3 (re-center), strobe=0.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(0),
          reason: 'J->K: strobe LOW on boundary cycle',
        );

        // N+1: phase 3->0, strobe=0.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(0),
          reason: 'J->K: strobe LOW one cycle after boundary',
        );

        // N+2: phase 0->1, strobe=1 (bit center). symbol must be K=0b01.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(1),
          reason: 'J->K: strobe HIGH 2 cycles after boundary (bit center)',
        );
        expect(
          dut.output('symbol').value.toInt(),
          equals(1),
          reason: 'J->K: symbol==K (0b01) at bit-center strobe',
        );

        // Now mirror: K->J transition. Phase continues from 1->2 on next cycle,
        // advance until phase==0 again so we start from a clean state.
        for (var i = 0; i < 3; i++) {
          await clk.nextPosedge;
        }
        // phase==0 again.

        lineState.inject(2); // K->J = 0b10

        // N (boundary): phase 0->3, strobe=0.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(0),
          reason: 'K->J: strobe LOW on boundary cycle',
        );

        // N+1: phase 3->0, strobe=0.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(0),
          reason: 'K->J: strobe LOW one cycle after boundary',
        );

        // N+2: phase 0->1, strobe=1. symbol must be J=0b10.
        await clk.nextPosedge;
        expect(
          dut.output('strobe').value.toInt(),
          equals(1),
          reason: 'K->J: strobe HIGH 2 cycles after boundary (bit center)',
        );
        expect(
          dut.output('symbol').value.toInt(),
          equals(2),
          reason: 'K->J: symbol==J (0b10) at bit-center strobe',
        );

        await Simulator.endSimulation();
      },
    );
  });

  group('HarborUsbNrziDestuff', () {
    test(
      'six decoded-1s followed by stuffed-0 drops stuffed bit, resumes correctly',
      () async {
        // TIMING (REGISTERED outputs):
        //   lastSym is registered, reset-seeded to J (0x2).
        //   decoded = symbol.eq(lastSym) is combinational on registered lastSym.
        //   valid/data/stuff_err are REGISTERED: they assert ONE clock after the
        //   strobe that produced them. valid is a single-cycle pulse.
        //   isStuff = ones.eq(6) checks the REGISTERED ones counter BEFORE update.
        //
        // Strobe sequence (all J=0x2 for ones-count, then K=0x1 as stuffed bit):
        //   S1: sym=J, lastSym=J -> decoded=1, ones=0->1, valid=1, data=1
        //   S2: sym=J, ones=1->2, valid=1, data=1
        //   S3: sym=J, ones=2->3, valid=1, data=1
        //   S4: sym=J, ones=3->4, valid=1, data=1
        //   S5: sym=J, ones=4->5, valid=1, data=1
        //   S6: sym=J, ones=5->6, valid=1, data=1  (isStuff checks pre-update ones=5)
        //   S7: sym=K, ones=6, isStuff=1, decoded=K.eq(J)=0 -> valid=0 (DROP), stuff_err=0
        //       ones->0, lastSym->K
        //   S8: sym=K, lastSym=K -> decoded=1, ones=0->1, valid=1, data=1
        //   S9: sym=J, lastSym=K -> decoded=0, ones->0, valid=1, data=0

        final dut = HarborUsbNrziDestuff(name: 'destuff_basic_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final symbol = Logic(name: 'symbol', width: 2);
        final strobe = Logic(name: 'strobe');

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('symbol').srcConnection! <= symbol;
        dut.input('strobe').srcConnection! <= strobe;

        await dut.build();

        reset.inject(1);
        symbol.inject(2); // J
        strobe.inject(0);
        Simulator.setMaxSimTime(10000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);

        // Collect (valid, data, stuff_err) at each strobe posedge.
        // driveStrobe pulses strobe high, we read outputs on that same posedge.
        final bits = <int>[];
        final stuffErrors = <int>[];
        int? stuffedCycleValid;

        // S1..S6: six consecutive decoded 1s (symbol=J vs lastSym=J).
        for (var i = 0; i < 6; i++) {
          symbol.inject(2); // J
          strobe.inject(1);
          await clk.nextPosedge;
          if (dut.output('valid').value.toInt() == 1) {
            bits.add(dut.output('data').value.toInt());
          }
          stuffErrors.add(dut.output('stuff_err').value.toInt());
          strobe.inject(0);
          for (var j = 0; j < 3; j++) {
            await clk.nextPosedge;
          }
        }

        // S7: stuffed bit. Symbol=K so decoded=0 (K!=J), isStuff=1 -> valid=0 DROP.
        symbol.inject(1); // K
        strobe.inject(1);
        await clk.nextPosedge;
        stuffedCycleValid = dut.output('valid').value.toInt();
        final stuffedErr = dut.output('stuff_err').value.toInt();
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }

        // S8: sym=K, lastSym=K after S7 -> decoded=1, valid=1, data=1.
        symbol.inject(1); // K
        strobe.inject(1);
        await clk.nextPosedge;
        if (dut.output('valid').value.toInt() == 1) {
          bits.add(dut.output('data').value.toInt());
        }
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }

        // S9: sym=J, lastSym=K -> decoded=0, valid=1, data=0.
        symbol.inject(2); // J
        strobe.inject(1);
        await clk.nextPosedge;
        if (dut.output('valid').value.toInt() == 1) {
          bits.add(dut.output('data').value.toInt());
        }
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }

        // S1..S6: six real bits, all 1.
        expect(bits.length, equals(8), reason: '6 + 1 + 1 real bits collected');
        expect(
          bits.sublist(0, 6),
          everyElement(equals(1)),
          reason: 'S1..S6 all decoded as 1',
        );
        // S7 dropped.
        expect(
          stuffedCycleValid,
          equals(0),
          reason: 'stuffed bit: valid must be 0',
        );
        expect(
          stuffedErr,
          equals(0),
          reason: 'no stuff_err for a proper stuffed 0',
        );
        // S8: data=1, S9: data=0.
        expect(bits[6], equals(1), reason: 'S8 decoded 1 (K->K)');
        expect(bits[7], equals(0), reason: 'S9 decoded 0 (J->K transition)');
        // No stuff errors in the non-stuff cycles.
        expect(
          stuffErrors,
          everyElement(equals(0)),
          reason: 'no stuff_err in normal run',
        );

        await Simulator.endSimulation();
      },
    );

    test('mixed sequence decodes correctly via NRZI', () async {
      // Drive: J K J J K K (vs lastSym=J seed).
      // NRZI decoded bits:
      //   sym=J vs last=J -> 1
      //   sym=K vs last=J -> 0
      //   sym=J vs last=K -> 0
      //   sym=J vs last=J -> 1
      //   sym=K vs last=J -> 0
      //   sym=K vs last=K -> 1
      // Expected bits: [1, 0, 0, 1, 0, 1]
      final dut = HarborUsbNrziDestuff(name: 'destuff_mixed_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final symbol = Logic(name: 'symbol', width: 2);
      final strobe = Logic(name: 'strobe');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('symbol').srcConnection! <= symbol;
      dut.input('strobe').srcConnection! <= strobe;

      await dut.build();

      reset.inject(1);
      symbol.inject(2);
      strobe.inject(0);
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      final syms = [2, 1, 2, 2, 1, 1]; // J K J J K K
      final expected = [1, 0, 0, 1, 0, 1];
      final bits = <int>[];

      for (final sym in syms) {
        symbol.inject(sym);
        strobe.inject(1);
        await clk.nextPosedge;
        if (dut.output('valid').value.toInt() == 1) {
          bits.add(dut.output('data').value.toInt());
        }
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }
      }

      expect(bits, equals(expected), reason: 'NRZI decode: mixed J/K sequence');
      await Simulator.endSimulation();
    });

    test('stuff_err when 7th consecutive 1 appears (stuffed 1, not 0)', () async {
      // Drive seven J symbols in a row (each decodes as 1 vs last=J).
      // S1..S6: valid bits. S7: isStuff=1, but decoded=1 (J==J) -> stuff_err=1.
      final dut = HarborUsbNrziDestuff(name: 'destuff_err_test');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final symbol = Logic(name: 'symbol', width: 2);
      final strobe = Logic(name: 'strobe');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('symbol').srcConnection! <= symbol;
      dut.input('strobe').srcConnection! <= strobe;

      await dut.build();

      reset.inject(1);
      symbol.inject(2);
      strobe.inject(0);
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      var stuffErrSeen = 0;

      for (var i = 0; i < 7; i++) {
        symbol.inject(2); // J
        strobe.inject(1);
        await clk.nextPosedge;
        if (dut.output('stuff_err').value.toInt() == 1) stuffErrSeen++;
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }
      }

      expect(
        stuffErrSeen,
        equals(1),
        reason: 'exactly one stuff_err on the 7th consecutive 1',
      );
      await Simulator.endSimulation();
    });

    test(
      'back-to-back strobes: valid pulses every cycle, does not get stuck high',
      () async {
        // TIMING TRACE (strobe held high every cycle, sym alternates J/K/J/K):
        //   Reset: lastSym=J(2), ones=0.
        //   Posedge A: sym=J, decoded=J.eq(J)=1, isStuff=0. Reg: validReg=1, dataReg=1,
        //              lastSym<-J, ones<-1.
        //   Posedge B: sym=K, decoded=K.eq(J)=0, isStuff=0. Reg: validReg=1, dataReg=0,
        //              lastSym<-K, ones<-0.
        //   Posedge C: sym=J, decoded=J.eq(K)=0, isStuff=0. Reg: validReg=1, dataReg=0,
        //              lastSym<-J, ones<-0.
        //   Posedge D: sym=K, decoded=K.eq(J)=0, isStuff=0. Reg: validReg=1, dataReg=0,
        //              lastSym<-K, ones<-0.
        //   Expected: valid=[1,1,1,1], data=[1,0,0,0].
        //   After strobe deasserts: validReg self-clears to 0 (no strobe => 0 & ~isStuff = 0).
        final dut = HarborUsbNrziDestuff(name: 'destuff_backtoback_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final symbol = Logic(name: 'symbol', width: 2);
        final strobe = Logic(name: 'strobe');

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('symbol').srcConnection! <= symbol;
        dut.input('strobe').srcConnection! <= strobe;

        await dut.build();

        reset.inject(1);
        symbol.inject(2);
        strobe.inject(0);
        Simulator.setMaxSimTime(5000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge; // one idle cycle after reset deassert

        // Drive 4 back-to-back strobes with alternating sym J/K/J/K.
        final syms = [2, 1, 2, 1]; // J K J K
        final validOut = <int>[];
        final dataOut = <int>[];

        for (final sym in syms) {
          symbol.inject(sym);
          strobe.inject(1);
          await clk.nextPosedge;
          validOut.add(dut.output('valid').value.toInt());
          dataOut.add(dut.output('data').value.toInt());
        }

        // valid must pulse exactly once per strobed bit (not stuck high).
        expect(
          validOut,
          equals([1, 1, 1, 1]),
          reason: 'valid high every strobed cycle: one pulse per bit',
        );
        // data sequence per trace above.
        expect(
          dataOut,
          equals([1, 0, 0, 0]),
          reason: 'data: J->J=1, K->J=0, J->K=0, K->J=0 per trace',
        );

        // Deassert strobe, valid must self-clear the very next cycle.
        strobe.inject(0);
        await clk.nextPosedge;
        expect(
          dut.output('valid').value.toInt(),
          equals(0),
          reason: 'valid self-clears when strobe low',
        );

        await Simulator.endSimulation();
      },
    );

    test(
      'reset mid-stream clears state and restores fresh-start decode',
      () async {
        // Drive 3 strobes (J J K) to build up some ones state, then assert reset
        // for one cycle. After reset deassert, drive two more strobes (J K) and
        // verify they decode as if starting fresh (lastSym=J seed).
        //
        // Pre-reset:
        //   S1: sym=J, decoded=J.eq(J)=1, ones->1
        //   S2: sym=J, decoded=J.eq(J)=1, ones->2
        //   S3: sym=K, decoded=K.eq(J)=0, ones->0
        //
        // Reset: lastSym<-J(2), ones<-0.
        //
        // Post-reset:
        //   S4: sym=J, decoded=J.eq(J)=1, valid=1, data=1
        //   S5: sym=K, decoded=K.eq(J)=0, valid=1, data=0
        final dut = HarborUsbNrziDestuff(name: 'destuff_reset_test');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final symbol = Logic(name: 'symbol', width: 2);
        final strobe = Logic(name: 'strobe');

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('symbol').srcConnection! <= symbol;
        dut.input('strobe').srcConnection! <= strobe;

        await dut.build();

        reset.inject(1);
        symbol.inject(2);
        strobe.inject(0);
        Simulator.setMaxSimTime(5000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);

        // S1..S3: build up some state before reset.
        for (final sym in [2, 2, 1]) {
          // J J K
          symbol.inject(sym);
          strobe.inject(1);
          await clk.nextPosedge;
          strobe.inject(0);
          for (var j = 0; j < 3; j++) {
            await clk.nextPosedge;
          }
        }

        // Assert reset mid-stream for one cycle.
        reset.inject(1);
        strobe.inject(0);
        await clk.nextPosedge;
        // Immediately confirm outputs clear during reset.
        expect(
          dut.output('valid').value.toInt(),
          equals(0),
          reason: 'valid cleared during reset',
        );
        expect(
          dut.output('stuff_err').value.toInt(),
          equals(0),
          reason: 'stuff_err cleared during reset',
        );
        reset.inject(0);

        // S4: sym=J should decode as 1 (lastSym reset to J).
        symbol.inject(2); // J
        strobe.inject(1);
        await clk.nextPosedge;
        final validS4 = dut.output('valid').value.toInt();
        final dataS4 = dut.output('data').value.toInt();
        strobe.inject(0);
        for (var j = 0; j < 3; j++) {
          await clk.nextPosedge;
        }

        // S5: sym=K, lastSym=J after S4 -> decoded=0.
        symbol.inject(1); // K
        strobe.inject(1);
        await clk.nextPosedge;
        final validS5 = dut.output('valid').value.toInt();
        final dataS5 = dut.output('data').value.toInt();
        strobe.inject(0);

        expect(validS4, equals(1), reason: 'S4 valid after reset: fresh start');
        expect(
          dataS4,
          equals(1),
          reason: 'S4 data: J.eq(J)=1 (lastSym seeded J)',
        );
        expect(validS5, equals(1), reason: 'S5 valid');
        expect(dataS5, equals(0), reason: 'S5 data: K.eq(J)=0 (transition)');

        await Simulator.endSimulation();
      },
    );
  });

  group('HarborUsbFsPhyRx', () {
    // Drives an encoded packet into the PHY at 4x oversample (each line symbol
    // held for 4 clk posedges) and collects the framing outputs. Returns the
    // assembled body bytes plus pulse counts and observed sync timing.
    Future<Map<String, dynamic>> runPacket(List<int> bytes) async {
      final dut = HarborUsbFsPhyRx(name: 'fsphy_${bytes.hashCode & 0xFFFF}');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;

      await dut.build();

      reset.inject(1);
      dp.inject(1); // idle J
      dm.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Let the line idle at J for a few bit-times so the DLL and destuff
      // settle before the packet starts.
      for (var i = 0; i < 16; i++) {
        await clk.nextPosedge;
      }

      final syms = _encode(bytes);

      var sopCount = 0;
      var eopCount = 0;
      var busResetSeen = 0;
      final bodyBits = <int>[];
      // Whether sop was observed before any body bit (ordering sanity).
      var sawSopBeforeBody = true;

      Future<void> sample() async {
        if (dut.output('sop').value.toInt() == 1) sopCount++;
        if (dut.output('eop').value.toInt() == 1) eopCount++;
        if (dut.output('bus_reset').value.toInt() == 1) busResetSeen++;
        final active = dut.output('active').value.toInt();
        final valid = dut.output('valid').value.toInt();
        if (active == 1 && valid == 1) {
          if (sopCount == 0) sawSopBeforeBody = false;
          bodyBits.add(dut.output('data').value.toInt());
        }
      }

      // Drive each line symbol for 4 clk posedges (one full-speed bit time).
      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }
      // Return to idle J and drain the pipeline so a trailing EOP lands.
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < 40; i++) {
        await clk.nextPosedge;
        await sample();
      }

      // Assemble body bytes LSB-first.
      final bodyBytes = <int>[];
      for (var i = 0; i + 8 <= bodyBits.length; i += 8) {
        var v = 0;
        for (var j = 0; j < 8; j++) {
          v |= bodyBits[i + j] << j;
        }
        bodyBytes.add(v);
      }

      await Simulator.endSimulation();

      return {
        'sopCount': sopCount,
        'eopCount': eopCount,
        'busResetSeen': busResetSeen,
        'bodyBits': bodyBits,
        'bodyBytes': bodyBytes,
        'sawSopBeforeBody': sawSopBeforeBody,
      };
    }

    // Drives an arbitrary list of [dp,dm] line symbols (each held 4 clk
    // posedges) into the PHY and collects detailed framing info. Unlike
    // runPacket this does NOT append an EOP or assume any packet structure, so
    // it can drive glitches, chained packets and long-SE0 cases.
    Future<Map<String, dynamic>> runSyms(
      List<List<int>> syms, {
      int resetTicks = 120,
      int tailIdle = 40,
    }) async {
      final dut = HarborUsbFsPhyRx(
        resetTicks: resetTicks,
        name:
            'fsphys_${syms.hashCode & 0xFFFF}_${DateTime.now().microsecondsSinceEpoch & 0xFFFF}',
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final dp = Logic(name: 'dp');
      final dm = Logic(name: 'dm');

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('dp').srcConnection! <= dp;
      dut.input('dm').srcConnection! <= dm;

      await dut.build();

      reset.inject(1);
      dp.inject(1);
      dm.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      for (var i = 0; i < 16; i++) {
        await clk.nextPosedge;
      }

      var sopCount = 0;
      var eopCount = 0;
      var busResetSeen = 0;
      // Body bits collected per active-region (resets to a new list each sop),
      // so chained packets keep their bodies separate.
      final perPacketBits = <List<int>>[];
      List<int>? curBits;
      var activeEverDropped = 0;
      var prevActive = 0;

      Future<void> sample() async {
        final sop = dut.output('sop').value.toInt() == 1;
        final eop = dut.output('eop').value.toInt() == 1;
        if (sop) {
          sopCount++;
          curBits = <int>[];
          perPacketBits.add(curBits!);
        }
        if (eop) eopCount++;
        if (dut.output('bus_reset').value.toInt() == 1) busResetSeen++;
        final active = dut.output('active').value.toInt();
        if (prevActive == 1 && active == 0) activeEverDropped++;
        prevActive = active;
        final valid = dut.output('valid').value.toInt();
        if (active == 1 && valid == 1 && curBits != null) {
          curBits!.add(dut.output('data').value.toInt());
        }
      }

      for (final s in syms) {
        for (var t = 0; t < 4; t++) {
          dp.inject(s[0]);
          dm.inject(s[1]);
          await clk.nextPosedge;
          await sample();
        }
      }
      dp.inject(1);
      dm.inject(0);
      for (var i = 0; i < tailIdle; i++) {
        await clk.nextPosedge;
        await sample();
      }

      List<int> bytesOf(List<int> bits) {
        final out = <int>[];
        for (var i = 0; i + 8 <= bits.length; i += 8) {
          var v = 0;
          for (var j = 0; j < 8; j++) {
            v |= bits[i + j] << j;
          }
          out.add(v);
        }
        return out;
      }

      await Simulator.endSimulation();

      return {
        'sopCount': sopCount,
        'eopCount': eopCount,
        'busResetSeen': busResetSeen,
        'activeDropped': activeEverDropped,
        'perPacketBits': perPacketBits,
        'perPacketBytes': perPacketBits.map((b) => bytesOf(b)).toList(),
        'finalActive': dut.output('active').value.toInt(),
      };
    }

    test('B1: isolated SE0 glitch mid-packet does not trigger EOP', () async {
      // Build a packet body, splice a single SE0 bit-time into the middle,
      // followed by a good bit so SE0s are non-consecutive, then finish a real
      // EOP. With the cumulative-counter bug the glitch + first real EOP SE0
      // would falsely fire EOP early.
      final body = [_pid(0xD), ..._token(0, 0)];
      final b = _encodeBody(body);
      final syms = <List<int>>[];
      final half = b.syms.length ~/ 2;
      syms.addAll(b.syms.sublist(0, half));
      syms.add([0, 0]); // single isolated SE0 glitch
      // Resume from the line state before the glitch (the glitch is a dropout,
      // line returns to its prior J/K), so NRZI continuity holds.
      syms.addAll(b.syms.sublist(half));
      syms.add([0, 0]); // real EOP SE0
      syms.add([0, 0]); // real EOP SE0
      syms.add([1, 0]); // J

      final r = await runSyms(syms);
      expect(r['sopCount'], equals(1), reason: 'one sop');
      expect(
        r['eopCount'],
        equals(1),
        reason: 'exactly one eop: the isolated SE0 must NOT trigger EOP',
      );
      // The full body must still decode despite the mid-packet glitch.
      expect(
        r['perPacketBytes'][0],
        equals(body),
        reason: 'full body decodes through the isolated SE0 glitch',
      );
    });

    test(
      'B1: two SE0 bit-times separated by a good bit do not trigger EOP',
      () async {
        final body = [_pid(0xD), ..._token(0, 0)];
        final b = _encodeBody(body);
        final syms = <List<int>>[];
        final third = b.syms.length ~/ 3;
        syms.addAll(b.syms.sublist(0, third));
        syms.add([0, 0]); // SE0 #1 (isolated)
        syms.add(b.syms[third]); // one good bit between
        syms.add([0, 0]); // SE0 #2 (isolated)
        syms.addAll(b.syms.sublist(third + 1));
        syms.add([0, 0]); // real EOP SE0
        syms.add([0, 0]); // real EOP SE0
        syms.add([1, 0]); // J

        final r = await runSyms(syms);
        expect(
          r['eopCount'],
          equals(1),
          reason: 'non-consecutive SE0s must not accumulate into an EOP',
        );
        expect(r['sopCount'], equals(1), reason: 'one sop');
      },
    );

    test(
      'I1: valid-pulse count equals body bit count (no stray EOP bit)',
      () async {
        // A 3-byte body = 24 body bits. With the I1 bug the first EOP SE0 leaks
        // one extra forwarded valid pulse, giving 25.
        final body = [0x55, 0xAA, 0x55];
        final r = await runPacket(body);
        // bodyBits is collected the same way runSyms does, reuse runPacket result.
        final bits = r['bodyBits'] as List<int>;
        expect(
          bits.length,
          equals(24),
          reason: 'exactly 24 valid pulses for a 24-bit body, no EOP leak',
        );
      },
    );

    // Packets separated ONLY by a spec EOP (SE0 SE0 J), no extra idle. This is
    // the minimal-separation case the review flagged: the EOP's SE0->J
    // transitions can pollute the NRZI decode reference carried into packet 2.
    test('B2: two back-to-back packets (same payload) both decode', () async {
      final body = [_pid(0x3), 0x55, 0x2A];
      // 2nd packet starts from J: the EOP terminator drives the line to J.
      final b1 = _encodeBody(body, startLine: 1);
      final b2 = _encodeBody(body, startLine: 1);
      final syms = <List<int>>[];
      syms.addAll(b1.syms);
      syms.add([0, 0]); // EOP SE0
      syms.add([0, 0]); // EOP SE0
      syms.add([1, 0]); // J (single EOP terminator, no extra idle)
      syms.addAll(b2.syms);
      syms.add([0, 0]); // EOP SE0
      syms.add([0, 0]); // EOP SE0
      syms.add([1, 0]); // J

      final r = await runSyms(syms);
      expect(r['sopCount'], equals(2), reason: 'two sop pulses');
      expect(r['eopCount'], equals(2), reason: 'two eop pulses');
      expect(
        r['perPacketBytes'][0],
        equals(body),
        reason: 'packet 1 body decodes',
      );
      expect(
        r['perPacketBytes'][1],
        equals(body),
        reason: 'packet 2 body decodes (NRZI ref must reset across boundary)',
      );
    });

    test(
      'B2: two back-to-back packets (different payloads) both decode',
      () async {
        final body1 = [_pid(0x3), 0xC3, 0x3C];
        final body2 = [_pid(0xB), 0xA5, 0x5A];
        final b1 = _encodeBody(body1);
        final b2 = _encodeBody(body2);
        final syms = <List<int>>[];
        syms.addAll(b1.syms);
        syms.addAll([
          [0, 0],
          [0, 0],
          [1, 0],
          [1, 0],
          [1, 0],
        ]);
        syms.addAll(b2.syms);
        syms.addAll([
          [0, 0],
          [0, 0],
          [1, 0],
        ]);

        final r = await runSyms(syms);
        expect(r['sopCount'], equals(2), reason: 'two sop');
        expect(r['eopCount'], equals(2), reason: 'two eop');
        expect(r['perPacketBytes'][0], equals(body1), reason: 'packet 1 body');
        expect(r['perPacketBytes'][1], equals(body2), reason: 'packet 2 body');
      },
    );

    test('B2: three back-to-back packets all decode', () async {
      final bodies = [
        [_pid(0x3), 0x12, 0x34],
        [_pid(0xB), 0x56, 0x78],
        [_pid(0x3), 0x9A, 0xBC],
      ];
      final syms = <List<int>>[];
      for (final body in bodies) {
        syms.addAll(_encodeBody(body).syms);
        syms.addAll([
          [0, 0],
          [0, 0],
          [1, 0],
          [1, 0],
          [1, 0],
        ]);
      }

      final r = await runSyms(syms);
      expect(r['sopCount'], equals(3), reason: 'three sop');
      expect(r['eopCount'], equals(3), reason: 'three eop');
      for (var i = 0; i < bodies.length; i++) {
        expect(
          r['perPacketBytes'][i],
          equals(bodies[i]),
          reason: 'packet ${i + 1} body decodes',
        );
      }
    });

    test(
      'long SE0 / bus_reset: one eop, active deasserts, bus_reset, no stuck',
      () async {
        final body = [_pid(0xD), ..._token(0, 0)];
        final b = _encodeBody(body);
        final syms = <List<int>>[];
        syms.addAll(b.syms);
        // Long SE0: well beyond the 2-bit EOP and past the (small) reset
        // threshold so bus_reset asserts too.
        for (var i = 0; i < 60; i++) {
          syms.add([0, 0]);
        }
        syms.add([1, 0]); // return to J

        // Small resetTicks so the long SE0 trips bus_reset within the drive.
        final r = await runSyms(syms, resetTicks: 8);
        expect(r['sopCount'], equals(1), reason: 'one sop');
        expect(
          r['eopCount'],
          equals(1),
          reason: 'exactly one eop even for a very long SE0 (no repeated eop)',
        );
        expect(
          r['activeDropped'],
          equals(1),
          reason: 'active deasserts exactly once',
        );
        expect(r['finalActive'], equals(0), reason: 'not stuck active');
        expect(r['busResetSeen'] > 0, isTrue, reason: 'bus_reset propagates');
        expect(r['perPacketBytes'][0], equals(body), reason: 'body decodes');
      },
    );

    test('SETUP token: sop/active/body/eop framing', () async {
      // SETUP token = PID(0xD) + addr/endp token bytes (+CRC5).
      final body = [_pid(0xD), ..._token(0, 0)];
      final r = await runPacket(body);

      // SOP pulses exactly once, before any body bit.
      expect(r['sopCount'], equals(1), reason: 'exactly one sop pulse');
      expect(r['sawSopBeforeBody'], isTrue, reason: 'sop precedes body data');
      // EOP pulses exactly once at the end.
      expect(r['eopCount'], equals(1), reason: 'exactly one eop pulse');
      // bus_reset stays low for a normal packet.
      expect(r['busResetSeen'], equals(0), reason: 'no bus_reset');
      // Body bytes equal PID + token (SYNC excluded).
      expect(
        r['bodyBytes'],
        equals(body),
        reason: 'decoded body == PID + token bytes',
      );
    });

    test('DATA0 packet: multi-byte body assembly', () async {
      const payload = [0xC3, 0x3C, 0xA5, 0x5A];
      final crc = _crc16(payload);
      final body = [
        _pid(0x3), // DATA0
        ...payload,
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ];
      final r = await runPacket(body);

      expect(r['sopCount'], equals(1), reason: 'one sop');
      expect(r['eopCount'], equals(1), reason: 'one eop');
      expect(r['busResetSeen'], equals(0), reason: 'no bus_reset');
      expect(
        r['bodyBytes'],
        equals(body),
        reason: 'PID + payload + CRC16 reassembled (SYNC excluded)',
      );
    });
  });

  group('HarborUsbFsPhyTx', () {
    // Expands a list of bytes into the raw LSB-first data-bit stream the TX
    // host interface expects (NO stuffing, NO NRZI: the TX does both).
    List<int> bitsOf(List<int> bytes) {
      final bits = <int>[];
      for (final b in bytes) {
        for (var i = 0; i < 8; i++) {
          bits.add((b >> i) & 1);
        }
      }
      return bits;
    }

    // Drives a tiny known data-bit stream and captures the per-cycle line
    // state, asserting that NRZI toggling and a stuffed forced-toggle appear.
    // This guards against a round-trip-only pass masking a TX bug.
    test(
      'low-level: NRZI toggling and a stuffed toggle appear on the wire',
      () async {
        final dut = HarborUsbFsPhyTx(name: 'tx_lowlevel');
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final data = Logic(name: 'data');
        final dataValid = Logic(name: 'data_valid');
        final eopReq = Logic(name: 'eop_req');

        dut.input('clk').srcConnection! <= clk;
        dut.input('reset').srcConnection! <= reset;
        dut.input('data').srcConnection! <= data;
        dut.input('data_valid').srcConnection! <= dataValid;
        dut.input('eop_req').srcConnection! <= eopReq;

        await dut.build();

        reset.inject(1);
        data.inject(0);
        dataValid.inject(0);
        eopReq.inject(0);
        Simulator.setMaxSimTime(200000);
        unawaited(Simulator.run());

        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        // Data stream: a 0 (toggle to K), then seven 1s (hold) which forces a
        // stuff after the sixth, then a final 0. Sample dp/dm on every posedge
        // and record one line symbol per bit time (sampled at phase==2 ish).
        final stream = [0, 1, 1, 1, 1, 1, 1, 1, 0];
        var idx = 0;

        // Per-bit-time captured line symbols (dp,dm) and oe.
        final lineSeq = <List<int>>[];

        // Host: present stream[idx] with data_valid, when ready pulses, advance.
        // After the stream, raise eop_req to terminate.
        // We capture the line symbol at the cycle just before each ready pulse
        // (the bit being driven), but simplest: sample on the cycle ready==1.
        data.inject(stream[0]);
        dataValid.inject(1);

        var guard = 0;
        var eopAsserted = false;
        while (guard < 400) {
          guard++;
          await clk.nextPosedge;
          final ready = dut.output('ready').value.toInt();
          final oe = dut.output('oe').value.toInt();
          final dp = dut.output('dp_out').value.toInt();
          final dm = dut.output('dm_out').value.toInt();
          // Record the line symbol whenever the TX is driving (oe high).
          if (oe == 1) lineSeq.add([dp, dm]);
          if (ready == 1 && oe == 1) {
            // A host bit was just consumed at this edge, advance.
            idx++;
            if (idx < stream.length) {
              data.inject(stream[idx]);
              dataValid.inject(1);
            } else {
              // Stream exhausted: drop data, request EOP.
              dataValid.inject(0);
              eopReq.inject(1);
              eopAsserted = true;
            }
          }
          // Stop once we've driven the EOP and returned to idle (oe low) after
          // having asserted eop.
          if (eopAsserted && oe == 0 && lineSeq.isNotEmpty) break;
        }

        // Collapse the per-cycle samples into per-bit-time symbols: 4 identical
        // samples per symbol while oe is high.
        final symbols = <List<int>>[];
        for (var i = 0; i < lineSeq.length; i += 4) {
          symbols.add(lineSeq[i]);
        }

        // J=[1,0], K=[0,1], SE0=[0,0].
        // Expected wire symbols for stream [0,1,1,1,1,1,1,1,0] starting from J:
        //   bit 0 -> toggle -> K
        //   bits 1..6 (1s) -> hold -> K,K,K,K,K,K
        //   STUFF (forced toggle) -> J
        //   bit 7 (1) -> hold -> J
        //   bit 8 (0) -> toggle -> K
        // then EOP: SE0, SE0, J.
        final expected = <List<int>>[
          [0, 1], // K  (bit0 = 0, toggle from J)
          [0, 1], [0, 1], [0, 1], [0, 1], [0, 1], [0, 1], // six 1s held at K
          [1, 0], // STUFF forced toggle -> J
          [1, 0], // bit7 = 1 held at J
          [0, 1], // bit8 = 0 toggle -> K
          [0, 0], [0, 0], // EOP SE0 SE0
          [1, 0], // EOP J
        ];

        expect(
          symbols.length,
          equals(expected.length),
          reason: 'one symbol per bit time incl. stuff + EOP. got=$symbols',
        );
        for (var i = 0; i < expected.length; i++) {
          expect(
            symbols[i],
            equals(expected[i]),
            reason:
                'symbol[$i] mismatch: got ${symbols[i]} want ${expected[i]}',
          );
        }

        // Explicit checks: NRZI toggle happened (bit0 J->K) and a stuffed toggle
        // (K->J between the run of 1s) appears.
        expect(symbols[0], equals([0, 1]), reason: 'NRZI: data 0 toggled J->K');
        expect(
          symbols[7],
          equals([1, 0]),
          reason: 'stuffed forced toggle K->J after six 1s',
        );

        await Simulator.endSimulation();
      },
    );

    // Wire PhyTx's line outputs into PhyRx and confirm the body bytes survive.
    Future<Map<String, dynamic>> roundTrip(List<int> body) async {
      // The host bit stream the TX serializes is SYNC (0x80) + body. The Rx
      // strips the SYNC and recovers the body.
      final hostBits = bitsOf([0x80, ...body]);

      final tx = HarborUsbFsPhyTx(name: 'rt_tx_${body.hashCode & 0xFFFF}');
      final rx = HarborUsbFsPhyRx(name: 'rt_rx_${body.hashCode & 0xFFFF}');
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final data = Logic(name: 'data');
      final dataValid = Logic(name: 'data_valid');
      final eopReq = Logic(name: 'eop_req');

      tx.input('clk').srcConnection! <= clk;
      tx.input('reset').srcConnection! <= reset;
      tx.input('data').srcConnection! <= data;
      tx.input('data_valid').srcConnection! <= dataValid;
      tx.input('eop_req').srcConnection! <= eopReq;

      rx.input('clk').srcConnection! <= clk;
      rx.input('reset').srcConnection! <= reset;
      // Line connection TX -> RX.
      rx.input('dp').srcConnection! <= tx.output('dp_out');
      rx.input('dm').srcConnection! <= tx.output('dm_out');

      await tx.build();
      await rx.build();

      reset.inject(1);
      data.inject(0);
      dataValid.inject(0);
      eopReq.inject(0);
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);

      // Let the line idle at J a few bit-times so the Rx DLL/destuff settle.
      for (var i = 0; i < 16; i++) {
        await clk.nextPosedge;
      }

      var sopCount = 0;
      var eopCount = 0;
      final bodyBits = <int>[];

      void sampleRx() {
        if (rx.output('sop').value.toInt() == 1) sopCount++;
        if (rx.output('eop').value.toInt() == 1) eopCount++;
        final active = rx.output('active').value.toInt();
        final valid = rx.output('valid').value.toInt();
        if (active == 1 && valid == 1) {
          bodyBits.add(rx.output('data').value.toInt());
        }
      }

      // Drive the host stream into the TX.
      var idx = 0;
      data.inject(hostBits[0]);
      dataValid.inject(1);

      var guard = 0;
      var eopAsserted = false;
      var doneCountdown = -1;
      while (guard < 6000) {
        guard++;
        await clk.nextPosedge;
        sampleRx();
        final ready = tx.output('ready').value.toInt();
        final oe = tx.output('oe').value.toInt();
        if (ready == 1 && oe == 1 && !eopAsserted) {
          idx++;
          if (idx < hostBits.length) {
            data.inject(hostBits[idx]);
            dataValid.inject(1);
          } else {
            dataValid.inject(0);
            eopReq.inject(1);
            eopAsserted = true;
          }
        }
        // Once the TX has finished its EOP (oe back low after eop), drain the
        // Rx pipeline for a fixed tail then stop.
        if (eopAsserted && oe == 0 && doneCountdown < 0) {
          eopReq.inject(0);
          doneCountdown = 60;
        }
        if (doneCountdown > 0) {
          doneCountdown--;
        } else if (doneCountdown == 0) {
          break;
        }
      }

      final bodyBytes = <int>[];
      for (var i = 0; i + 8 <= bodyBits.length; i += 8) {
        var v = 0;
        for (var j = 0; j < 8; j++) {
          v |= bodyBits[i + j] << j;
        }
        bodyBytes.add(v);
      }

      await Simulator.endSimulation();

      return {
        'sopCount': sopCount,
        'eopCount': eopCount,
        'bodyBits': bodyBits,
        'bodyBytes': bodyBytes,
      };
    }

    test('round-trip: SETUP-like body survives TX -> RX', () async {
      final body = [_pid(0xD), ..._token(0, 0)];
      final r = await roundTrip(body);
      expect(r['sopCount'], equals(1), reason: 'exactly one sop');
      expect(r['eopCount'], equals(1), reason: 'exactly one eop');
      expect(
        r['bodyBytes'],
        equals(body),
        reason: 'TX-serialized body round-trips through RX: $body',
      );
    });

    test(
      'round-trip: body with 0xFF forces bit-stuff and still round-trips',
      () async {
        // 0xFF gives eight consecutive 1s on the wire (after the PID), forcing
        // the TX to stuff and the RX to de-stuff. The byte must survive intact.
        final body = [_pid(0x3), 0xFF, 0x00, 0xFF];
        final r = await roundTrip(body);
        expect(r['sopCount'], equals(1), reason: 'one sop');
        expect(r['eopCount'], equals(1), reason: 'one eop');
        expect(
          r['bodyBytes'],
          equals(body),
          reason: 'stuffed 0xFF bytes round-trip intact: $body',
        );
      },
    );

    test(
      'round-trip: long run of ones (multiple stuffs) round-trips',
      () async {
        // 0xFF, 0xFF in a row => long run forcing multiple bit-stuffs.
        final body = [_pid(0x3), 0xFF, 0xFF, 0x7F];
        final r = await roundTrip(body);
        expect(r['sopCount'], equals(1), reason: 'one sop');
        expect(r['eopCount'], equals(1), reason: 'one eop');
        expect(
          r['bodyBytes'],
          equals(body),
          reason: 'multiple-stuff body round-trips: $body',
        );
      },
    );
  });

  // Task 6: full PHY + CDC-FIFO round trip across the 48 MHz <-> 12 MHz domain
  // boundary. TX + RX live in the fast 48 MHz USB domain, the recovered bytes
  // are assembled in that domain and pushed into a gray-code async FIFO whose
  // read side is clocked by the slow 12 MHz controller domain. We prove the
  // exact body byte sequence arrives on the slow read side, in order, with no
  // loss or duplication under the 4:1 rate mismatch.
  //
  // FIFO sizing: dataWidth = 9 (8 data bits + 1 spare flag bit, here driven to
  // 0 but present to model the real datapath carrying a byte plus a side-band
  // tag such as start-of-packet). depth = 8: the largest packet body driven
  // below is 6 bytes, and the 12 MHz read side drains continuously while the
  // 48 MHz write side fills, so the in-flight occupancy never approaches 8.
  // We additionally assert wr_full never blocks a byte (no dropped write).
  group('HarborUsbFsPhy CDC round-trip (48MHz -> 12MHz)', () {
    List<int> bitsOf(List<int> bytes) {
      final bits = <int>[];
      for (final b in bytes) {
        for (var i = 0; i < 8; i++) {
          bits.add((b >> i) & 1);
        }
      }
      return bits;
    }

    // Drives `body` through TX->RX in the 48 MHz domain, assembles recovered
    // bytes and pushes them into a 9-bit-wide HarborCdcFifo written on usbClk.
    // The FIFO read side is drained on sysClk (12 MHz). Returns the bytes that
    // arrived in the slow domain plus integrity counters.
    Future<Map<String, dynamic>> crossDomain(List<int> body) async {
      final hostBits = bitsOf([0x80, ...body]);

      final tx = HarborUsbFsPhyTx(name: 'cdc_tx_${body.hashCode & 0xFFFF}');
      final rx = HarborUsbFsPhyRx(name: 'cdc_rx_${body.hashCode & 0xFFFF}');
      final fifo = HarborCdcFifo(
        dataWidth: 9,
        depth: 8,
        name: 'cdc_fifo_${body.hashCode & 0xFFFF}',
      );

      // 48 MHz USB domain (period 10) and 12 MHz controller domain (period 40).
      // 40 / 10 == 4 -> the required 4:1 ratio.
      final usbClk = SimpleClockGenerator(10).clk;
      final sysClk = SimpleClockGenerator(40).clk;

      final reset = Logic(name: 'reset');
      final data = Logic(name: 'data');
      final dataValid = Logic(name: 'data_valid');
      final eopReq = Logic(name: 'eop_req');

      // FIFO write-side drivers (usb domain).
      final wrData = Logic(name: 'wr_data', width: 9);
      final wrEn = Logic(name: 'wr_en');
      // FIFO read-side driver (sys domain).
      final rdEn = Logic(name: 'rd_en');

      // TX/RX in the usb domain.
      tx.input('clk').srcConnection! <= usbClk;
      tx.input('reset').srcConnection! <= reset;
      tx.input('data').srcConnection! <= data;
      tx.input('data_valid').srcConnection! <= dataValid;
      tx.input('eop_req').srcConnection! <= eopReq;

      rx.input('clk').srcConnection! <= usbClk;
      rx.input('reset').srcConnection! <= reset;
      rx.input('dp').srcConnection! <= tx.output('dp_out');
      rx.input('dm').srcConnection! <= tx.output('dm_out');

      // FIFO: write side on usbClk, read side on sysClk.
      fifo.input('wr_clk').srcConnection! <= usbClk;
      fifo.input('wr_reset').srcConnection! <= reset;
      fifo.input('wr_data').srcConnection! <= wrData;
      fifo.input('wr_en').srcConnection! <= wrEn;
      fifo.input('rd_clk').srcConnection! <= sysClk;
      fifo.input('rd_reset').srcConnection! <= reset;
      fifo.input('rd_en').srcConnection! <= rdEn;

      await tx.build();
      await rx.build();
      await fifo.build();

      reset.inject(1);
      data.inject(0);
      dataValid.inject(0);
      eopReq.inject(0);
      wrData.inject(0);
      wrEn.inject(0);
      rdEn.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      // Hold reset across several edges of the SLOW (12 MHz) clock so both
      // domains' sync registers and pointers leave x before reset releases.
      // Releasing on a usbClk edge alone fires before the first sysClk posedge,
      // leaving the read-domain pointers/flags stuck at x for the whole run.
      for (var i = 0; i < 4; i++) {
        await sysClk.nextPosedge;
      }
      reset.inject(0);

      // Let the line idle at J so the Rx DLL/destuff settle.
      for (var i = 0; i < 16; i++) {
        await usbClk.nextPosedge;
      }

      var sopCount = 0;
      var eopCount = 0;
      var wrFullWhenPushing = 0; // times we wanted to push but FIFO was full
      final writtenBytes = <int>[]; // bytes pushed into the FIFO (write side)

      // Byte assembler state (usb domain).
      var bitAccum = 0;
      var bitCount = 0;

      // Read-side capture (sys domain).
      final readBytes = <int>[];
      var readDone = false;

      // Read-side drainer: runs on sysClk, asserts rd_en when not empty and
      // captures rd_data on the following edge (FIFO advances rd_ptr on the
      // edge where rd_en & ~rd_empty, rd_data is combinational on rd_ptr).
      Future<void> drainer() async {
        while (!readDone) {
          await sysClk.nextPosedge;
          final emptyVal = fifo.output('rd_empty').value;
          // Treat an invalid (x) empty flag as "empty" (pre-reset settling).
          final empty = emptyVal.isValid ? emptyVal.toInt() : 1;
          if (empty == 0) {
            // rd_data reflects the head entry now (combinational on rd_ptr).
            final d = fifo.output('rd_data').value;
            readBytes.add(d.isValid ? (d.toInt() & 0xFF) : 0);
            rdEn.inject(1);
          } else {
            rdEn.inject(0);
          }
        }
        rdEn.inject(0);
      }

      final drainTask = drainer();

      // Write/host side: drive the host stream into TX, assemble RX bytes,
      // push them into the FIFO. Runs on usbClk.
      var idx = 0;
      data.inject(hostBits[0]);
      dataValid.inject(1);

      var guard = 0;
      var eopAsserted = false;
      var doneCountdown = -1;
      while (guard < 8000) {
        guard++;

        await usbClk.nextPosedge;
        // A wr_en asserted at the end of the previous iteration was sampled by
        // the FIFO on the posedge just above, clear it now so each push is a
        // clean one-posedge-wide pulse.
        wrEn.inject(0);

        // Sample RX framing/body in the usb domain.
        if (rx.output('sop').value.toInt() == 1) {
          sopCount++;
          // New packet: reset the byte assembler.
          bitAccum = 0;
          bitCount = 0;
        }
        if (rx.output('eop').value.toInt() == 1) eopCount++;
        final active = rx.output('active').value.toInt();
        final valid = rx.output('valid').value.toInt();
        if (active == 1 && valid == 1) {
          final bit = rx.output('data').value.toInt() & 1;
          bitAccum |= bit << bitCount;
          bitCount++;
          if (bitCount == 8) {
            final b = bitAccum & 0xFF;
            // Push the assembled byte into the FIFO (9-bit: spare flag = 0).
            final fullVal = fifo.output('wr_full').value;
            if (fullVal.isValid && fullVal.toInt() == 1) {
              wrFullWhenPushing++;
            } else {
              wrData.inject(b);
              wrEn.inject(1);
              writtenBytes.add(b);
            }
            bitAccum = 0;
            bitCount = 0;
          }
        }

        // Host advance: gate on ready & oe.
        final ready = tx.output('ready').value.toInt();
        final oe = tx.output('oe').value.toInt();
        if (ready == 1 && oe == 1 && !eopAsserted) {
          idx++;
          if (idx < hostBits.length) {
            data.inject(hostBits[idx]);
            dataValid.inject(1);
          } else {
            dataValid.inject(0);
            eopReq.inject(1);
            eopAsserted = true;
          }
        }
        if (eopAsserted && oe == 0 && doneCountdown < 0) {
          eopReq.inject(0);
          doneCountdown = 200; // drain the FIFO into the slow domain
        }
        if (doneCountdown > 0) {
          doneCountdown--;
        } else if (doneCountdown == 0) {
          break;
        }
      }

      // Stop driving writes, let the slow drainer finish pulling remaining bytes.
      wrEn.inject(0);
      // Wait enough sysClk edges that any byte still in the FIFO is read out.
      // depth is 8, give it well over depth*4 usbClk cycles == many sysClk edges.
      for (var i = 0; i < 64; i++) {
        await usbClk.nextPosedge;
      }
      readDone = true;
      await drainTask;

      await Simulator.endSimulation();

      return {
        'sopCount': sopCount,
        'eopCount': eopCount,
        'writtenBytes': writtenBytes,
        'readBytes': readBytes,
        'wrFullWhenPushing': wrFullWhenPushing,
      };
    }

    test('single packet crosses 48->12 MHz intact, in order', () async {
      // Body includes a 0xFF to force bit-stuff/de-stuff on the wire.
      final body = [_pid(0x3), 0x55, 0xFF, 0x2A];
      final r = await crossDomain(body);

      expect(r['sopCount'], equals(1), reason: 'one sop in the usb domain');
      expect(r['eopCount'], equals(1), reason: 'one eop in the usb domain');
      // The bytes pushed into the FIFO (write side) must equal the sent body.
      expect(
        r['writtenBytes'],
        equals(body),
        reason: 'usb-domain byte assembler recovered the body: $body',
      );
      // No byte was ever dropped due to wr_full.
      expect(
        r['wrFullWhenPushing'],
        equals(0),
        reason: 'FIFO never full when pushing (depth 8 fits the burst)',
      );
      // The slow 12 MHz read side received the exact same sequence, in order.
      expect(
        r['readBytes'],
        equals(body),
        reason:
            'bytes arrive on the 12 MHz read side intact and in order: '
            '${r['readBytes']} vs $body',
      );
    });

    test(
      'larger packet (6 bytes) crosses with multiple stuffs, no loss',
      () async {
        final body = [_pid(0x3), 0xFF, 0xFF, 0x00, 0xA5, 0x7F];
        final r = await crossDomain(body);

        expect(r['sopCount'], equals(1), reason: 'one sop');
        expect(r['eopCount'], equals(1), reason: 'one eop');
        expect(
          r['writtenBytes'],
          equals(body),
          reason: 'write-side recovered body (multi-stuff): $body',
        );
        expect(
          r['wrFullWhenPushing'],
          equals(0),
          reason: 'no dropped byte: depth 8 holds a 6-byte burst',
        );
        expect(
          r['readBytes'],
          equals(body),
          reason:
              '6 bytes cross the 4:1 boundary with no loss/dup: '
              '${r['readBytes']} vs $body',
        );
      },
    );
  });
}
