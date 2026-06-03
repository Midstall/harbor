import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../soc/target.dart';
import '../blackbox/ice40/ice40.dart';
import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../util/pretty_string.dart';

/// Configuration for a clock domain.
///
/// Describes the desired frequency and relationship to a source
/// clock. Used by [HarborClockGenerator] to select the appropriate PLL
/// primitive for the target device.
/// Clock rate mode.
sealed class HarborClockRate {
  const HarborClockRate();
}

/// Fixed clock rate - single frequency, no dynamic scaling.
class HarborFixedClockRate extends HarborClockRate {
  /// Frequency in Hz.
  final int frequency;

  const HarborFixedClockRate(this.frequency);

  @override
  String toString() => '${(frequency / 1e6).toStringAsFixed(1)} MHz';
}

/// Dynamic clock rate - supports frequency scaling between min and max.
///
/// Used for DVFS (Dynamic Voltage and Frequency Scaling) / turbo mode.
/// The PLL must support runtime reconfiguration, or multiple PLLs
/// with clock muxing are used.
class HarborDynamicClockRate extends HarborClockRate {
  /// Minimum frequency in Hz (power-saving mode).
  final int minFrequency;

  /// Maximum frequency in Hz (turbo/boost mode).
  final int maxFrequency;

  /// Default/nominal frequency in Hz.
  final int nominalFrequency;

  /// Frequency steps available between min and max.
  /// Empty means continuously variable (PLL-dependent).
  final List<int> steps;

  const HarborDynamicClockRate({
    required this.minFrequency,
    required this.maxFrequency,
    required this.nominalFrequency,
    this.steps = const [],
  });

  /// All available frequencies (min, steps, max).
  List<int> get allFrequencies {
    if (steps.isEmpty) return [minFrequency, nominalFrequency, maxFrequency];
    return [minFrequency, ...steps, maxFrequency];
  }

  @override
  String toString() =>
      '${(minFrequency / 1e6).toStringAsFixed(0)}-'
      '${(maxFrequency / 1e6).toStringAsFixed(0)} MHz '
      '(nom ${(nominalFrequency / 1e6).toStringAsFixed(0)} MHz)';
}

/// Configuration for a clock domain.
///
/// Describes the desired frequency (fixed or dynamic) and relationship
/// to a source clock. Used by [HarborClockGenerator] to select the appropriate
/// PLL primitive for the target device.
class HarborClockConfig with HarborPrettyString {
  /// Human-readable name for this clock domain.
  final String name;

  /// Clock rate - fixed or dynamic.
  final HarborClockRate rate;

  /// Source clock frequency in Hz (input to PLL).
  final int? sourceFrequency;

  /// Whether this is the primary clock (not derived from a PLL).
  final bool isPrimary;

  const HarborClockConfig({
    required this.name,
    required this.rate,
    this.sourceFrequency,
    this.isPrimary = false,
  });

  /// Convenience factory for fixed-frequency clocks.
  static HarborClockConfig fixed({
    required String name,
    required int frequency,
    int? sourceFrequency,
    bool isPrimary = false,
  }) => HarborClockConfig(
    name: name,
    rate: HarborFixedClockRate(frequency),
    sourceFrequency: sourceFrequency,
    isPrimary: isPrimary,
  );

  /// Convenience factory for dynamic-frequency clocks.
  static HarborClockConfig dynamic_({
    required String name,
    required int minFrequency,
    required int maxFrequency,
    required int nominalFrequency,
    List<int> steps = const [],
    int? sourceFrequency,
    bool isPrimary = false,
  }) => HarborClockConfig(
    name: name,
    rate: HarborDynamicClockRate(
      minFrequency: minFrequency,
      maxFrequency: maxFrequency,
      nominalFrequency: nominalFrequency,
      steps: steps,
    ),
    sourceFrequency: sourceFrequency,
    isPrimary: isPrimary,
  );

  /// The nominal/default frequency in Hz.
  int get frequency => switch (rate) {
    HarborFixedClockRate(:final frequency) => frequency,
    HarborDynamicClockRate(:final nominalFrequency) => nominalFrequency,
  };

  /// Whether this clock supports dynamic frequency scaling.
  bool get isDynamic => rate is HarborDynamicClockRate;

  /// Period in nanoseconds at nominal frequency.
  double get periodNs => 1e9 / frequency;

  /// Frequency in MHz at nominal frequency.
  double get frequencyMhz => frequency / 1e6;

  @override
  String toString() =>
      'HarborClockConfig($name, ${frequencyMhz.toStringAsFixed(1)} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborClockConfig(\n');
    buf.writeln('${c}name: $name,');
    buf.writeln('${c}rate: $rate,');
    if (sourceFrequency != null) {
      buf.writeln('${c}source: $sourceFrequency Hz,');
    }
    if (isPrimary) buf.writeln('${c}primary,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// A resolved clock domain with actual Logic signals.
///
/// Created by [HarborClockGenerator] after selecting the appropriate
/// PLL for the target.
class HarborClockDomain {
  /// The configuration this domain was created from.
  final HarborClockConfig config;

  /// The clock signal.
  final Logic clk;

  /// The reset signal (active high).
  final Logic reset;

  /// Whether the PLL has locked (null if no PLL used).
  final Logic? locked;

  /// Frequency select input for dynamic clocking.
  ///
  /// Only present when [HarborClockConfig.isDynamic] is true. Write to this
  /// signal to change the operating frequency at runtime.
  /// The encoding is target-specific (e.g., PLL divider values).
  final Logic? frequencySelect;

  const HarborClockDomain({
    required this.config,
    required this.clk,
    required this.reset,
    this.locked,
    this.frequencySelect,
  });

  /// The domain name.
  String get name => config.name;

  /// The nominal frequency in Hz.
  int get frequency => config.frequency;

  /// Whether this domain supports dynamic frequency scaling.
  bool get isDynamic => config.isDynamic;
}

/// Generates clock domains using target-appropriate PLL primitives.
///
/// For primary clocks (no PLL needed), passes through the input.
/// For derived clocks, instantiates the correct PLL blackbox based
/// on the [HarborDeviceTarget].
///
/// ```dart
/// final gen = HarborClockGenerator(
///   parent: soc,
///   inputClk: soc.port('clk').port,
///   inputReset: soc.port('reset').port,
///   target: HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48'),
/// );
///
/// final sysDomain = gen.createDomain(HarborClockConfig(
///   name: 'sys',
///   frequency: 48000000,
///   sourceFrequency: 12000000,
/// ));
///
/// // sysDomain.clk is now driven by an SB_PLL40_CORE
/// ```
class HarborClockGenerator {
  /// Parent module to add PLL submodules into.
  final BridgeModule parent;

  /// Input clock signal.
  final Logic inputClk;

  /// Input reset signal.
  final Logic inputReset;

  /// The target device (determines which PLL primitive to use).
  final HarborDeviceTarget? target;

  final List<HarborClockDomain> _domains = [];

  HarborClockGenerator({
    required this.parent,
    required this.inputClk,
    required this.inputReset,
    this.target,
  });

  /// All created clock domains.
  List<HarborClockDomain> get domains => List.unmodifiable(_domains);

  /// Creates a clock domain.
  ///
  /// If [HarborClockConfig.isPrimary] is true, passes through the input clock.
  /// Otherwise, instantiates a PLL for the target device.
  HarborClockDomain createDomain(HarborClockConfig config) {
    if (config.isPrimary) {
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: inputReset,
      );
      _domains.add(domain);
      return domain;
    }

    final sourceFreq = config.sourceFrequency;
    if (sourceFreq == null) {
      throw ArgumentError(
        'Non-primary clock "${config.name}" requires sourceFrequency',
      );
    }

    // No frequency change: pass the source clock through directly. A 1:1 PLL
    // is pointless, costs a hard PLL block, and on iCE40 conflicts with placing
    // the clock-input pad.
    if (config.frequency == sourceFreq) {
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: inputReset,
      );
      _domains.add(domain);
      return domain;
    }

    final t = target;
    if (t == null) {
      // No target - just pass through (simulation mode)
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: inputReset,
      );
      _domains.add(domain);
      return domain;
    }

    switch (t) {
      case HarborFpgaTarget():
        return _createFpgaPll(config, sourceFreq, t);
      case HarborAsicTarget():
        return _createAsicPll(config, sourceFreq);
    }
  }

  HarborClockDomain _createFpgaPll(
    HarborClockConfig config,
    int sourceFreq,
    HarborFpgaTarget fpga,
  ) {
    switch (fpga.vendor) {
      case HarborFpgaVendor.ice40:
        return _createIce40Pll(config, sourceFreq);
      case HarborFpgaVendor.ecp5:
        return _createEcp5Pll(config, sourceFreq);
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return _createXilinxPll(config, sourceFreq);
    }
  }

  HarborClockDomain _createIce40Pll(HarborClockConfig config, int sourceFreq) {
    // Calculate PLL dividers
    // fout = (fin * (DIVF + 1)) / ((DIVR + 1) * (1 << DIVQ))
    final (divr, divf, divq) = calculateDividers(
      sourceFreq,
      config.frequency,
      maxDivr: 15,
      maxDivf: 127,
      maxDivq: 7,
    );

    final pll = parent.addSubModule(
      Ice40SbPll40Core(
        divr: divr,
        divf: divf,
        divq: divq,
        filterRange: ice40FilterRange(sourceFreq ~/ (divr + 1)),
        name: '${config.name}_pll',
      ),
    );

    pll.input('REFERENCECLK').srcConnection! <= inputClk;
    pll.input('RESETB').srcConnection! <= Const(1);
    pll.input('BYPASS').srcConnection! <= Const(0);

    final pllClk = pll.output('PLLOUTGLOBAL');
    final pllLock = pll.output('LOCK');

    // Reset is active until PLL locks
    final domain = HarborClockDomain(
      config: config,
      clk: pllClk,
      reset: inputReset | ~pllLock,
      locked: pllLock,
    );
    _domains.add(domain);
    return domain;
  }

  HarborClockDomain _createEcp5Pll(HarborClockConfig config, int sourceFreq) {
    final ratio = config.frequency / sourceFreq;
    final clkfbDiv = (ratio * 1).round().clamp(1, 128);
    final clkiDiv = 1;
    final clkopDiv = (800000000 ~/ config.frequency).clamp(1, 128);

    // Self-feedback: CLKFB driven by CLKOP
    final feedback = Logic(name: '${config.name}_pll_fb');

    final pll = Ecp5Ehxplll(
      clkiDiv: clkiDiv,
      clkfbDiv: clkfbDiv,
      clkopDiv: clkopDiv,
      clk: inputClk,
      clkfb: feedback,
      name: '${config.name}_pll',
    );

    feedback <= pll.output('CLKOP');

    final domain = HarborClockDomain(
      config: config,
      clk: pll.output('CLKOP'),
      reset: inputReset | ~pll.output('LOCK'),
      locked: pll.output('LOCK'),
    );
    _domains.add(domain);
    return domain;
  }

  HarborClockDomain _createXilinxPll(HarborClockConfig config, int sourceFreq) {
    final periodNs = 1e9 / sourceFreq;
    final ratio = config.frequency / sourceFreq;
    // MMCM: fout = fin * CLKFBOUT_MULT / (DIVCLK_DIVIDE * CLKOUTn_DIVIDE)
    final mult = (ratio * 10).round().clamp(2, 64).toDouble();
    final outDiv = 10.0;
    final divClk = 1.0;

    final mmcm = parent.addSubModule(
      XilinxMmcme2Adv(
        clkfboutMult: mult,
        clkout0Divide: outDiv,
        divclkDivide: divClk,
        clkinPeriod: periodNs,
        name: '${config.name}_mmcm',
      ),
    );

    mmcm.input('CLKIN1').srcConnection! <= inputClk;
    mmcm.input('CLKIN2').srcConnection! <= Const(0);
    mmcm.input('CLKINSEL').srcConnection! <= Const(1);
    mmcm.input('CLKFBIN').srcConnection! <= mmcm.output('CLKFBOUT');
    mmcm.input('RST').srcConnection! <= Const(0);
    mmcm.input('PWRDWN').srcConnection! <= Const(0);

    final bufg = parent.addSubModule(XilinxBufg(name: '${config.name}_bufg'));
    bufg.input('I').srcConnection! <= mmcm.output('CLKOUT0');

    final domain = HarborClockDomain(
      config: config,
      clk: bufg.output('O'),
      reset: inputReset | ~mmcm.output('LOCKED'),
      locked: mmcm.output('LOCKED'),
    );
    _domains.add(domain);
    return domain;
  }

  HarborClockDomain _createAsicPll(HarborClockConfig config, int sourceFreq) {
    // ASIC: no specific PLL primitive, just pass through
    // The actual PLL would be an analog block from the PDK
    final domain = HarborClockDomain(
      config: config,
      clk: inputClk,
      reset: inputReset,
    );
    _domains.add(domain);
    return domain;
  }

  /// Calculates PLL dividers for a target frequency.
  ///
  /// Returns (DIVR, DIVF, DIVQ) such that:
  /// fout = (fin * (DIVF + 1)) / ((DIVR + 1) * (1 << DIVQ))
  static (int, int, int) calculateDividers(
    int fin,
    int fout, {
    int maxDivr = 15,
    int maxDivf = 127,
    int maxDivq = 7,
  }) {
    var bestDivr = 0;
    var bestDivf = 0;
    var bestDivq = 0;
    var bestError = double.infinity;

    for (var divr = 0; divr <= maxDivr; divr++) {
      for (var divq = 0; divq <= maxDivq; divq++) {
        final divf = ((fout * (divr + 1) * (1 << divq)) / fin - 1).round();
        if (divf < 0 || divf > maxDivf) continue;

        final actual = (fin * (divf + 1)) ~/ ((divr + 1) * (1 << divq));
        final error = (actual - fout).abs().toDouble();
        if (error < bestError) {
          bestError = error;
          bestDivr = divr;
          bestDivf = divf;
          bestDivq = divq;
        }
      }
    }

    return (bestDivr, bestDivf, bestDivq);
  }

  static int ice40FilterRange(int pfdFreq) {
    if (pfdFreq < 17000000) return 1;
    if (pfdFreq < 26000000) return 2;
    if (pfdFreq < 44000000) return 3;
    if (pfdFreq < 66000000) return 4;
    if (pfdFreq < 101000000) return 5;
    return 6;
  }
}
