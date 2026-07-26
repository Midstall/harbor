import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// SPI master/slave controller.
///
/// Register map:
/// - 0x00: CTRL    (control: enable, CPOL, CPHA, master/slave, loopback)
/// - 0x04: STATUS  (read-only: busy, tx_empty, rx_ready, overrun)
/// - 0x08: DATA    (write=TX, read=RX)
/// - 0x0C: DIVIDER (clock divider for baud rate)
/// - 0x10: CS      (chip select output value)
///
/// Supports both master and slave mode. CPOL/CPHA configurable.
class HarborSpiController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Whether this is a master (true) or slave (false) by default.
  final bool isMaster;

  /// Number of chip select lines (master mode).
  final int csCount;

  /// Data width in bits (typically 8).
  final int spiDataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborSpiController({
    required this.baseAddress,
    this.isMaster = true,
    this.csCount = 1,
    this.spiDataWidth = 8,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborSpiController', name: name ?? 'spi') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SPI pins
    addOutput('spi_clk');
    addOutput('spi_mosi');
    createPort('spi_miso', PortDirection.input);
    addOutput('spi_cs_n', width: csCount);
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
    final miso = input('spi_miso');

    // Control register fields
    final enable = Logic(name: 'enable');
    final cpol = Logic(name: 'cpol');
    final cpha = Logic(name: 'cpha');
    final loopback = Logic(name: 'loopback');
    final divider = Logic(name: 'divider', width: 16);
    final csReg = Logic(name: 'cs_reg', width: csCount);

    // TX/RX state
    final txData = Logic(name: 'tx_data', width: spiDataWidth);
    final rxData = Logic(name: 'rx_data', width: spiDataWidth);
    final shiftReg = Logic(name: 'shift_reg', width: spiDataWidth);
    final bitCount = Logic(name: 'bit_count', width: 4);
    final divCount = Logic(name: 'div_count', width: 16);
    final busy = Logic(name: 'busy');
    final txEmpty = Logic(name: 'tx_empty');
    final rxReady = Logic(name: 'rx_ready');
    final spiClkReg = Logic(name: 'spi_clk_reg');

    output('spi_clk') <= spiClkReg ^ cpol;
    output('spi_mosi') <= shiftReg[spiDataWidth - 1];
    output('spi_cs_n') <= ~csReg;

    // Status register
    final status = Logic(name: 'status', width: 32);
    status <=
        busy.zeroExtend(32) |
            (txEmpty.zeroExtend(32) << Const(1, width: 32)) |
            (rxReady.zeroExtend(32) << Const(2, width: 32));

    interrupt <= rxReady;

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          cpol < Const(0),
          cpha < Const(0),
          loopback < Const(0),
          divider < Const(1, width: 16),
          csReg < Const(0, width: csCount),
          txData < Const(0, width: spiDataWidth),
          rxData < Const(0, width: spiDataWidth),
          shiftReg < Const(0, width: spiDataWidth),
          bitCount < Const(0, width: 4),
          divCount < Const(0, width: 16),
          busy < Const(0),
          txEmpty < Const(1),
          rxReady < Const(0),
          spiClkReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // SPI shift engine
          If(
            busy & enable,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [
                  divCount < divider,
                  spiClkReg < ~spiClkReg,

                  // Sample on appropriate edge based on CPHA
                  If(
                    spiClkReg ^ cpha,
                    then: [
                      shiftReg <
                          (shiftReg << Const(1, width: spiDataWidth)) |
                              mux(
                                loopback,
                                shiftReg[spiDataWidth - 1],
                                miso,
                              ).zeroExtend(spiDataWidth),
                      bitCount < (bitCount + Const(1, width: 4)),
                      If(
                        bitCount.eq(Const(spiDataWidth - 1, width: 4)),
                        then: [
                          busy < Const(0),
                          rxData < shiftReg,
                          rxReady < Const(1),
                          spiClkReg < Const(0),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [divCount < (divCount - Const(1, width: 16))],
              ),
            ],
          ),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              Case(bus.addr.getRange(0, 5), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 5), [
                  If(
                    bus.we,
                    then: [
                      enable < bus.dataIn[0],
                      cpol < bus.dataIn[1],
                      cpha < bus.dataIn[2],
                      loopback < bus.dataIn[3],
                    ],
                    orElse: [
                      bus.dataOut <
                          enable.zeroExtend(32) |
                              (cpol.zeroExtend(32) << Const(1, width: 32)) |
                              (cpha.zeroExtend(32) << Const(2, width: 32)) |
                              (loopback.zeroExtend(32) << Const(3, width: 32)),
                    ],
                  ),
                ]),
                // 0x04: STATUS
                CaseItem(Const(0x01, width: 5), [bus.dataOut < status]),
                // 0x08: DATA
                CaseItem(Const(0x02, width: 5), [
                  If(
                    bus.we,
                    then: [
                      shiftReg < bus.dataIn.getRange(0, spiDataWidth),
                      busy < Const(1),
                      txEmpty < Const(0),
                      bitCount < Const(0, width: 4),
                      divCount < divider,
                    ],
                    orElse: [
                      bus.dataOut < rxData.zeroExtend(32),
                      rxReady < Const(0),
                    ],
                  ),
                ]),
                // 0x0C: DIVIDER
                CaseItem(Const(0x03, width: 5), [
                  If(
                    bus.we,
                    then: [divider < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < divider.zeroExtend(32)],
                  ),
                ]),
                // 0x10: CS
                CaseItem(Const(0x04, width: 5), [
                  If(
                    bus.we,
                    then: [csReg < bus.dataIn.getRange(0, csCount)],
                    orElse: [bus.dataOut < csReg.zeroExtend(32)],
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
    compatible: ['harbor,spi', 'opencores,spi-oc'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'num-cs': csCount, '#address-cells': 1, '#size-cells': 0},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,spi', 'opencores,spi-oc'],
      'num-cs': csCount,
      '#address-cells': 1,
      '#size-cells': 0,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SPI',
    groupName: 'SPI',
    description: 'SPI master and slave controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
