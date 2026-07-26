import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('HarborClockRate', () {
    test('HarborFixedClockRate', () {
      const rate = HarborFixedClockRate(48000000);
      expect(rate.frequency, equals(48000000));
      expect(rate.toString(), contains('48.0 MHz'));
    });

    test('HarborDynamicClockRate', () {
      const rate = HarborDynamicClockRate(
        minFrequency: 24000000,
        maxFrequency: 96000000,
        nominalFrequency: 48000000,
        steps: [36000000, 48000000, 72000000],
      );
      expect(rate.minFrequency, equals(24000000));
      expect(rate.maxFrequency, equals(96000000));
      expect(rate.nominalFrequency, equals(48000000));
      expect(rate.allFrequencies, hasLength(5));
    });

    test('sealed exhaustiveness', () {
      const HarborClockRate rate = HarborFixedClockRate(100000000);
      final desc = switch (rate) {
        HarborFixedClockRate(:final frequency) => 'fixed $frequency',
        HarborDynamicClockRate(:final nominalFrequency) =>
          'dynamic $nominalFrequency',
      };
      expect(desc, equals('fixed 100000000'));
    });
  });

  group('HarborClockConfig', () {
    test('fixed frequency', () {
      const config = HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(48000000),
      );
      expect(config.frequency, equals(48000000));
      expect(config.isDynamic, isFalse);
      expect(config.periodNs, closeTo(20.83, 0.01));
      expect(config.frequencyMhz, closeTo(48.0, 0.1));
    });

    test('dynamic frequency', () {
      const config = HarborClockConfig(
        name: 'cpu',
        rate: HarborDynamicClockRate(
          minFrequency: 400000000,
          maxFrequency: 1200000000,
          nominalFrequency: 800000000,
        ),
      );
      expect(config.frequency, equals(800000000)); // nominal
      expect(config.isDynamic, isTrue);
    });

    test('primary clock', () {
      const config = HarborClockConfig(
        name: 'osc',
        rate: HarborFixedClockRate(12000000),
        isPrimary: true,
      );
      expect(config.isPrimary, isTrue);
    });

    test('toPrettyString', () {
      const config = HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(48000000),
        sourceFrequency: 12000000,
      );
      final pretty = config.toPrettyString();
      expect(pretty, contains('name: sys'));
      expect(pretty, contains('source: 12000000'));
    });
  });

  group('HarborClockDomain', () {
    test('fixed domain', () {
      final domain = HarborClockDomain(
        config: const HarborClockConfig(
          name: 'sys',
          rate: HarborFixedClockRate(48000000),
        ),
        clk: Logic(),
        reset: Logic(),
      );
      expect(domain.name, equals('sys'));
      expect(domain.frequency, equals(48000000));
      expect(domain.isDynamic, isFalse);
      expect(domain.frequencySelect, isNull);
    });

    test('dynamic domain', () {
      final domain = HarborClockDomain(
        config: const HarborClockConfig(
          name: 'cpu',
          rate: HarborDynamicClockRate(
            minFrequency: 400000000,
            maxFrequency: 1200000000,
            nominalFrequency: 800000000,
          ),
        ),
        clk: Logic(),
        reset: Logic(),
        frequencySelect: Logic(width: 4),
      );
      expect(domain.isDynamic, isTrue);
      expect(domain.frequencySelect, isNotNull);
      expect(domain.frequencySelect!.width, equals(4));
    });
  });

  group('HarborClockGenerator', () {
    test('PLL divider calculation', () {
      final (divr, divf, divq) = HarborClockGenerator.calculateDividers(
        12000000, // 12 MHz input
        48000000, // 48 MHz output
      );
      // Verify the calculated output is close to target
      final actual = (12000000 * (divf + 1)) ~/ ((divr + 1) * (1 << divq));
      expect((actual - 48000000).abs(), lessThan(1000000)); // within 1 MHz
    });

    test('ECP5 PLL divides 48 MHz down to 24 MHz with an in-range VCO', () {
      // The OrangeCrab feeds a 48 MHz oscillator. A 24 MHz core clock needs the
      // PLL to divide DOWN (CLKI_DIV = 2). The old code hardcoded CLKI_DIV = 1
      // and produced a 1:1 PLL (CLKOP = 48 MHz, VCO = 1584 MHz, never locks).
      final d = HarborClockGenerator.ecp5PllDividers(48000000, 24000000);
      // fCLKOP = sourceFreq * CLKFB_DIV / CLKI_DIV must equal the target.
      expect(48000000 * d.clkfbDiv / d.clkiDiv, equals(24000000));
      // fVCO = fCLKOP * CLKOP_DIV must land in the ECP5 400-800 MHz band.
      final vco = 24000000 * d.clkopDiv;
      expect(vco, inInclusiveRange(400000000, 800000000));
    });

    test('ECP5 PLL multiplies 12 MHz up to 48 MHz with an in-range VCO', () {
      final d = HarborClockGenerator.ecp5PllDividers(12000000, 48000000);
      expect(12000000 * d.clkfbDiv / d.clkiDiv, equals(48000000));
      final vco = 48000000 * d.clkopDiv;
      expect(vco, inInclusiveRange(400000000, 800000000));
    });
  });
}
