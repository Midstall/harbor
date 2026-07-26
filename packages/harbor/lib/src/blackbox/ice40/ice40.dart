import 'package:rohd_bridge/rohd_bridge.dart';

/// iCE40 SB_PLL40_CORE: Phase-locked loop (internal clock input).
class Ice40SbPll40Core extends BridgeModule {
  Ice40SbPll40Core({
    required int divr,
    required int divf,
    required int divq,
    required int filterRange,
    String feedbackPath = 'SIMPLE',
    super.name = 'pll',
  }) : super('SB_PLL40_CORE', isSystemVerilogLeaf: true) {
    createPort('REFERENCECLK', PortDirection.input);
    createPort('RESETB', PortDirection.input);
    createPort('BYPASS', PortDirection.input);
    addOutput('PLLOUTCORE');
    addOutput('PLLOUTGLOBAL');
    addOutput('LOCK');

    createParameter('DIVR', '$divr');
    createParameter('DIVF', '$divf');
    createParameter('DIVQ', '$divq');
    createParameter('FILTER_RANGE', '$filterRange');
    createParameter('FEEDBACK_PATH', '"$feedbackPath"');
  }
}

/// iCE40 SB_PLL40_PAD: Phase-locked loop (pad clock input).
class Ice40SbPll40Pad extends BridgeModule {
  Ice40SbPll40Pad({
    required int divr,
    required int divf,
    required int divq,
    required int filterRange,
    String feedbackPath = 'SIMPLE',
    super.name = 'pll',
  }) : super('SB_PLL40_PAD', isSystemVerilogLeaf: true) {
    createPort('PACKAGEPIN', PortDirection.input);
    createPort('RESETB', PortDirection.input);
    createPort('BYPASS', PortDirection.input);
    addOutput('PLLOUTCORE');
    addOutput('PLLOUTGLOBAL');
    addOutput('LOCK');

    createParameter('DIVR', '$divr');
    createParameter('DIVF', '$divf');
    createParameter('DIVQ', '$divq');
    createParameter('FILTER_RANGE', '$filterRange');
    createParameter('FEEDBACK_PATH', '"$feedbackPath"');
  }
}

/// iCE40 SB_GB: Global buffer.
class Ice40SbGb extends BridgeModule {
  Ice40SbGb({super.name = 'gb'}) : super('SB_GB', isSystemVerilogLeaf: true) {
    createPort('USER_SIGNAL_TO_GLOBAL_BUFFER', PortDirection.input);
    addOutput('GLOBAL_BUFFER_OUTPUT');
  }
}

/// iCE40 SB_IO: Configurable I/O cell.
class Ice40SbIo extends BridgeModule {
  Ice40SbIo({required String pinType, super.name = 'io'})
    : super('SB_IO', isSystemVerilogLeaf: true) {
    createPort('PACKAGE_PIN', PortDirection.inOut);
    createPort('CLOCK_ENABLE', PortDirection.input);
    createPort('INPUT_CLK', PortDirection.input);
    createPort('OUTPUT_CLK', PortDirection.input);
    createPort('OUTPUT_ENABLE', PortDirection.input);
    createPort('D_OUT_0', PortDirection.input);
    createPort('D_OUT_1', PortDirection.input);
    addOutput('D_IN_0');
    addOutput('D_IN_1');

    createParameter('PIN_TYPE', '"$pinType"');
  }
}

/// iCE40 SB_RAM40_4K: 4Kbit single-port block RAM.
class Ice40SbRam40_4k extends BridgeModule {
  Ice40SbRam40_4k({super.name = 'bram'})
    : super('SB_RAM40_4K', isSystemVerilogLeaf: true) {
    createPort('RDATA', PortDirection.output, width: 16);
    createPort('RADDR', PortDirection.input, width: 11);
    createPort('RCLK', PortDirection.input);
    createPort('RCLKE', PortDirection.input);
    createPort('RE', PortDirection.input);
    createPort('WDATA', PortDirection.input, width: 16);
    createPort('WADDR', PortDirection.input, width: 11);
    createPort('WCLK', PortDirection.input);
    createPort('WCLKE', PortDirection.input);
    createPort('WE', PortDirection.input);
    createPort('MASK', PortDirection.input, width: 16);
  }
}

/// iCE40 SB_RAM40_4KNR: 4Kbit BRAM with negative-edge read clock.
///
/// Identical to [Ice40SbRam40_4k] but the read port samples on the falling
/// edge of `RCLK`. Driving `RCLK` with the normal clock keeps the read in the
/// same clock domain (phase-related), so a read launched against a posedge
/// register is correctly timed, unlike feeding an inverted clock to a plain
/// SB_RAM40_4K, which the tools treat as an independent domain.
class Ice40SbRam40_4kNR extends BridgeModule {
  Ice40SbRam40_4kNR({super.name = 'bram'})
    : super('SB_RAM40_4KNR', isSystemVerilogLeaf: true) {
    createPort('RDATA', PortDirection.output, width: 16);
    createPort('RADDR', PortDirection.input, width: 11);
    // Negedge read clock port is named RCLKN on the NR variant.
    createPort('RCLKN', PortDirection.input);
    createPort('RCLKE', PortDirection.input);
    createPort('RE', PortDirection.input);
    createPort('WDATA', PortDirection.input, width: 16);
    createPort('WADDR', PortDirection.input, width: 11);
    createPort('WCLK', PortDirection.input);
    createPort('WCLKE', PortDirection.input);
    createPort('WE', PortDirection.input);
    createPort('MASK', PortDirection.input, width: 16);
  }
}

/// iCE40 SB_SPRAM256KA: 256Kbit single-port RAM.
class Ice40SbSpram256ka extends BridgeModule {
  Ice40SbSpram256ka({super.name = 'spram'})
    : super('SB_SPRAM256KA', isSystemVerilogLeaf: true) {
    createPort('DATAIN', PortDirection.input, width: 16);
    createPort('ADDRESS', PortDirection.input, width: 14);
    createPort('MASKWREN', PortDirection.input, width: 4);
    createPort('WREN', PortDirection.input);
    createPort('CHIPSELECT', PortDirection.input);
    createPort('CLOCK', PortDirection.input);
    createPort('DATAOUT', PortDirection.output, width: 16);
    createPort('STANDBY', PortDirection.input);
    createPort('SLEEP', PortDirection.input);
    createPort('POWEROFF', PortDirection.input);
  }
}
