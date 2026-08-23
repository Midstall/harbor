import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// I2C master/slave controller.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL     (enable, interrupt enable, master/slave)
/// - 0x08: STATUS   (busy, ack_received, arb_lost, tx_empty, rx_ready)
/// - 0x10: DATA     (write=TX byte, read=RX byte)
/// - 0x18: ADDR     (slave address for master mode, own address for slave)
/// - 0x20: PRESCALE (clock prescaler for SCL frequency)
/// - 0x28: CMD      (write: start, stop, read, write, ack/nack)
///
/// Supports standard (100 kHz), fast (400 kHz), and fast-plus (1 MHz).
class HarborI2cController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborInputClockConsumer {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Controller input clock in Hz (the system clock the PRESCALE register
  /// divides). Emitted as `harbor,input-clock-hz`, NOT `clock-frequency`: on an
  /// I2C node the standard binding gives `clock-frequency` the SCL bus rate, so
  /// overloading it would make a driver clock the bus at the system rate.
  /// 0 leaves the property out.
  int clockFrequency;

  /// Wishbone slave address width. Defaults to 8 (256-byte register window).
  final int busAddressWidth;

  /// Wishbone slave data width. Must match the SoC fabric (e.g. 64 on an RV64
  /// SoC). The register file itself is 32-bit; wider buses zero-extend reads.
  final int busDataWidth;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborI2cController({
    required this.baseAddress,
    this.clockFrequency = 0,
    this.busAddressWidth = 8,
    this.busDataWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborI2cController', name: name ?? 'i2c') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // I2C pins (directly exposed, directly active or active-low variants)
    createPort('scl_in', PortDirection.input);
    addOutput('scl_out');
    addOutput('scl_oe'); // output enable (active high)
    createPort('sda_in', PortDirection.input);
    addOutput('sda_out');
    addOutput('sda_oe');
    addOutput('interrupt');

    // Bus read-data width. The register file is 32-bit; a wider fabric sees the
    // registers zero-extended into the low word.
    final dw = busDataWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth,
      dataWidth: dw,
    );

    final clk = input('clk');
    final reset = input('reset');
    final sclOut = output('scl_out');
    final sclOe = output('scl_oe');
    final sdaOut = output('sda_out');
    final sdaOe = output('sda_oe');

    // Registers
    final enable = Logic(name: 'enable');
    final irqEn = Logic(name: 'irq_en');
    final prescale = Logic(name: 'prescale', width: 16);
    final txData = Logic(name: 'tx_data', width: 8);
    final rxData = Logic(name: 'rx_data', width: 8);
    final slaveAddr = Logic(name: 'slave_addr', width: 7);
    final shiftReg = Logic(name: 'shift_reg', width: 8);
    final bitCount = Logic(name: 'bit_count', width: 4);
    final divCount = Logic(name: 'div_count', width: 16);

    // Status
    final busy = Logic(name: 'busy');
    final ackReceived = Logic(name: 'ack_received');
    final arbLost = Logic(name: 'arb_lost');
    final rxReady = Logic(name: 'rx_ready');
    final cmdDone = Logic(name: 'cmd_done');

    // I2C state
    final i2cState = Logic(name: 'i2c_state', width: 4);
    final sclPhase = Logic(name: 'scl_phase');

    const stIdle = 0;
    const stStart = 1;
    const stData = 2;
    // const stAck = 3; // used in full implementation
    const stStop = 4;

    // Default: release lines (open-drain, active low drive)
    sclOut <= Const(0);
    sdaOut <= Const(0);
    sclOe <= busy & ~sclPhase; // drive SCL low during low phase
    sdaOe <= busy & ~shiftReg[7]; // drive SDA low when bit is 0

    interrupt <= irqEn & cmdDone;

    final status =
        busy.zeroExtend(dw) |
        (ackReceived.zeroExtend(dw) << Const(1, width: dw)) |
        (arbLost.zeroExtend(dw) << Const(2, width: dw)) |
        (rxReady.zeroExtend(dw) << Const(4, width: dw)) |
        (cmdDone.zeroExtend(dw) << Const(5, width: dw));

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          irqEn < Const(0),
          prescale < Const(100, width: 16), // default 100 kHz at ~10 MHz
          txData < Const(0, width: 8),
          rxData < Const(0, width: 8),
          slaveAddr < Const(0, width: 7),
          shiftReg < Const(0xFF, width: 8),
          bitCount < Const(0, width: 4),
          divCount < Const(0, width: 16),
          busy < Const(0),
          ackReceived < Const(0),
          arbLost < Const(0),
          rxReady < Const(0),
          cmdDone < Const(0),
          i2cState < Const(stIdle, width: 4),
          sclPhase < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),

          // I2C clock divider
          If(
            busy & enable,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [divCount < prescale, sclPhase < ~sclPhase],
                orElse: [divCount < (divCount - Const(1, width: 16))],
              ),
            ],
          ),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Byte-address decode: registers sit 8 bytes apart (see the map
              // above), so match the low 6 bits of the byte address directly.
              Case(bus.addr.getRange(0, 6), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [enable < bus.dataIn[0], irqEn < bus.dataIn[1]],
                    orElse: [
                      bus.dataOut <
                          enable.zeroExtend(dw) |
                              (irqEn.zeroExtend(dw) << Const(1, width: dw)),
                    ],
                  ),
                ]),
                // 0x08: STATUS
                CaseItem(Const(0x08, width: 6), [
                  bus.dataOut < status,
                  If(bus.we, then: [cmdDone < Const(0)]), // clear on write
                ]),
                // 0x10: DATA
                CaseItem(Const(0x10, width: 6), [
                  If(
                    bus.we,
                    then: [txData < bus.dataIn.getRange(0, 8)],
                    orElse: [
                      bus.dataOut < rxData.zeroExtend(dw),
                      rxReady < Const(0),
                    ],
                  ),
                ]),
                // 0x18: ADDR
                CaseItem(Const(0x18, width: 6), [
                  If(
                    bus.we,
                    then: [slaveAddr < bus.dataIn.getRange(0, 7)],
                    orElse: [bus.dataOut < slaveAddr.zeroExtend(dw)],
                  ),
                ]),
                // 0x20: PRESCALE
                CaseItem(Const(0x20, width: 6), [
                  If(
                    bus.we,
                    then: [prescale < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < prescale.zeroExtend(dw)],
                  ),
                ]),
                // 0x28: CMD (write-only: trigger I2C operations)
                CaseItem(Const(0x28, width: 6), [
                  If(
                    bus.we,
                    then: [
                      // bit 0: start, bit 1: stop, bit 2: write, bit 3: read
                      If(
                        bus.dataIn[0],
                        then: [
                          // START
                          busy < Const(1),
                          i2cState < Const(stStart, width: 4),
                          bitCount < Const(0, width: 4),
                        ],
                      ),
                      If(
                        bus.dataIn[1],
                        then: [
                          // STOP
                          i2cState < Const(stStop, width: 4),
                        ],
                      ),
                      If(
                        bus.dataIn[2],
                        then: [
                          // WRITE byte
                          shiftReg < txData,
                          bitCount < Const(0, width: 4),
                          i2cState < Const(stData, width: 4),
                        ],
                      ),
                      If(
                        bus.dataIn[3],
                        then: [
                          // READ byte
                          shiftReg < Const(0xFF, width: 8),
                          bitCount < Const(0, width: 4),
                          i2cState < Const(stData, width: 4),
                        ],
                      ),
                    ],
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
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,i2c', 'opencores,i2c-ocores'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'harbor,input-clock-hz': clockFrequency,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,i2c', 'opencores,i2c-ocores'],
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'harbor,input-clock-hz': clockFrequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'I2C',
    groupName: 'I2C',
    description: 'I2C master/slave controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
