import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:test/test.dart';

void main() {
  // 300 MHz DDR3 demo config: CK = 3.333 ns, 4:1 SERDES -> 13.333 ns controller.
  final t = DdrTiming.fromPs(ddr3ClkPeriodPs: 3333, serdesRatio: 4);

  group('timing-conversion functions', () {
    test('nsToCycles rounds up to controller cycles (13.333 ns)', () {
      expect(t.nsToCycles(15), 2); // 15/13.333 = 1.125 -> 2
      expect(t.nsToCycles(14.5), 2);
      expect(t.nsToCycles(11), 1); // 0.825 -> 1
    });

    test('nckToCycles rounds up over the 4:1 SERDES', () {
      expect(t.nckToCycles(16), 4);
      expect(t.nckToCycles(15), 4);
      expect(t.nckToCycles(13), 4);
    });

    test('nsToNck rounds up to DDR cycles (3.333 ns)', () {
      expect(t.nsToNck(15), 5); // 4.5 -> 5
      expect(t.nsToNck(14.875), 5);
      expect(t.nsToNck(13.875), 5);
    });

    test('nckToNs rounds up to an integer ns', () {
      expect(t.nckToNs(4), 14); // 13.332 -> 14
      expect(t.nckToNs(3), 10); // 9.999 -> 10
      expect(t.nckToNs(5), 17); // 16.665 -> 17
    });
  });

  group('command-slot assignment', () {
    test('read/write slots wrap mod 4 off CL/CWL', () {
      expect(t.readSlot, 2); // -6 mod 4
      expect(t.writeSlot, 3); // -5 mod 4
    });

    test('activate/precharge take the two remaining slots', () {
      expect(t.activateSlot, 1);
      expect(t.prechargeSlot, 0);
      // All four slots are distinct.
      final slots = {t.readSlot, t.writeSlot, t.activateSlot, t.prechargeSlot};
      expect(slots.length, 4);
    });
  });

  group('derived command-to-command delays (300 MHz)', () {
    // These are the faithful-port values for the underclocked demo config. The
    // inline "//3" style notes in ddr3_controller.v are for the rated DDR3-1600
    // bin (a faster CK needs more controller cycles); at 300 MHz they are lower.
    test('match the hand-computed find_delay outputs', () {
      expect(t.prechargeToActivateDelay, 0);
      expect(t.activateToPrechargeDelay, 2);
      expect(t.activateToWriteDelay, 0);
      expect(t.activateToReadDelay, 0);
      expect(t.readToWriteDelay, 1);
      expect(t.readToReadDelay, 0);
      expect(t.readToPrechargeDelay, 1);
      expect(t.writeToWriteDelay, 0);
      expect(t.writeToReadDelay, 3);
      expect(t.writeToPrechargeDelay, 4);
      expect(t.preRefreshDelay, 5); // writeToPrecharge + 1
    });

    test('all delays are non-negative and fit the 4-bit find_delay field', () {
      for (final d in [
        t.prechargeToActivateDelay,
        t.activateToPrechargeDelay,
        t.activateToWriteDelay,
        t.activateToReadDelay,
        t.readToWriteDelay,
        t.readToPrechargeDelay,
        t.writeToReadDelay,
        t.writeToPrechargeDelay,
      ]) {
        expect(d, inInclusiveRange(0, 15));
      }
    });
  });

  group('mode-register + density parameters', () {
    test('tRFC follows the device density', () {
      expect(t.tRfc, 160.0); // 2 Gb (MT41K128M16)
      expect(
        DdrTiming.fromPs(
          ddr3ClkPeriodPs: 3333,
          serdesRatio: 4,
          density: DdrDensity.gb4,
        ).tRfc,
        300.0,
      );
    });

    test('WRA_mode_register_value matches the JEDEC MR0 table', () {
      expect(DdrTiming.wraModeRegisterValue(4), 1); // WRA+1 = 5 -> 001
      expect(DdrTiming.wraModeRegisterValue(5), 2); // 6 -> 010
      expect(DdrTiming.wraModeRegisterValue(6), 3); // 7 -> 011
      expect(DdrTiming.wraModeRegisterValue(7), 4); // 8 -> 100
      expect(DdrTiming.wraModeRegisterValue(9), 5); // 10 -> 101
      expect(DdrTiming.wraModeRegisterValue(15), 0); // 16 -> 000
    });

    test('DQS initial tap is a quarter CK over 78.125 ps/tap', () {
      // (3333/4)/78.125 = 10.66 -> 10
      expect(t.dqsInitialOdelayTap, 10);
      expect(t.dqsInitialIdelayTap, 10);
    });

    test('a faster 333 MHz CK needs more activate-to-precharge cycles', () {
      final t333 = DdrTiming.fromPs(ddr3ClkPeriodPs: 3000, serdesRatio: 4);
      expect(t333.activateToPrechargeDelay, 3); // tRAS=35 ns -> 12 nCK
      expect(t333.prechargeToActivateDelay, 0);
    });
  });
}
