import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// General-Purpose I/O (GPIO) peripheral.
///
/// Provides configurable input/output pins with direction control,
/// output value, and input readback registers.
///
/// Register map:
/// - 0x00: INPUT   (read-only, current pin values)
/// - 0x04: OUTPUT  (read/write, output values)
/// - 0x08: DIR     (read/write, 1=output, 0=input)
/// - 0x0C: IRQ_EN  (read/write, interrupt enable per pin)
/// - 0x10: IRQ_STATUS (read/write-1-to-clear, interrupt status)
/// - 0x14: IRQ_EDGE (read/write, 0=level, 1=edge triggered)
class HarborGpio extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Number of GPIO pins.
  final int pinCount;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// GPIO pin I/O (directly exposed for board connection).
  Logic get gpioIn => input('gpio_in');
  Logic get gpioOut => output('gpio_out');
  Logic get gpioDir => output('gpio_dir');

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborGpio({
    required this.baseAddress,
    this.pinCount = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborGpio', name: name ?? 'gpio') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    createPort('gpio_in', PortDirection.input, width: pinCount);
    addOutput('gpio_out', width: pinCount);
    addOutput('gpio_dir', width: pinCount);
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

    final outputReg = Logic(name: 'output_reg', width: pinCount);
    final dirReg = Logic(name: 'dir_reg', width: pinCount);
    final irqEn = Logic(name: 'irq_en', width: pinCount);
    final irqStatus = Logic(name: 'irq_status', width: pinCount);
    final irqEdge = Logic(name: 'irq_edge', width: pinCount);
    final prevInput = Logic(name: 'prev_input', width: pinCount);

    gpioOut <= outputReg;
    gpioDir <= dirReg;

    // Interrupt: OR of all enabled, active interrupts
    interrupt <= (irqStatus & irqEn).or();

    Sequential(clk, [
      If(
        reset,
        then: [
          outputReg < Const(0, width: pinCount),
          dirReg < Const(0, width: pinCount),
          irqEn < Const(0, width: pinCount),
          irqStatus < Const(0, width: pinCount),
          irqEdge < Const(0, width: pinCount),
          prevInput < Const(0, width: pinCount),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          prevInput < gpioIn,

          // Edge detection: set status on rising edge
          for (var i = 0; i < pinCount && i < 32; i++)
            If(
              irqEdge[i] & gpioIn[i] & ~prevInput[i],
              then: [irqStatus < (irqStatus | Const(1 << i, width: pinCount))],
            ),
          // Level detection: set status when pin high
          for (var i = 0; i < pinCount && i < 32; i++)
            If(
              ~irqEdge[i] & gpioIn[i],
              then: [irqStatus < (irqStatus | Const(1 << i, width: pinCount))],
            ),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              Case(bus.addr.getRange(0, 5), [
                // 0x00: INPUT
                CaseItem(Const(0x00, width: 5), [
                  bus.dataOut < gpioIn.zeroExtend(32),
                ]),
                // 0x04: OUTPUT
                CaseItem(Const(0x04 >> 2, width: 5), [
                  If(
                    bus.we,
                    then: [outputReg < bus.dataIn.getRange(0, pinCount)],
                    orElse: [bus.dataOut < outputReg.zeroExtend(32)],
                  ),
                ]),
                // 0x08: DIR
                CaseItem(Const(0x08 >> 2, width: 5), [
                  If(
                    bus.we,
                    then: [dirReg < bus.dataIn.getRange(0, pinCount)],
                    orElse: [bus.dataOut < dirReg.zeroExtend(32)],
                  ),
                ]),
                // 0x0C: IRQ_EN
                CaseItem(Const(0x0C >> 2, width: 5), [
                  If(
                    bus.we,
                    then: [irqEn < bus.dataIn.getRange(0, pinCount)],
                    orElse: [bus.dataOut < irqEn.zeroExtend(32)],
                  ),
                ]),
                // 0x10: IRQ_STATUS (write-1-to-clear)
                CaseItem(Const(0x10 >> 2, width: 5), [
                  If(
                    bus.we,
                    then: [
                      irqStatus <
                          (irqStatus & ~bus.dataIn.getRange(0, pinCount)),
                    ],
                    orElse: [bus.dataOut < irqStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x14: IRQ_EDGE
                CaseItem(Const(0x14 >> 2, width: 5), [
                  If(
                    bus.we,
                    then: [irqEdge < bus.dataIn.getRange(0, pinCount)],
                    orElse: [bus.dataOut < irqEdge.zeroExtend(32)],
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
    compatible: ['harbor,gpio', 'sifive,gpio0'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'ngpios': pinCount, '#gpio-cells': 2, 'gpio-controller': true},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,gpio', 'sifive,gpio0'],
      'ngpios': pinCount,
      '#gpio-cells': 2,
      'gpio-controller': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'GPIO',
    groupName: 'GPIO',
    description: 'General-purpose I/O controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
