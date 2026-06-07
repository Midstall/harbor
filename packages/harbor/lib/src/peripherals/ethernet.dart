import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// Ethernet PHY interface type.
enum HarborEthernetPhyInterface {
  /// MII (Media Independent Interface, 10/100 Mbps).
  mii,

  /// RMII (Reduced MII, 10/100 Mbps).
  rmii,

  /// GMII (Gigabit MII, 10/100/1000 Mbps).
  gmii,

  /// RGMII (Reduced GMII, 10/100/1000 Mbps).
  rgmii,

  /// SGMII (Serial GMII, 10/100/1000 Mbps).
  sgmii,
}

/// Ethernet speed.
enum HarborEthernetSpeed {
  /// 10 Mbps.
  speed10(10),

  /// 100 Mbps.
  speed100(100),

  /// 1000 Mbps (Gigabit).
  speed1000(1000);

  final int mbps;
  const HarborEthernetSpeed(this.mbps);
}

/// Ethernet MAC configuration.
class HarborEthernetConfig with HarborPrettyString {
  /// Maximum speed supported.
  final HarborEthernetSpeed maxSpeed;

  /// PHY interface type.
  final HarborEthernetPhyInterface phyInterface;

  /// Number of TX descriptor ring entries.
  final int txDescriptors;

  /// Number of RX descriptor ring entries.
  final int rxDescriptors;

  /// TX FIFO depth in bytes.
  final int txFifoSize;

  /// RX FIFO depth in bytes.
  final int rxFifoSize;

  /// Whether hardware checksum offload is supported.
  final bool checksumOffload;

  const HarborEthernetConfig({
    this.maxSpeed = HarborEthernetSpeed.speed1000,
    this.phyInterface = HarborEthernetPhyInterface.rgmii,
    this.txDescriptors = 64,
    this.rxDescriptors = 64,
    this.txFifoSize = 2048,
    this.rxFifoSize = 2048,
    this.checksumOffload = false,
  });

  @override
  String toString() =>
      'HarborEthernetConfig(${maxSpeed.mbps} Mbps, ${phyInterface.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborEthernetConfig(\n');
    buf.writeln('${c}speed: ${maxSpeed.mbps} Mbps,');
    buf.writeln('${c}phy: ${phyInterface.name},');
    buf.writeln('${c}txDesc: $txDescriptors, rxDesc: $rxDescriptors,');
    buf.writeln('${c}txFifo: $txFifoSize, rxFifo: $rxFifoSize,');
    if (checksumOffload) buf.writeln('${c}checksum offload,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// Ethernet MAC controller.
///
/// Register map:
/// - 0x000: MAC_CTRL    (enable, speed, duplex, loopback)
/// - 0x004: MAC_STATUS  (link, speed_actual, rx_ready, tx_ready)
/// - 0x008: MAC_ADDR_LO (MAC address bytes 0-3)
/// - 0x00C: MAC_ADDR_HI (MAC address bytes 4-5)
/// - 0x010: INT_STATUS  (W1C)
/// - 0x014: INT_ENABLE
/// - 0x020: TX_CTRL     (enable, descriptor ring base)
/// - 0x024: TX_STATUS   (busy, descriptors used)
/// - 0x028: TX_DESC_BASE (TX descriptor ring base address)
/// - 0x030: RX_CTRL     (enable, descriptor ring base)
/// - 0x034: RX_STATUS   (busy, descriptors available)
/// - 0x038: RX_DESC_BASE (RX descriptor ring base address)
/// - 0x040: MDIO_CTRL   (PHY management: addr, reg, write, busy)
/// - 0x044: MDIO_DATA   (PHY management data)
class HarborEthernetMac extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// MAC configuration.
  final HarborEthernetConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborEthernetMac({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborEthernetMac', name: name ?? 'ethernet') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    // MDIO management interface
    addOutput('mdc'); // Management clock
    createPort('mdio_in', PortDirection.input);
    addOutput('mdio_out');
    addOutput('mdio_oe');

    // PHY interface pins (RGMII shown, other interfaces would differ)
    addOutput('tx_clk');
    addOutput('tx_en');
    addOutput(
      'txd',
      width: config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4,
    );
    createPort('rx_clk', PortDirection.input);
    createPort('rx_dv', PortDirection.input);
    createPort(
      'rxd',
      PortDirection.input,
      width: config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4,
    );

    // DMA master interface for descriptor/data access
    addOutput('dma_addr', width: 32);
    addOutput('dma_wdata', width: 32);
    createPort('dma_rdata', PortDirection.input, width: 32);
    addOutput('dma_we');
    addOutput('dma_stb');
    createPort('dma_ack', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 8,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Registers
    final macEnable = Logic(name: 'mac_enable');
    final macAddrLo = Logic(name: 'mac_addr_lo', width: 32);
    final macAddrHi = Logic(name: 'mac_addr_hi', width: 16);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final txEnable = Logic(name: 'tx_enable');
    final rxEnable = Logic(name: 'rx_enable');
    final txDescBase = Logic(name: 'tx_desc_base', width: 32);
    final rxDescBase = Logic(name: 'rx_desc_base', width: 32);
    final mdioCtrl = Logic(name: 'mdio_ctrl', width: 32);
    final mdioData = Logic(name: 'mdio_data', width: 16);

    interrupt <= (intStatus & intEnable).or();

    // Default PHY outputs
    output('tx_clk') <= Const(0);
    output('tx_en') <= Const(0);
    output('txd') <=
        Const(
          0,
          width: config.maxSpeed == HarborEthernetSpeed.speed1000 ? 8 : 4,
        );
    output('mdc') <= Const(0);
    output('mdio_out') <= Const(0);
    output('mdio_oe') <= Const(0);
    output('dma_addr') <= Const(0, width: 32);
    output('dma_wdata') <= Const(0, width: 32);
    output('dma_we') <= Const(0);
    output('dma_stb') <= Const(0);

    Sequential(clk, [
      If(
        reset,
        then: [
          macEnable < Const(0),
          macAddrLo < Const(0, width: 32),
          macAddrHi < Const(0, width: 16),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          txEnable < Const(0),
          rxEnable < Const(0),
          txDescBase < Const(0, width: 32),
          rxDescBase < Const(0, width: 32),
          mdioCtrl < Const(0, width: 32),
          mdioData < Const(0, width: 16),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              Case(bus.addr.getRange(0, 6), [
                // 0x000: MAC_CTRL
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [macEnable < bus.dataIn[0]],
                    orElse: [bus.dataOut < macEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x004: MAC_STATUS
                CaseItem(Const(0x01, width: 6), [
                  bus.dataOut <
                      txEnable.zeroExtend(32) |
                          (rxEnable.zeroExtend(32) << Const(1, width: 32)),
                ]),
                // 0x008: MAC_ADDR_LO
                CaseItem(Const(0x02, width: 6), [
                  If(
                    bus.we,
                    then: [macAddrLo < bus.dataIn],
                    orElse: [bus.dataOut < macAddrLo],
                  ),
                ]),
                // 0x00C: MAC_ADDR_HI
                CaseItem(Const(0x03, width: 6), [
                  If(
                    bus.we,
                    then: [macAddrHi < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < macAddrHi.zeroExtend(32)],
                  ),
                ]),
                // 0x010: INT_STATUS (W1C)
                CaseItem(Const(0x04, width: 6), [
                  If(
                    bus.we,
                    then: [
                      intStatus < (intStatus & ~bus.dataIn.getRange(0, 8)),
                    ],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x014: INT_ENABLE
                CaseItem(Const(0x05, width: 6), [
                  If(
                    bus.we,
                    then: [intEnable < bus.dataIn.getRange(0, 8)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x020: TX_CTRL
                CaseItem(Const(0x08, width: 6), [
                  If(
                    bus.we,
                    then: [txEnable < bus.dataIn[0]],
                    orElse: [bus.dataOut < txEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x028: TX_DESC_BASE
                CaseItem(Const(0x0A, width: 6), [
                  If(
                    bus.we,
                    then: [txDescBase < bus.dataIn],
                    orElse: [bus.dataOut < txDescBase],
                  ),
                ]),
                // 0x030: RX_CTRL
                CaseItem(Const(0x0C, width: 6), [
                  If(
                    bus.we,
                    then: [rxEnable < bus.dataIn[0]],
                    orElse: [bus.dataOut < rxEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x038: RX_DESC_BASE
                CaseItem(Const(0x0E, width: 6), [
                  If(
                    bus.we,
                    then: [rxDescBase < bus.dataIn],
                    orElse: [bus.dataOut < rxDescBase],
                  ),
                ]),
                // 0x040: MDIO_CTRL
                CaseItem(Const(0x10, width: 6), [
                  If(
                    bus.we,
                    then: [mdioCtrl < bus.dataIn],
                    orElse: [bus.dataOut < mdioCtrl],
                  ),
                ]),
                // 0x044: MDIO_DATA
                CaseItem(Const(0x11, width: 6), [
                  If(
                    bus.we,
                    then: [mdioData < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < mdioData.zeroExtend(32)],
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
    compatible: ['harbor,ethernet'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'phy-mode': config.phyInterface.name,
      'max-speed': config.maxSpeed.mbps,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,ethernet'],
      'phy-mode': config.phyInterface.name,
      'max-speed': config.maxSpeed.mbps,
    },
  );
}
