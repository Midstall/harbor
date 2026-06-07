import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// USB speed mode.
enum HarborUsbSpeed {
  /// Low speed (1.5 Mbps, USB 1.0).
  low,

  /// Full speed (12 Mbps, USB 1.1).
  full,

  /// High speed (480 Mbps, USB 2.0).
  high,

  /// SuperSpeed (5 Gbps, USB 3.0 / USB 3.2 Gen 1).
  super_,

  /// SuperSpeed+ (10 Gbps, USB 3.1 / USB 3.2 Gen 2).
  superPlus,

  /// SuperSpeed+ (20 Gbps, USB 3.2 Gen 2x2).
  superPlus2x2,
}

/// USB role.
enum HarborUsbRole {
  /// Device (peripheral) mode.
  device,

  /// Host mode.
  host,

  /// OTG (On-The-Go) - supports both.
  otg,
}

/// USB endpoint type.
enum HarborUsbEndpointType { control, isochronous, bulk, interrupt }

/// USB endpoint direction.
enum HarborUsbEndpointDirection {
  /// OUT: host to device.
  out_,

  /// IN: device to host.
  in_,
}

/// USB endpoint configuration.
class HarborUsbEndpoint {
  /// Endpoint number (0-15).
  final int number;

  /// Direction.
  final HarborUsbEndpointDirection direction;

  /// Transfer type.
  final HarborUsbEndpointType type;

  /// Maximum packet size in bytes.
  final int maxPacketSize;

  const HarborUsbEndpoint({
    required this.number,
    required this.direction,
    required this.type,
    this.maxPacketSize = 64,
  });
}

/// USB controller configuration.
class HarborUsbConfig with HarborPrettyString {
  /// Maximum speed supported.
  final HarborUsbSpeed maxSpeed;

  /// Controller role.
  final HarborUsbRole role;

  /// Number of endpoints (including EP0).
  final int endpointCount;

  /// FIFO buffer size per endpoint in bytes.
  final int fifoSize;

  const HarborUsbConfig({
    this.maxSpeed = HarborUsbSpeed.full,
    this.role = HarborUsbRole.device,
    this.endpointCount = 4,
    this.fifoSize = 64,
  });

  /// Whether this configuration includes USB 3.x SuperSpeed.
  bool get isSuperSpeed =>
      maxSpeed == HarborUsbSpeed.super_ ||
      maxSpeed == HarborUsbSpeed.superPlus ||
      maxSpeed == HarborUsbSpeed.superPlus2x2;

  /// Whether this configuration includes USB 2.0 High Speed.
  bool get isHighSpeed => isSuperSpeed || maxSpeed == HarborUsbSpeed.high;

  @override
  String toString() =>
      'HarborUsbConfig(${maxSpeed.name}, ${role.name}, '
      '$endpointCount EPs)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborUsbConfig(\n');
    buf.writeln('${c}speed: ${maxSpeed.name},');
    buf.writeln('${c}role: ${role.name},');
    buf.writeln('${c}endpoints: $endpointCount,');
    buf.writeln('${c}fifoSize: $fifoSize bytes,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// USB controller peripheral.
///
/// Register map:
/// - 0x000: CTRL       (enable, speed, role, reset)
/// - 0x004: STATUS     (connected, suspended, speed_actual, ep0_setup)
/// - 0x008: ADDR       (device address, set after SET_ADDRESS)
/// - 0x00C: INT_STATUS (interrupt status, write-1-to-clear)
/// - 0x010: INT_ENABLE (interrupt enable mask)
/// - 0x014: FRAME      (current frame number, read-only)
///
/// Per-endpoint registers (base + 0x100 + ep*0x20):
/// - +0x00: EP_CTRL    (enable, type, direction, stall)
/// - +0x04: EP_STATUS  (data ready, nak, stall, setup)
/// - +0x08: EP_BUFSIZE (max packet size)
/// - +0x0C: EP_TXDATA  (write TX byte)
/// - +0x10: EP_RXDATA  (read RX byte)
/// - +0x14: EP_TXLEN   (TX packet length)
/// - +0x18: EP_RXLEN   (RX packet length, read-only)
class HarborUsbController extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// USB configuration.
  final HarborUsbConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborUsbController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborUsbController', name: name ?? 'usb') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // USB 2.0 PHY pins (always present for backwards compatibility)
    createPort('usb_dp_in', PortDirection.input); // D+ input
    createPort('usb_dm_in', PortDirection.input); // D- input
    addOutput('usb_dp_out'); // D+ output
    addOutput('usb_dm_out'); // D- output
    addOutput('usb_oe'); // output enable
    addOutput('usb_pullup'); // 1.5k pullup for device mode

    // USB 3.x SuperSpeed PHY pins (only when SuperSpeed is configured)
    if (config.isSuperSpeed) {
      createPort('ss_rx_p', PortDirection.input); // SuperSpeed RX+
      createPort('ss_rx_n', PortDirection.input); // SuperSpeed RX-
      addOutput('ss_tx_p'); // SuperSpeed TX+
      addOutput('ss_tx_n'); // SuperSpeed TX-
      addOutput('ss_tx_oe'); // SuperSpeed TX output enable
    }

    addOutput('interrupt');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Global registers
    final ctrlEnable = Logic(name: 'ctrl_enable');
    final deviceAddr = Logic(name: 'device_addr', width: 7);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final connected = Logic(name: 'connected');
    final frameNum = Logic(name: 'frame_num', width: 11);

    // Pullup for device mode detection
    output('usb_pullup') <= ctrlEnable;
    output('usb_dp_out') <= Const(0);
    output('usb_dm_out') <= Const(0);
    output('usb_oe') <= Const(0);

    interrupt <= (intStatus & intEnable).or();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlEnable < Const(0),
          deviceAddr < Const(0, width: 7),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          connected < Const(0),
          frameNum < Const(0, width: 11),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // Frame counter (increments every 1ms at full speed)
          If(ctrlEnable, then: [frameNum < (frameNum + Const(1, width: 11))]),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (0x000-0x0FF)
              If(
                ~bus.addr[8],
                then: [
                  Case(bus.addr.getRange(0, 6), [
                    // 0x000: CTRL
                    CaseItem(Const(0x00, width: 6), [
                      If(
                        bus.we,
                        then: [ctrlEnable < bus.dataIn[0]],
                        orElse: [bus.dataOut < ctrlEnable.zeroExtend(32)],
                      ),
                    ]),
                    // 0x004: STATUS
                    CaseItem(Const(0x01, width: 6), [
                      bus.dataOut <
                          connected.zeroExtend(32) |
                              (Const(config.maxSpeed.index, width: 32) <<
                                  Const(4, width: 32)),
                    ]),
                    // 0x008: ADDR
                    CaseItem(Const(0x02, width: 6), [
                      If(
                        bus.we,
                        then: [deviceAddr < bus.dataIn.getRange(0, 7)],
                        orElse: [bus.dataOut < deviceAddr.zeroExtend(32)],
                      ),
                    ]),
                    // 0x00C: INT_STATUS (write-1-to-clear)
                    CaseItem(Const(0x03, width: 6), [
                      If(
                        bus.we,
                        then: [
                          intStatus < (intStatus & ~bus.dataIn.getRange(0, 8)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // 0x010: INT_ENABLE
                    CaseItem(Const(0x04, width: 6), [
                      If(
                        bus.we,
                        then: [intEnable < bus.dataIn.getRange(0, 8)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                    // 0x014: FRAME
                    CaseItem(Const(0x05, width: 6), [
                      bus.dataOut < frameNum.zeroExtend(32),
                    ]),
                  ]),
                ],
              ),

              // Per-endpoint registers would go at 0x100 + ep*0x20
              // Implementation left for the USB protocol engine
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,usb'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'maximum-speed': _dtSpeedString(config.maxSpeed),
      'dr_mode': config.role == HarborUsbRole.otg ? 'otg' : config.role.name,
      'num-endpoints': config.endpointCount,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,usb'],
      'maximum-speed': _dtSpeedString(config.maxSpeed),
      'dr_mode': config.role == HarborUsbRole.otg ? 'otg' : config.role.name,
      'num-endpoints': config.endpointCount,
    },
  );
}

/// Maps HarborUsbSpeed to the Linux DT `maximum-speed` string.
String _dtSpeedString(HarborUsbSpeed speed) => switch (speed) {
  HarborUsbSpeed.low => 'low-speed',
  HarborUsbSpeed.full => 'full-speed',
  HarborUsbSpeed.high => 'high-speed',
  HarborUsbSpeed.super_ => 'super-speed',
  HarborUsbSpeed.superPlus => 'super-speed-plus',
  HarborUsbSpeed.superPlus2x2 => 'super-speed-plus',
};
