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

/// Fixed clock rate: single frequency, no dynamic scaling.
class HarborFixedClockRate extends HarborClockRate {
  /// Frequency in Hz.
  final int frequency;

  const HarborFixedClockRate(this.frequency);

  @override
  String toString() => '${(frequency / 1e6).toStringAsFixed(1)} MHz';
}

/// Dynamic clock rate: supports frequency scaling between min and max.
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

  /// Clock rate: fixed or dynamic.
  final HarborClockRate rate;

  /// Source clock frequency in Hz (input to PLL).
  final int? sourceFrequency;

  /// Whether this is the primary clock (not derived from a PLL).
  final bool isPrimary;

  /// Force a real PLL even when [frequency] equals [sourceFrequency].
  ///
  /// Normally a 1:1 ratio short-circuits to the raw input clock (a 1:1 PLL is
  /// pointless and costs a hard PLL block). But an ECP5 DDR PHY needs its edge
  /// clock (ECLK) to come from a PLL output (CLKOP): nextpnr only assigns the
  /// dedicated ECLK network to a PLL/clock-tree source, not a raw I/O pad, so a
  /// raw-pad-fed ECLKSYNCB fails to route ("no route found" for the edge-clock
  /// source). Setting this on the same-rate DDR domain makes the generator emit
  /// a CLKOP at the source rate on a real clock network, the litex ECP5DDRPHY
  /// structure. Ignored when [isPrimary].
  final bool forcePll;

  /// Optional CLKOS secondary clock derived from the SAME PLL as this domain.
  ///
  /// When set, this domain is the PLL primary (CLKOP) and the named secondary
  /// is a CLKOS output off the SAME VCO, sharing one EHXPLLL and one LOCK. This
  /// exists because a SECOND EHXPLLL on the ECP5 may not lock on silicon (the
  /// 2nd PLL site's clock-input routing): collapsing two related clocks (e.g. a
  /// 144 MHz DDR CK and a 24 MHz core) into one PLL avoids that failure. The
  /// VCO is `frequency * CLKOP_DIV` and must be an integer multiple of the
  /// secondary frequency (e.g. 144*4 = 576 MHz, 576/24 = 24). The generator
  /// emits both domains, see [HarborClockGenerator.createDomainWithSecondary].
  final ({String name, int frequency})? coClkosSecondary;

  /// Run this domain off the shared Xilinx DDR3-fast clock tree's spare core
  /// CLKOUT instead of a dedicated PLL/MMCM. On a single-oscillator board (Arty
  /// S7) a second MMCM on the raw clock pin cannot share the pin's one dedicated
  /// clock-capable route, so the core clock is folded onto a spare output of the
  /// DDR MMCM. When set, [HarborSoC] must be built with an `xilinxDdr3Tree` spec.
  /// The domain is then clocked by that tree's `coreClk`. Ignored otherwise.
  final bool providedByDdr3Tree;

  const HarborClockConfig({
    required this.name,
    required this.rate,
    this.sourceFrequency,
    this.isPrimary = false,
    this.forcePll = false,
    this.coClkosSecondary,
    this.providedByDdr3Tree = false,
  });

  /// Convenience factory for fixed-frequency clocks.
  static HarborClockConfig fixed({
    required String name,
    required int frequency,
    int? sourceFrequency,
    bool isPrimary = false,
    bool forcePll = false,
  }) => HarborClockConfig(
    name: name,
    rate: HarborFixedClockRate(frequency),
    sourceFrequency: sourceFrequency,
    isPrimary: isPrimary,
    forcePll: forcePll,
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

  /// Top-level input port this domain is driven by under [HarborSimTarget],
  /// or null when it has none.
  ///
  /// A simulation has no PLL, so a derived domain becomes its own input clock
  /// for the harness to drive. A domain that already runs at the source rate
  /// is the source clock, with NO port of its own; a harness that assumed one
  /// would bind a port that does not exist.
  final String? simPort;

  const HarborClockDomain({
    required this.config,
    required this.clk,
    required this.reset,
    this.locked,
    this.frequencySelect,
    this.simPort,
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

  /// Builds a domain reset from [assertSrc]: assertion is immediate
  /// (combinational, so it holds even before the domain clock runs), while
  /// deassertion is re-timed through a two-flop synchronizer clocked in the
  /// domain. This avoids recovery/removal hazards when the source (input
  /// reset, power-on reset, or PLL lock) releases asynchronously to [domClk].
  /// The pipe resets to zero while [assertSrc] is high and shifts in ones
  /// after it falls, so reset releases two clean domain edges later. FPGA
  /// flops power up to zero (reset asserted), and on ASIC the externally
  /// held reset clears the pipe within two edges regardless of power-up
  /// state.
  Logic _domainReset(Logic domClk, Logic assertSrc, String name) {
    final pipe = Logic(name: '${name}RstSync', width: 2);
    Sequential(domClk, reset: assertSrc, [
      pipe < [pipe[0], Const(1)].swizzle(),
    ]);
    return (assertSrc | ~pipe[1]).named('${name}Reset');
  }

  /// Creates a clock domain.
  ///
  /// If [HarborClockConfig.isPrimary] is true, passes through the input clock.
  /// Otherwise, instantiates a PLL for the target device.
  /// Creates a domain driven by an already-generated [providedClk] (e.g. a
  /// spare CLKOUT of another MMCM's clock tree) instead of instantiating a
  /// dedicated PLL/MMCM. The domain reset is re-synchronised into [providedClk]
  /// exactly like [createDomain]. Used to run the core off the shared Xilinx
  /// DDR3-fast clock tree on a single-oscillator board, where a second MMCM on
  /// the raw clock pin cannot share the pin's one dedicated clock route.
  HarborClockDomain createDomainFromClock(
    HarborClockConfig config,
    Logic providedClk, {
    Logic? locked,
  }) {
    // Reset hold until the providing PLL is up, BELT-AND-SUSPENDERS: release on
    // (PLL LOCKED) OR (a fixed fallback timer expires), whichever comes first.
    // The HW-verified UberDDR3 openXC7 flow gates on PLL LOCKED, but whether
    // LOCKED physically reaches the fabric is PLACEMENT-DEPENDENT on openXC7's
    // lenient router (some netlists route it, some silently do not. A pure
    // LOCKED gate then hangs that build in reset forever even though the clock
    // is fine). So ALSO run an 18-bit counter (131072 cycles, ~1.3 ms at 100 MHz,
    // comfortably past the ~100 us lock) on the RAW input clock (stable once the
    // clock pin's IOSTANDARD matches its bank. A clock pin in a DDR3 1.35 V bank
    // MUST be SSTL135, not LVCMOS33): if LOCKED never arrives, the timer releases
    // anyway. The release is re-synchronised onto [providedClk]. No counter reset.
    // The FPGA INIT=0 power-up value initialises it.
    final lockCnt = Logic(name: '${config.name}_provLockCnt', width: 18);
    Sequential(inputClk, [
      If(~lockCnt[17], then: [lockCnt < lockCnt + 1]),
    ]);
    final timerHold = ~lockCnt[17];
    // Assert while NOT-locked AND timer-not-expired => release on LOCKED or timer.
    final assertSrc = (locked != null ? (~locked & timerHold) : timerHold)
        .named('${config.name}_provResetHold');
    // [inputReset] (the raw-pin POR counter) is intentionally NOT mixed in: the
    // timer above already covers power-up, and dropping it lets that POR counter
    // DCE so the raw pin feeds ONLY the PLL (the UberDDR3 arrangement).
    final domain = HarborClockDomain(
      config: config,
      clk: providedClk,
      reset: _domainReset(providedClk, assertSrc, config.name),
      locked: locked,
    );
    _domains.add(domain);
    return domain;
  }

  HarborClockDomain createDomain(HarborClockConfig config) {
    if (config.isPrimary) {
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: _domainReset(inputClk, inputReset, config.name),
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
    // the clock-input pad. EXCEPTION: [forcePll] keeps the PLL even at 1:1
    // (the ECP5 DDR edge clock must be a PLL/CLKOP source, not a raw pad, for
    // nextpnr to assign the dedicated ECLK network).
    if (config.frequency == sourceFreq && !config.forcePll) {
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: _domainReset(inputClk, inputReset, config.name),
      );
      _domains.add(domain);
      return domain;
    }

    final t = target;
    if (t == null) {
      // No target: just pass through (simulation mode)
      final domain = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: _domainReset(inputClk, inputReset, config.name),
      );
      _domains.add(domain);
      return domain;
    }

    switch (t) {
      case HarborFpgaTarget():
        return _createFpgaPll(config, sourceFreq, t);
      case HarborAsicTarget():
        return _createAsicPll(config, sourceFreq);
      case HarborSimTarget():
        return _createSimClock(config);
    }
  }

  /// Verilator has no PLL to instantiate, so each derived domain becomes its
  /// OWN top-level input port that the generated C++ clock wheel drives at
  /// [HarborClockConfig.frequency].
  ///
  /// Passing the source clock through instead would be simpler, but it would
  /// collapse every domain onto one clock and quietly turn all the
  /// clock-crossing logic synchronous, which is precisely the logic a
  /// simulator is worth having for. Separate ports keep the crossings real.
  HarborClockDomain _createSimClock(HarborClockConfig config) {
    final portName = '${config.name}_clk';
    parent.createPort(portName, PortDirection.input);
    final domClk = parent.input(portName);
    final domain = HarborClockDomain(
      config: config,
      clk: domClk,
      // No LOCKED to wait on: the harness supplies a running clock from the
      // first tick, so the domain leaves reset off the shared input reset.
      reset: _domainReset(domClk, inputReset, config.name),
      simPort: portName,
    );
    _domains.add(domain);
    return domain;
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

    // Reset is active until the PLL locks, then released into the PLL clock.
    final domain = HarborClockDomain(
      config: config,
      clk: pllClk,
      reset: _domainReset(pllClk, inputReset | ~pllLock, config.name),
      locked: pllLock,
    );
    _domains.add(domain);
    return domain;
  }

  /// ECP5 EHXPLLL divider selection for self-feedback (CLKFB driven by CLKOP).
  ///
  /// At lock fCLKOP = sourceFreq * CLKFB_DIV / CLKI_DIV, and the VCO
  /// fVCO = fCLKOP * CLKOP_DIV must land in the ECP5 400-800 MHz band. The
  /// output:input ratio is realized as a reduced integer fraction (CLKFB_DIV :
  /// CLKI_DIV) so the PLL can divide DOWN as well as up: targetFreq below
  /// sourceFreq needs CLKI_DIV > 1, which the old code (CLKI_DIV hardcoded to 1)
  /// could not express, so a 48->24 request produced a 1:1 PLL whose VCO landed
  /// at 1584 MHz (out of range, never locks).
  static ({int clkiDiv, int clkfbDiv, int clkopDiv}) ecp5PllDividers(
    int sourceFreq,
    int targetFreq,
  ) {
    final g = targetFreq.gcd(sourceFreq);
    final clkfbDiv = (targetFreq ~/ g).clamp(1, 128);
    final clkiDiv = (sourceFreq ~/ g).clamp(1, 128);
    final clkopDiv = (600000000 ~/ targetFreq).clamp(1, 128);
    return (clkiDiv: clkiDiv, clkfbDiv: clkfbDiv, clkopDiv: clkopDiv);
  }

  HarborClockDomain _createEcp5Pll(HarborClockConfig config, int sourceFreq) {
    final dividers = ecp5PllDividers(sourceFreq, config.frequency);
    final clkiDiv = dividers.clkiDiv;
    final clkfbDiv = dividers.clkfbDiv;
    final clkopDiv = dividers.clkopDiv;

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
      reset: _domainReset(
        pll.output('CLKOP'),
        inputReset | ~pll.output('LOCK'),
        config.name,
      ),
      locked: pll.output('LOCK'),
    );
    _domains.add(domain);
    return domain;
  }

  /// CLKOS divider for a secondary ECP5 output sharing CLKOP's VCO.
  ///
  /// The VCO runs at `primaryFreq * CLKOP_DIV`. CLKOS is that divided by the
  /// returned value. For 25 MHz in, 125 MHz primary (CLKOP_DIV 4 -> VCO
  /// 500 MHz), a 25 MHz secondary needs CLKOS_DIV 20.
  static int ecp5ClkosDiv(int sourceFreq, int primaryFreq, int secondaryFreq) {
    final dividers = ecp5PllDividers(sourceFreq, primaryFreq);
    final vco = primaryFreq * dividers.clkopDiv;
    return (vco / secondaryFreq).round();
  }

  /// Solves a Xilinx 7-series MMCME2 for two related outputs off one VCO:
  /// CLKOUT0 = primary (fractional, 0.125 steps), CLKOUT1 = secondary (integer).
  /// Searches CLKFBOUT_MULT_F (2..64, /8) x DIVCLK_DIVIDE (1..8) keeping the VCO
  /// in the 600-1200 MHz band and the PFD (fin/D) in 10-450 MHz, then picks the
  /// divide pair with the least combined relative frequency error. Throws if no
  /// in-band solution exists (bad source/target combination).
  static ({double mult, int divclk, double out0, int out1}) _mmcmDualSolve(
    int fin,
    int primary,
    int secondary,
  ) {
    var bestScore = double.infinity;
    var bMult = 0.0;
    var bDiv = 1;
    var bOut0 = 1.0;
    var bOut1 = 1;
    for (var d = 1; d <= 8; d++) {
      final pfd = fin / d;
      if (pfd < 10e6 || pfd > 450e6) continue;
      for (var m8 = 16; m8 <= 512; m8++) {
        final m = m8 / 8.0;
        final vco = fin * m / d;
        if (vco < 600e6 || vco > 1200e6) continue;
        final o0 = ((vco / primary) * 8).round() / 8.0;
        if (o0 < 1.0 || o0 > 128.0) continue;
        final o1 = (vco / secondary).round();
        if (o1 < 1 || o1 > 128) continue;
        final pErr = (vco / o0 - primary).abs() / primary;
        final sErr = (vco / o1 - secondary).abs() / secondary;
        final score = pErr + sErr;
        if (score < bestScore) {
          bestScore = score;
          bMult = m;
          bDiv = d;
          bOut0 = o0;
          bOut1 = o1;
        }
      }
    }
    if (bMult == 0.0) {
      throw StateError(
        'No MMCME2 solution for fin=$fin primary=$primary secondary=$secondary '
        '(VCO 600-1200 MHz unreachable).',
      );
    }
    return (mult: bMult, divclk: bDiv, out0: bOut0, out1: bOut1);
  }

  /// Creates a [config] clock domain plus a [secondaryFrequency] clock derived
  /// from the SAME PLL. On ECP5 this is one EHXPLLL driving CLKOP (primary) and
  /// CLKOS (secondary) off a shared VCO, with a single lock signal, so a design
  /// needing two related clocks (e.g. a 125 MHz pixel-serializer clock and its
  /// 25 MHz pixel clock) spends one PLL block instead of two.
  ///
  /// ECP5 only. With no target (simulation) both pass the input clock through.
  ({HarborClockDomain primary, HarborClockDomain secondary})
  createDomainWithSecondary(
    HarborClockConfig config, {
    required int secondaryFrequency,
    String? secondaryName,
  }) {
    final secName = secondaryName ?? '${config.name}_s';
    final secConfig = HarborClockConfig.fixed(
      name: secName,
      frequency: secondaryFrequency,
      sourceFrequency: config.sourceFrequency,
    );

    final t = target;
    if (t == null) {
      final p = HarborClockDomain(
        config: config,
        clk: inputClk,
        reset: _domainReset(inputClk, inputReset, config.name),
      );
      final s = HarborClockDomain(
        config: secConfig,
        clk: inputClk,
        reset: _domainReset(inputClk, inputReset, secName),
      );
      _domains
        ..add(p)
        ..add(s);
      return (primary: p, secondary: s);
    }

    // Xilinx 7-series: TWO separate single-output MMCMs (each CLKOUT0), one per
    // domain. A single dual-output MMCM (CLKOUT0 primary + CLKOUT1 secondary) is
    // NOT used: the open nextpnr-xilinx / prjxray FASM backend does not
    // configure the second MMCM output, so CLKOUT1 comes out dead (core held in
    // reset, silent bring-up). Two MMCMs cost more (the 7S50 has plenty) but each
    // uses the proven CLKOUT0 path from _createXilinxPll. The two domains cross
    // through a CDC anyway, so a shared VCO buys nothing here.
    if (t is HarborFpgaTarget &&
        (t.vendor == HarborFpgaVendor.vivado ||
            t.vendor == HarborFpgaVendor.openXc7)) {
      if (config.sourceFrequency == null) {
        throw ArgumentError('Clock "${config.name}" requires sourceFrequency');
      }
      final primaryX = _createXilinxPll(config, config.sourceFrequency!);
      final secondaryX = _createXilinxPll(
        secConfig,
        secConfig.sourceFrequency!,
      );
      return (primary: primaryX, secondary: secondaryX);
    }

    if (t is! HarborFpgaTarget || t.vendor != HarborFpgaVendor.ecp5) {
      throw UnsupportedError(
        'createDomainWithSecondary is implemented for ECP5 and Xilinx '
        '(got ${t.runtimeType}).',
      );
    }

    final sourceFreq = config.sourceFrequency;
    if (sourceFreq == null) {
      throw ArgumentError('Clock "${config.name}" requires sourceFrequency');
    }

    final dividers = ecp5PllDividers(sourceFreq, config.frequency);
    final clkosDiv = ecp5ClkosDiv(
      sourceFreq,
      config.frequency,
      secondaryFrequency,
    );

    final feedback = Logic(name: '${config.name}_pll_fb');
    final pll = Ecp5Ehxplll(
      clkiDiv: dividers.clkiDiv,
      clkfbDiv: dividers.clkfbDiv,
      clkopDiv: dividers.clkopDiv,
      clk: inputClk,
      clkfb: feedback,
      clkosDiv: clkosDiv,
      // CLKOS_CPHASE ~= CLKOS_DIV/2 gives a centered 50%-duty 0-degree output,
      // matching the CLKOP convention. Leaving it at the default 0 produces a
      // degenerate CLKOS edge so the secondary domain's flops never clock and
      // that whole domain is dead: the cause of the silent single-PLL bring-up.
      clkosCphase: clkosDiv ~/ 2,
      name: '${config.name}_pll',
    );
    feedback <= pll.output('CLKOP');
    final lock = pll.output('LOCK');

    final primary = HarborClockDomain(
      config: config,
      clk: pll.output('CLKOP'),
      reset: _domainReset(pll.output('CLKOP'), inputReset | ~lock, config.name),
      locked: lock,
    );
    final secondary = HarborClockDomain(
      config: secConfig,
      clk: pll.output('CLKOS'),
      reset: _domainReset(pll.output('CLKOS'), inputReset | ~lock, secName),
      locked: lock,
    );
    _domains
      ..add(primary)
      ..add(secondary);
    return (primary: primary, secondary: secondary);
  }

  HarborClockDomain _createXilinxPll(HarborClockConfig config, int sourceFreq) {
    final periodNs = 1e9 / sourceFreq;
    // MMCM: fout = fin * CLKFBOUT_MULT_F / (DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F).
    // The VCO (fin*M/D) MUST land in 600-1200 MHz or the MMCM never locks. The
    // old `mult=ratio*10, outDiv=10` gave VCO=fout*10 (e.g. 480 MHz for 48 MHz,
    // below the 600 min), so every single-PLL Xilinx clock was silently dead.
    // Reuse the two-output solver with secondary=primary and take CLKOUT0.
    final sol = _mmcmDualSolve(sourceFreq, config.frequency, config.frequency);
    final mult = sol.mult;
    final outDiv = sol.out0;
    final divClk = sol.divclk.toDouble();

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
    // openXC7 REQUIRES a BUFG in the feedback path (CLKFBOUT -> BUFG -> CLKFBIN),
    // NOT a direct internal feedback. Silicon-verified: with the direct feedback
    // nextpnr drops the MMCM or mis-routes CLKFBIN so it never locks (free VCO).
    // With a BUFG feedback + COMPENSATION ZHOLD it locks and divides exactly.
    final fbBufg = parent.addSubModule(
      XilinxBufg(name: '${config.name}_fbbufg'),
    );
    fbBufg.input('I').srcConnection! <= mmcm.output('CLKFBOUT');
    mmcm.input('CLKFBIN').srcConnection! <= fbBufg.output('O');
    mmcm.input('RST').srcConnection! <= Const(0);
    mmcm.input('PWRDWN').srcConnection! <= Const(0);

    final bufg = parent.addSubModule(XilinxBufg(name: '${config.name}_bufg'));
    bufg.input('I').srcConnection! <= mmcm.output('CLKOUT0');

    // openXC7 MMCM lock hold. The nextpnr-xilinx + prjxray FASM emits the MMCM
    // divider and lock/filter tables correctly, but the LOCKED status output
    // does NOT reach the fabric on silicon (it stays low), so the reset must
    // NOT gate on it. Doing so holds the core dead forever. Instead hold reset
    // with a fixed timer on the RAW input clock that comfortably exceeds the
    // 7-series MMCM lock time (~100 us): a 17-bit counter is 131072 cycles,
    // ~11 ms at 12 MHz. The core boots only after the MMCM has locked and O is
    // a clean clock. Mirrors the SoC power-on counter (no reset of its own, the
    // FPGA INIT=0 power-up value is its initializer).
    final lockCnt = Logic(name: '${config.name}_mmcmLockCnt', width: 18);
    Sequential(inputClk, [
      If(~lockCnt[17], then: [lockCnt < lockCnt + 1]),
    ]);
    final lockHold = (~lockCnt[17]).named('${config.name}_mmcmLockHold');

    final domain = HarborClockDomain(
      config: config,
      clk: bufg.output('O'),
      reset: _domainReset(bufg.output('O'), inputReset | lockHold, config.name),
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
