import 'target.dart';

/// A physical FPGA board: a named bundle of the vendor part, the on-board
/// oscillator, a catalog of usable pins, and how to program it.
///
/// This is the whole-board cousin of River's `DdrBoard`. Instead of describing
/// a DRAM part, it describes a complete board so an SoC can target it by name
/// without hand-entering pin sites. Use [fpgaTarget] to turn a board into a
/// [HarborFpgaTarget].
class HarborBoard {
  /// Board name (e.g. `'ulx3s-85f'`).
  final String name;

  /// FPGA vendor.
  final HarborFpgaVendor vendor;

  /// Device part (e.g. `'lfe5u-85f'`).
  final String device;

  /// Package (e.g. `'CABGA381'`).
  final String package;

  /// On-board oscillator frequency in Hz. Used as the default target clock and
  /// for the input-clock timing constraint.
  final int oscillatorHz;

  /// Pin catalog: logical signal name -> `"SITE [IO_TYPE] [ATTR=VAL...]"`, in
  /// the format [HarborFpgaTarget] renders into constraints.
  final Map<String, String> pins;

  /// Bitstream programming command for the generated `prog` Makefile target.
  final String? progCommand;

  /// Name of the board's clock signal in [pins] and the SoC top port (default
  /// `'clk'`).
  final String clockPortName;

  const HarborBoard({
    required this.name,
    required this.vendor,
    required this.device,
    required this.package,
    required this.oscillatorHz,
    required this.pins,
    this.progCommand,
    this.clockPortName = 'clk',
  });

  /// Built-in board presets, keyed by [name].
  static const byName = <String, HarborBoard>{
    'ulx3s-85f': _ulx3s85f,
    'orangecrab-25f': _orangeCrab25f,
    'arty-s7-50': _artyS7_50,
  };

  /// Resolves a board preset by name, throwing if it is unknown.
  static HarborBoard get(String name) {
    final board = byName[name];
    if (board == null) {
      throw ArgumentError(
        'Unknown board "$name". Known: ${byName.keys.join(', ')}.',
      );
    }
    return board;
  }

  String get _vendorPrefix => switch (vendor) {
    HarborFpgaVendor.ice40 => 'ice40',
    HarborFpgaVendor.ecp5 => 'ecp5',
    HarborFpgaVendor.vivado => 'spartan7',
    HarborFpgaVendor.openXc7 => 'spartan7',
  };

  /// Builds a [HarborFpgaTarget] for this board.
  ///
  /// [pins] selects which catalog signals to constrain (defaults to all of
  /// them), requesting a signal not in the catalog throws. [extraPins] adds
  /// board-specific pins not in the catalog. [frequency] overrides the target
  /// clock (defaults to [oscillatorHz]).
  HarborFpgaTarget fpgaTarget({
    Iterable<String>? pins,
    int? frequency,
    Map<String, String> extraPins = const {},
  }) {
    final selected = pins ?? this.pins.keys;
    final pinMap = <String, String>{};
    for (final signal in selected) {
      final site = this.pins[signal];
      if (site == null) {
        throw ArgumentError(
          'Pin "$signal" is not in board "$name"\'s catalog. '
          'Known: ${this.pins.keys.join(', ')}.',
        );
      }
      pinMap[signal] = site;
    }
    pinMap.addAll(extraPins);

    return HarborFpgaTarget(
      name: '$_vendorPrefix-$device',
      vendor: vendor,
      device: device,
      package: package,
      frequency: frequency ?? oscillatorHz,
      pinMap: pinMap,
      clockPortName: clockPortName,
      progCommand: progCommand,
    );
  }
}

/// ULX3S with the Lattice ECP5 LFE5U-85F (CABGA381), 25 MHz oscillator.
///
/// Fully open toolchain (yosys + nextpnr + trellis) with GPDI/HDMI display
/// output. The catalog currently covers the oscillator and the FTDI console
/// UART. LEDs, the button, and the GPDI pairs are added with verified sites as
/// the bring-up needs them.
const _ulx3s85f = HarborBoard(
  name: 'ulx3s-85f',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-85f',
  package: 'CABGA381',
  oscillatorHz: 25000000,
  pins: {
    'clk': 'G2', // clk_25mhz
    'uart_tx': 'L4', // ftdi_rxd (FPGA drives FTDI receive)
    'uart_rx': 'M1', // ftdi_txd (FPGA reads FTDI transmit)
    // GPDI (HDMI) TMDS lanes, ULX3S v2.0. LVCMOS33D is a true differential
    // output, so only the positive ball is constrained, the tool drives the
    // complement pad. Channels 0..2 are data (blue/green/red), 3 is the clock.
    'gpdi_dp[0]': 'A16 LVCMOS33D DRIVE=4',
    'gpdi_dp[1]': 'A14 LVCMOS33D DRIVE=4',
    'gpdi_dp[2]': 'A12 LVCMOS33D DRIVE=4',
    'gpdi_dp[3]': 'A17 LVCMOS33D DRIVE=4',
  },
  // openFPGALoader knows the ULX3S. Loads the bitstream over USB.
  progCommand: 'openFPGALoader -b ulx3s \$(TOP).bit',
);

/// OrangeCrab r0.2 with the Lattice ECP5 LFE5U-25F (CSFBGA285), 48 MHz oscillator.
///
/// Fully open toolchain (yosys + nextpnr-ecp5 + trellis). The catalog covers the
/// oscillator, the DirtyJTAG CDC UART, and the config SPI flash (quad, clock via
/// the ECP5 USRMCLK macro so there is no spi_clk pad). DDR3L sdram_* sites are
/// added with their SSTL135 attributes when the DDR weight backend lands (the
/// OrangeCrab DDR path is not yet hardware-proven). Loaded over DirtyJTAG.
const _orangeCrab25f = HarborBoard(
  name: 'orangecrab-25f',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-25f',
  package: 'CSFBGA285',
  oscillatorHz: 48000000,
  pins: {
    'clk': 'A9 LVCMOS33',
    'uart_tx': 'N17 LVCMOS33', // FPGA drives the DirtyJTAG CDC receive
    'uart_rx': 'M18 LVCMOS33', // FPGA reads the DirtyJTAG CDC transmit
    // Config SPI flash (W25Q128, quad). The clock has no pad: the controller
    // drives it through USRMCLK, so only cs_n + the 4-bit io bus are constrained.
    'spi_cs_n': 'U17 LVCMOS33',
    'spi_io[0]': 'U18 LVCMOS33',
    'spi_io[1]': 'T18 LVCMOS33',
    'spi_io[2]': 'R18 LVCMOS33',
    'spi_io[3]': 'N18 LVCMOS33',
  },
  // DirtyJTAG speaks the OrangeCrab JTAG. openFPGALoader loads to SRAM.
  progCommand: 'openFPGALoader -c dirtyJtag \$(TOP).bit',
);

/// Digilent Arty S7-50 with the Xilinx Spartan-7 XC7S50 (csga324), 100 MHz
/// oscillator, via the open-source openXC7 flow (yosys synth_xilinx +
/// nextpnr-xilinx + prjxray, the only Xilinx flow that runs on aarch64).
///
/// Covers the oscillator and the USB-UART bridge (the HW-proven Weir-boot pins).
/// The config SPI flash and DDR3L sdram_* sites (Micron MT41K128M16, from the
/// litex arty_s7 platform) stay authoritative in River's boards.dart, pulled in
/// per memory region (`flash:...:arty-s7`, `dram:...:arty-s7-x8`), so they are
/// intentionally not duplicated here.
const _artyS7_50 = HarborBoard(
  name: 'arty-s7-50',
  vendor: HarborFpgaVendor.openXc7,
  device: 'xc7s50',
  package: 'csga324',
  oscillatorHz: 100000000,
  pins: {
    'clk': 'R2', // 100 MHz board oscillator
    'uart_tx': 'R12 LVCMOS33', // FPGA -> USB-UART bridge RX (Pmod/onboard)
    'uart_rx': 'V12 LVCMOS33', // FPGA <- USB-UART bridge TX
  },
);
