import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });
  group('HarborCdcSync', () {
    test('creates with default 2 stages', () {
      final sync = HarborCdcSync();
      expect(sync.stages, equals(2));
      expect(sync.syncOut.width, equals(1));
    });

    test('creates with custom stages', () {
      final sync = HarborCdcSync(stages: 3);
      expect(sync.stages, equals(3));
    });

    test('rejects less than 2 stages', () {
      expect(() => HarborCdcSync(stages: 1), throwsA(isA<AssertionError>()));
    });
  });

  group('HarborCdcHandshake', () {
    test('creates with default data width', () {
      final hs = HarborCdcHandshake();
      expect(hs.dataWidth, equals(32));
      expect(hs.output('src_ready').width, equals(1));
      expect(hs.output('dst_data').width, equals(32));
      expect(hs.output('dst_valid').width, equals(1));
    });

    test('creates with custom width', () {
      final hs = HarborCdcHandshake(dataWidth: 64);
      expect(hs.dataWidth, equals(64));
      expect(hs.output('dst_data').width, equals(64));
    });
  });

  group('HarborCdcFifo', () {
    test('creates with default config', () {
      final fifo = HarborCdcFifo();
      expect(fifo.dataWidth, equals(32));
      expect(fifo.depth, equals(8));
      expect(fifo.output('wr_full').width, equals(1));
      expect(fifo.output('rd_empty').width, equals(1));
      expect(fifo.output('rd_data').width, equals(32));
    });

    test('custom depth and width', () {
      final fifo = HarborCdcFifo(dataWidth: 64, depth: 16);
      expect(fifo.dataWidth, equals(64));
      expect(fifo.depth, equals(16));
    });

    test('rejects non-power-of-2 depth', () {
      expect(() => HarborCdcFifo(depth: 7), throwsA(isA<AssertionError>()));
    });

    test('rejects depth=1', () {
      expect(() => HarborCdcFifo(depth: 1), throwsA(isA<AssertionError>()));
    });

    test('accepts depth=2', () {
      final fifo = HarborCdcFifo(dataWidth: 8, depth: 2);
      expect(fifo.depth, equals(2));
    });
  });

  group('HarborCdcFifo functional', () {
    // Helper: build and wire a FIFO with a shared clock for both domains.
    // Returns a record with the built FIFO and all driving Logics.
    Future<
      ({
        HarborCdcFifo fifo,
        Logic clk,
        Logic reset,
        Logic wrData,
        Logic wrEn,
        Logic rdEn,
      })
    >
    buildSameClock({int dataWidth = 8, int depth = 4}) async {
      final fifo = HarborCdcFifo(
        dataWidth: dataWidth,
        depth: depth,
        name: 'fifo_sc',
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset_sc');
      final wrData = Logic(name: 'wr_data_sc', width: dataWidth);
      final wrEn = Logic(name: 'wr_en_sc');
      final rdEn = Logic(name: 'rd_en_sc');

      fifo.input('wr_clk').srcConnection! <= clk;
      fifo.input('wr_reset').srcConnection! <= reset;
      fifo.input('wr_data').srcConnection! <= wrData;
      fifo.input('wr_en').srcConnection! <= wrEn;
      fifo.input('rd_clk').srcConnection! <= clk;
      fifo.input('rd_reset').srcConnection! <= reset;
      fifo.input('rd_en').srcConnection! <= rdEn;

      await fifo.build();
      return (
        fifo: fifo,
        clk: clk,
        reset: reset,
        wrData: wrData,
        wrEn: wrEn,
        rdEn: rdEn,
      );
    }

    // (a) Same-clock sanity: write a known byte sequence, read it back,
    //     assert order preserved, no loss, no duplication.
    test('(a) same-clock write-read preserves order', () async {
      final r = await buildSameClock();
      final fifo = r.fifo;
      final clk = r.clk;

      r.reset.inject(1);
      r.wrData.inject(0);
      r.wrEn.inject(0);
      r.rdEn.inject(0);
      Simulator.setMaxSimTime(50000);
      unawaited(Simulator.run());

      // Hold reset for 3 posedges so both sync chains clear.
      for (var i = 0; i < 3; i++) {
        await clk.nextPosedge;
      }
      r.reset.inject(0);
      await clk.nextPosedge;

      // Write bytes 0xAA, 0xBB, 0xCC one per cycle.
      final toWrite = [0xAA, 0xBB, 0xCC];
      for (final b in toWrite) {
        r.wrData.inject(b);
        r.wrEn.inject(1);
        await clk.nextPosedge;
        r.wrEn.inject(0);
      }

      // Allow two extra cycles for the gray-code sync pipeline (2 stages).
      for (var i = 0; i < 2; i++) {
        await clk.nextPosedge;
      }

      // Drain and capture.
      final readBytes = <int>[];
      for (var i = 0; i < toWrite.length; i++) {
        final emptyVal = fifo.output('rd_empty').value;
        expect(emptyVal.isValid, isTrue, reason: 'rd_empty valid at read $i');
        expect(
          emptyVal.toInt(),
          equals(0),
          reason: 'FIFO not empty at read $i',
        );

        final d = fifo.output('rd_data').value;
        expect(d.isValid, isTrue, reason: 'rd_data valid at read $i');
        readBytes.add(d.toInt());

        r.rdEn.inject(1);
        await clk.nextPosedge;
        r.rdEn.inject(0);
        // One extra cycle for the sync pipeline to propagate rd_ptr gray.
        await clk.nextPosedge;
      }

      expect(readBytes, equals(toWrite), reason: 'sequence preserved');

      // FIFO must be empty now.
      await clk.nextPosedge;
      expect(
        fifo.output('rd_empty').value.toInt(),
        equals(1),
        reason: 'rd_empty after drain',
      );

      await Simulator.endSimulation();
    });

    // (b) Fill-to-FULL then drain: write depth entries, assert wr_full asserts
    //     at exactly depth entries, drain all, assert every value in order and
    //     rd_empty reasserts.
    test('(b) fill-to-full then drain', () async {
      final r = await buildSameClock(depth: 4);
      final fifo = r.fifo;
      final clk = r.clk;

      r.reset.inject(1);
      r.wrData.inject(0);
      r.wrEn.inject(0);
      r.rdEn.inject(0);
      Simulator.setMaxSimTime(50000);
      unawaited(Simulator.run());

      for (var i = 0; i < 3; i++) {
        await clk.nextPosedge;
      }
      r.reset.inject(0);
      await clk.nextPosedge;

      // Write depth (4) entries: values 0x01..0x04.
      const depth = 4;
      final toWrite = List.generate(depth, (i) => i + 1);
      for (final b in toWrite) {
        final fullVal = fifo.output('wr_full').value;
        // Must not be full before we have written all depth entries.
        if (fullVal.isValid) {
          expect(
            fullVal.toInt(),
            equals(0),
            reason: 'FIFO must not be full before depth entries written',
          );
        }
        r.wrData.inject(b);
        r.wrEn.inject(1);
        await clk.nextPosedge;
        r.wrEn.inject(0);
      }

      // Wait for wr_full to assert (sync pipeline needs up to 2 cycles).
      var fullSeen = false;
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
        final fv = fifo.output('wr_full').value;
        if (fv.isValid && fv.toInt() == 1) {
          fullSeen = true;
          break;
        }
      }
      expect(
        fullSeen,
        isTrue,
        reason: 'wr_full must assert after depth writes',
      );

      // A push while full must be rejected: pointer must not advance.
      r.wrData.inject(0xFF);
      r.wrEn.inject(1);
      await clk.nextPosedge;
      r.wrEn.inject(0);

      // Allow sync to settle.
      for (var i = 0; i < 2; i++) {
        await clk.nextPosedge;
      }

      // Drain all depth entries.
      final readBytes = <int>[];
      for (var i = 0; i < depth; i++) {
        final emptyVal = fifo.output('rd_empty').value;
        expect(emptyVal.isValid, isTrue, reason: 'rd_empty valid at drain $i');
        expect(
          emptyVal.toInt(),
          equals(0),
          reason: 'FIFO has data at drain $i',
        );

        final d = fifo.output('rd_data').value;
        expect(d.isValid, isTrue, reason: 'rd_data valid at drain $i');
        readBytes.add(d.toInt());

        r.rdEn.inject(1);
        await clk.nextPosedge;
        r.rdEn.inject(0);
        for (var s = 0; s < 2; s++) {
          await clk.nextPosedge;
        }
      }

      expect(
        readBytes,
        equals(toWrite),
        reason: 'drained values match written values in order',
      );

      // Must be empty now.
      expect(
        fifo.output('rd_empty').value.toInt(),
        equals(1),
        reason: 'rd_empty reasserts after full drain',
      );

      await Simulator.endSimulation();
    });

    // (c) Two-clock crossing: wr_clk from SimpleClockGenerator(10) (fast),
    //     rd_clk from SimpleClockGenerator(40) (slow, 4:1). Write a multi-byte
    //     sequence on the fast clock, drain on the slow clock, assert the slow-
    //     domain sequence equals what was written, in order, no loss/dup.
    //     Reset is held across several SLOW-clock posedges before release.
    test('(c) two-clock crossing 4:1', () async {
      final fifo = HarborCdcFifo(dataWidth: 8, depth: 4, name: 'fifo_2clk');
      final wrClk = SimpleClockGenerator(10).clk;
      final rdClk = SimpleClockGenerator(40).clk;
      final reset = Logic(name: 'reset_2c');
      final wrData = Logic(name: 'wr_data_2c', width: 8);
      final wrEn = Logic(name: 'wr_en_2c');
      final rdEn = Logic(name: 'rd_en_2c');

      fifo.input('wr_clk').srcConnection! <= wrClk;
      fifo.input('wr_reset').srcConnection! <= reset;
      fifo.input('wr_data').srcConnection! <= wrData;
      fifo.input('wr_en').srcConnection! <= wrEn;
      fifo.input('rd_clk').srcConnection! <= rdClk;
      fifo.input('rd_reset').srcConnection! <= reset;
      fifo.input('rd_en').srcConnection! <= rdEn;

      await fifo.build();

      reset.inject(1);
      wrData.inject(0);
      wrEn.inject(0);
      rdEn.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());

      // Hold reset across several SLOW-clock posedges so both sync chains
      // (which run on rdClk) leave x before release.
      for (var i = 0; i < 4; i++) {
        await rdClk.nextPosedge;
      }
      reset.inject(0);

      // Let both clocks settle for a couple of their own posedges.
      for (var i = 0; i < 2; i++) {
        await wrClk.nextPosedge;
      }

      // Write four bytes on the fast (wr) clock.
      final toWrite = [0x11, 0x22, 0x33, 0x44];
      for (final b in toWrite) {
        wrData.inject(b);
        wrEn.inject(1);
        await wrClk.nextPosedge;
        wrEn.inject(0);
      }

      // Drain on the slow (rd) clock.
      final readBytes = <int>[];
      var guard = 0;
      while (readBytes.length < toWrite.length && guard < 200) {
        guard++;
        await rdClk.nextPosedge;
        final emptyVal = fifo.output('rd_empty').value;
        final empty = emptyVal.isValid ? emptyVal.toInt() : 1;
        if (empty == 0) {
          final d = fifo.output('rd_data').value;
          readBytes.add(d.isValid ? d.toInt() : 0);
          rdEn.inject(1);
        } else {
          rdEn.inject(0);
        }
        // Clear rdEn on the next posedge so each read is a one-cycle pulse.
        await rdClk.nextPosedge;
        rdEn.inject(0);
      }

      expect(
        readBytes.length,
        equals(toWrite.length),
        reason: 'all bytes crossed without loss or duplication',
      );
      expect(
        readBytes,
        equals(toWrite),
        reason: 'bytes arrive in order on slow clock',
      );

      await Simulator.endSimulation();
    });
  });

  group('HarborClockGate', () {
    test('creates with correct ports', () {
      final gate = HarborClockGate();
      expect(gate.gatedClk.width, equals(1));
      expect(gate.input('enable').width, equals(1));
      expect(gate.input('test_enable').width, equals(1));
    });
  });
}
