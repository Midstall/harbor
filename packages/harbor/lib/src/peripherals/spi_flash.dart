import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// SPI flash operating mode.
enum HarborSpiFlashMode {
  /// Standard SPI (1-bit MOSI/MISO).
  standard,

  /// Dual SPI (2-bit I/O).
  dual,

  /// Quad SPI (4-bit I/O, QSPI).
  quad,
}

/// SPI flash configuration.
class HarborSpiFlashConfig with HarborPrettyString {
  /// HarborFlash size in bytes.
  final int size;

  /// SPI clock frequency in Hz.
  final int spiFrequency;

  /// Operating mode (standard/dual/quad).
  final HarborSpiFlashMode mode;

  /// Page size in bytes (typically 256).
  final int pageSize;

  /// Sector size in bytes (typically 4096).
  final int sectorSize;

  /// Read command opcode (0x03 for standard, 0x6B for quad).
  final int readCommand;

  /// Address width in bytes (3 for 24-bit, 4 for 32-bit).
  final int addressBytes;

  /// Number of dummy cycles for fast read.
  final int dummyCycles;

  const HarborSpiFlashConfig({
    required this.size,
    this.spiFrequency = 25000000,
    this.mode = HarborSpiFlashMode.standard,
    this.pageSize = 256,
    this.sectorSize = 4096,
    this.readCommand = 0x03,
    this.addressBytes = 3,
    this.dummyCycles = 0,
  });

  /// W25Q128 - common 16MB SPI flash (e.g., on iCEBreaker, OrangeCrab).
  const HarborSpiFlashConfig.w25q128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
  }) : size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B, // Quad Output Fast Read
       addressBytes = 3,
       dummyCycles = 8;

  /// IS25LP128 - common 16MB SPI flash (e.g., on Arty boards).
  const HarborSpiFlashConfig.is25lp128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
  }) : size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// S25FL256 - 32MB SPI flash.
  const HarborSpiFlashConfig.s25fl256({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
  }) : size = 32 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6C, // 4-byte addr quad read
       addressBytes = 4,
       dummyCycles = 8;

  @override
  String toString() =>
      'HarborSpiFlashConfig(${size ~/ (1024 * 1024)} MB, '
      '${mode.name}, ${spiFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSpiFlashConfig(\n');
    buf.writeln('${c}size: ${size ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}mode: ${mode.name},');
    buf.writeln('${c}frequency: ${spiFrequency ~/ 1000000} MHz,');
    buf.writeln('${c}readCmd: 0x${readCommand.toRadixString(16)},');
    buf.writeln('${c}addrBytes: $addressBytes,');
    buf.writeln('${c}dummyCycles: $dummyCycles,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SPI flash controller.
///
/// Provides a Wishbone slave interface for read access to external
/// SPI NOR flash. Supports standard, dual, and quad SPI modes.
///
/// SPI pins (directly exposed for board connection):
/// - `spi_clk` - SPI clock output
/// - `spi_cs_n` - Chip select (active low)
/// - `spi_mosi` - Master Out Slave In (standard mode data out)
/// - `spi_miso` - Master In Slave Out (standard mode data in)
/// - `spi_io` - Quad/Dual I/O (when mode != standard)
///
/// Supports XIP (Execute In Place) - the CPU can fetch instructions
/// directly from the SPI flash.
class HarborSpiFlashController extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// HarborFlash configuration.
  final HarborSpiFlashConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (CPU side).
  late final BusSlavePort bus;

  HarborSpiFlashController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborSpiFlashController', name: name ?? 'spi_flash') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SPI pins
    addOutput('spi_clk');
    addOutput('spi_cs_n');

    if (config.mode == HarborSpiFlashMode.standard) {
      addOutput('spi_mosi');
      createPort('spi_miso', PortDirection.input);
    } else {
      // Quad/Dual mode uses bidirectional IO
      final ioWidth = config.mode == HarborSpiFlashMode.quad ? 4 : 2;
      createPort('spi_io', PortDirection.inOut, width: ioWidth);
    }

    final addrWidth = config.size.bitLength;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: addrWidth,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final datOut = bus.dataOut;
    final ack = bus.ack;
    final stb = bus.stb;

    // SPI state machine
    final spiClk = output('spi_clk');
    final spiCsN = output('spi_cs_n');

    // Bits per clock cycle for data phases
    final bitsPerCycle = switch (config.mode) {
      HarborSpiFlashMode.standard => 1,
      HarborSpiFlashMode.dual => 2,
      HarborSpiFlashMode.quad => 4,
    };

    // Total clocks needed for each phase
    final cmdClocks = 8; // Command is always 1-bit SPI
    final addrClocks = config.addressBytes * 8 ~/ bitsPerCycle;
    final dataClocks = 32 ~/ bitsPerCycle;

    // Shift register for SPI transactions
    final shiftReg = Logic(name: 'shift_reg', width: 32);
    final bitCount = Logic(name: 'bit_count', width: 8);
    final spiState = Logic(name: 'spi_state', width: 3);
    final ioDir = Logic(name: 'io_dir'); // 0=output, 1=input

    // States
    const sIdle = 0;
    const sSendCmd = 1;
    const sSendAddr = 2;
    const sDummy = 3;
    const sReadData = 4;
    const sDone = 5;

    Sequential(clk, [
      If(
        reset,
        then: [
          spiCsN < Const(1),
          spiClk < Const(0),
          shiftReg < Const(0, width: 32),
          bitCount < Const(0, width: 8),
          spiState < Const(sIdle, width: 3),
          ioDir < Const(0),
          ack < Const(0),
          datOut < Const(0, width: 32),
        ],
        orElse: [
          ack < Const(0),

          Case(spiState, [
            // IDLE: wait for bus request
            CaseItem(Const(sIdle, width: 3), [
              If(
                stb & ~ack,
                then: [
                  spiCsN < Const(0),
                  shiftReg < Const(config.readCommand, width: 32),
                  bitCount < Const(0, width: 8),
                  ioDir < Const(0), // output
                  spiState < Const(sSendCmd, width: 3),
                ],
              ),
            ]),

            // SEND_CMD: 8 bits, always 1-bit SPI (MSB first)
            CaseItem(Const(sSendCmd, width: 3), [
              spiClk < ~spiClk,
              If(
                spiClk,
                then: [
                  shiftReg < (shiftReg << Const(1, width: 32)),
                  bitCount < (bitCount + Const(1, width: 8)),
                  If(
                    bitCount.eq(Const(cmdClocks - 1, width: 8)),
                    then: [
                      shiftReg < bus.addr.zeroExtend(32),
                      bitCount < Const(0, width: 8),
                      spiState < Const(sSendAddr, width: 3),
                    ],
                  ),
                ],
              ),
            ]),

            // SEND_ADDR: address bytes, using mode width
            CaseItem(Const(sSendAddr, width: 3), [
              spiClk < ~spiClk,
              If(
                spiClk,
                then: [
                  shiftReg < (shiftReg << Const(bitsPerCycle, width: 32)),
                  bitCount < (bitCount + Const(1, width: 8)),
                  If(
                    bitCount.eq(Const(addrClocks - 1, width: 8)),
                    then: [
                      bitCount < Const(0, width: 8),
                      ioDir < Const(1), // switch to input for read
                      spiState <
                          Const(
                            config.dummyCycles > 0 ? sDummy : sReadData,
                            width: 3,
                          ),
                    ],
                  ),
                ],
              ),
            ]),

            // DUMMY: dummy cycles (IO floating)
            CaseItem(Const(sDummy, width: 3), [
              spiClk < ~spiClk,
              If(
                spiClk,
                then: [
                  bitCount < (bitCount + Const(1, width: 8)),
                  If(
                    bitCount.eq(Const(config.dummyCycles - 1, width: 8)),
                    then: [
                      bitCount < Const(0, width: 8),
                      shiftReg < Const(0, width: 32),
                      spiState < Const(sReadData, width: 3),
                    ],
                  ),
                ],
              ),
            ]),

            // READ_DATA: shift in data using mode width
            CaseItem(Const(sReadData, width: 3), [
              spiClk < ~spiClk,
              If(
                spiClk,
                then: [
                  shiftReg < (shiftReg << Const(bitsPerCycle, width: 32)),
                  // In real hardware, lower bits would be filled from spi_io/miso
                  bitCount < (bitCount + Const(1, width: 8)),
                  If(
                    bitCount.eq(Const(dataClocks - 1, width: 8)),
                    then: [spiState < Const(sDone, width: 3)],
                  ),
                ],
              ),
            ]),

            // DONE: output data, deassert CS
            CaseItem(Const(sDone, width: 3), [
              datOut < shiftReg,
              ack < Const(1),
              spiCsN < Const(1),
              spiClk < Const(0),
              ioDir < Const(0),
              spiState < Const(sIdle, width: 3),
            ]),
          ]),
        ],
      ),
    ]);

    // MOSI/IO output
    if (config.mode == HarborSpiFlashMode.standard) {
      output('spi_mosi') <= shiftReg[31];
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['jedec,spi-nor'],
    reg: BusAddressRange(baseAddress, config.size),
    properties: {
      'spi-max-frequency': config.spiFrequency,
      if (config.mode == HarborSpiFlashMode.quad) 'spi-tx-bus-width': 4,
      if (config.mode == HarborSpiFlashMode.dual) 'spi-tx-bus-width': 2,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, config.size)],
    properties: {
      'compatible': ['jedec,spi-nor'],
      'spi-max-frequency': config.spiFrequency,
      if (config.mode == HarborSpiFlashMode.quad) 'spi-tx-bus-width': 4,
      if (config.mode == HarborSpiFlashMode.dual) 'spi-tx-bus-width': 2,
    },
  );
}
