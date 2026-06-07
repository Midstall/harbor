import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// SD/SDIO bus width.
enum HarborSdioBusWidth {
  /// 1-bit data bus.
  one(1),

  /// 4-bit data bus.
  four(4),

  /// 8-bit data bus (eMMC only).
  eight(8);

  final int width;
  const HarborSdioBusWidth(this.width);
}

/// SD/SDIO speed mode.
enum HarborSdioSpeed {
  /// Default speed (25 MHz, SD).
  defaultSpeed,

  /// High speed (50 MHz, SD).
  highSpeed,

  /// UHS-I SDR12 (25 MHz, SD 3.0).
  sdr12,

  /// UHS-I SDR25 (50 MHz, SD 3.0).
  sdr25,

  /// UHS-I SDR50 (100 MHz, SD 3.0).
  sdr50,

  /// UHS-I SDR104 (208 MHz, SD 3.0).
  sdr104,

  /// UHS-I DDR50 (50 MHz DDR, SD 3.0).
  ddr50,

  /// HS200 (200 MHz, eMMC 4.5).
  hs200,

  /// HS400 (200 MHz DDR, eMMC 5.0).
  hs400,
}

/// SD/SDIO controller configuration.
class HarborSdioConfig with HarborPrettyString {
  /// Maximum bus width supported.
  final HarborSdioBusWidth maxBusWidth;

  /// Maximum speed mode supported.
  final HarborSdioSpeed maxSpeed;

  /// Whether SDIO (I/O card) mode is supported.
  final bool supportsIo;

  /// Whether eMMC mode is supported.
  final bool supportsEmmc;

  /// Whether 1.8V signaling is supported (UHS-I).
  final bool supports1v8;

  /// Maximum clock frequency in Hz.
  final int maxFrequency;

  /// Maximum number of SDIO I/O functions (1-7, 0 = no I/O support).
  ///
  /// WiFi/BT combo chips typically use 2 functions
  /// (function 1: WiFi, function 2: Bluetooth).
  final int maxIoFunctions;

  const HarborSdioConfig({
    this.maxBusWidth = HarborSdioBusWidth.four,
    this.maxSpeed = HarborSdioSpeed.highSpeed,
    this.supportsIo = false,
    this.supportsEmmc = false,
    this.supports1v8 = false,
    this.maxFrequency = 50000000,
    this.maxIoFunctions = 0,
  });

  /// SD card controller (standard 4-bit, up to high speed).
  const HarborSdioConfig.sd()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = false,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 0;

  /// SDIO WiFi/BT controller (4-bit, high speed, I/O functions).
  ///
  /// Suitable for chips like ESP32, CYW43455, RTL8822, etc.
  const HarborSdioConfig.wifi()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 2;

  /// SD 3.0 UHS-I controller with full SDIO support.
  const HarborSdioConfig.uhs()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.sdr104,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = true,
      maxFrequency = 208000000,
      maxIoFunctions = 7;

  /// eMMC controller (8-bit, HS200).
  const HarborSdioConfig.emmc()
    : maxBusWidth = HarborSdioBusWidth.eight,
      maxSpeed = HarborSdioSpeed.hs200,
      supportsIo = false,
      supportsEmmc = true,
      supports1v8 = true,
      maxFrequency = 200000000,
      maxIoFunctions = 0;

  @override
  String toString() =>
      'HarborSdioConfig(${maxBusWidth.width}-bit, ${maxSpeed.name}, '
      '${maxFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSdioConfig(\n');
    buf.writeln('${c}busWidth: ${maxBusWidth.width}-bit,');
    buf.writeln('${c}speed: ${maxSpeed.name},');
    buf.writeln('${c}maxFrequency: ${maxFrequency ~/ 1000000} MHz,');
    if (supportsIo) buf.writeln('${c}SDIO I/O,');
    if (supportsEmmc) buf.writeln('${c}eMMC,');
    if (supports1v8) buf.writeln('${c}1.8V signaling,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SD/SDIO/eMMC host controller.
///
/// Register map:
/// - 0x00: CTRL      (enable, bus width, speed mode, reset)
/// - 0x04: STATUS    (card_detect, card_ready, busy, error)
/// - 0x08: CLK_DIV   (clock divider)
/// - 0x0C: CMD       (command index + argument trigger)
/// - 0x10: CMD_ARG   (command argument)
/// - 0x14: RESP0     (response bits 31:0)
/// - 0x18: RESP1     (response bits 63:32)
/// - 0x1C: RESP2     (response bits 95:64)
/// - 0x20: RESP3     (response bits 127:96)
/// - 0x24: DATA      (read/write data FIFO)
/// - 0x28: BLK_SIZE  (block size for data transfers)
/// - 0x2C: BLK_COUNT (block count for multi-block transfers)
/// - 0x30: INT_STATUS (interrupt status, write-1-to-clear)
/// - 0x34: INT_ENABLE (interrupt enable)
class HarborSdioController extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// Controller configuration.
  final HarborSdioConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborSdioController({
    required this.baseAddress,
    this.config = const HarborSdioConfig.sd(),
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborSdioController', name: name ?? 'sdio') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SD/SDIO pins
    addOutput('sd_clk');
    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    createPort('sd_cmd_in', PortDirection.input);
    addOutput('sd_dat_out', width: config.maxBusWidth.width);
    addOutput('sd_dat_oe');
    createPort(
      'sd_dat_in',
      PortDirection.input,
      width: config.maxBusWidth.width,
    );
    createPort('sd_cd', PortDirection.input); // card detect
    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 8,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final cardDetect = input('sd_cd');

    // Registers
    final ctrlEnable = Logic(name: 'ctrl_enable');
    final clkDiv = Logic(name: 'clk_div', width: 16);
    final cmdIndex = Logic(name: 'cmd_index', width: 6);
    final cmdArg = Logic(name: 'cmd_arg', width: 32);
    final resp = List.generate(4, (i) => Logic(name: 'resp$i', width: 32));
    final blkSize = Logic(name: 'blk_size', width: 12);
    final blkCount = Logic(name: 'blk_count', width: 16);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final busy = Logic(name: 'busy');
    final divCount = Logic(name: 'div_count', width: 16);
    final sdClkReg = Logic(name: 'sd_clk_reg');

    output('sd_clk') <= sdClkReg & ctrlEnable;
    output('sd_cmd_out') <= Const(1);
    output('sd_cmd_oe') <= Const(0);
    output('sd_dat_out') <= Const(0, width: config.maxBusWidth.width);
    output('sd_dat_oe') <= Const(0);
    interrupt <= (intStatus & intEnable).or();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlEnable < Const(0),
          clkDiv < Const(124, width: 16), // ~400 kHz from 50 MHz
          cmdIndex < Const(0, width: 6),
          cmdArg < Const(0, width: 32),
          for (var i = 0; i < 4; i++) resp[i] < Const(0, width: 32),
          blkSize < Const(512, width: 12),
          blkCount < Const(1, width: 16),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          busy < Const(0),
          divCount < Const(0, width: 16),
          sdClkReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // SD clock divider
          If(
            ctrlEnable,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [divCount < clkDiv, sdClkReg < ~sdClkReg],
                orElse: [divCount < (divCount - Const(1, width: 16))],
              ),
            ],
          ),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              Case(bus.addr.getRange(0, 6), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [ctrlEnable < bus.dataIn[0]],
                    orElse: [
                      bus.dataOut <
                          ctrlEnable.zeroExtend(32) |
                              (Const(config.maxBusWidth.width, width: 32) <<
                                  Const(4, width: 32)),
                    ],
                  ),
                ]),
                // 0x04: STATUS
                CaseItem(Const(0x01, width: 6), [
                  bus.dataOut <
                      cardDetect.zeroExtend(32) |
                          (busy.zeroExtend(32) << Const(8, width: 32)),
                ]),
                // 0x08: CLK_DIV
                CaseItem(Const(0x02, width: 6), [
                  If(
                    bus.we,
                    then: [clkDiv < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < clkDiv.zeroExtend(32)],
                  ),
                ]),
                // 0x0C: CMD
                CaseItem(Const(0x03, width: 6), [
                  If(
                    bus.we,
                    then: [
                      cmdIndex < bus.dataIn.getRange(0, 6),
                      busy < Const(1),
                      // Command execution would be handled by the SD protocol engine
                    ],
                    orElse: [bus.dataOut < cmdIndex.zeroExtend(32)],
                  ),
                ]),
                // 0x10: CMD_ARG
                CaseItem(Const(0x04, width: 6), [
                  If(
                    bus.we,
                    then: [cmdArg < bus.dataIn],
                    orElse: [bus.dataOut < cmdArg],
                  ),
                ]),
                // 0x14-0x20: RESP0-3
                for (var i = 0; i < 4; i++)
                  CaseItem(Const(0x05 + i, width: 6), [bus.dataOut < resp[i]]),
                // 0x24: DATA
                CaseItem(Const(0x09, width: 6), [
                  // Data FIFO read/write - protocol engine handles actual transfers
                  bus.dataOut < Const(0, width: 32),
                ]),
                // 0x28: BLK_SIZE
                CaseItem(Const(0x0A, width: 6), [
                  If(
                    bus.we,
                    then: [blkSize < bus.dataIn.getRange(0, 12)],
                    orElse: [bus.dataOut < blkSize.zeroExtend(32)],
                  ),
                ]),
                // 0x2C: BLK_COUNT
                CaseItem(Const(0x0B, width: 6), [
                  If(
                    bus.we,
                    then: [blkCount < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < blkCount.zeroExtend(32)],
                  ),
                ]),
                // 0x30: INT_STATUS (write-1-to-clear)
                CaseItem(Const(0x0C, width: 6), [
                  If(
                    bus.we,
                    then: [
                      intStatus < (intStatus & ~bus.dataIn.getRange(0, 8)),
                    ],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x34: INT_ENABLE
                CaseItem(Const(0x0D, width: 6), [
                  If(
                    bus.we,
                    then: [intEnable < bus.dataIn.getRange(0, 8)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: config.supportsEmmc ? ['harbor,sdhci-emmc'] : ['harbor,sdhci'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': config.supportsEmmc
          ? ['harbor,sdhci-emmc']
          : ['harbor,sdhci'],
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );
}
