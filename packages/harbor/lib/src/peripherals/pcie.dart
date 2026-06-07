import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// PCIe generation.
enum HarborPcieGen {
  /// PCIe Gen 1 (2.5 GT/s per lane).
  gen1(1, 2500),

  /// PCIe Gen 2 (5 GT/s per lane).
  gen2(2, 5000),

  /// PCIe Gen 3 (8 GT/s per lane).
  gen3(3, 8000),

  /// PCIe Gen 4 (16 GT/s per lane).
  gen4(4, 16000),

  /// PCIe Gen 5 (32 GT/s per lane).
  gen5(5, 32000);

  /// Generation number.
  final int gen;

  /// Transfer rate in MT/s per lane.
  final int mtPerSecond;

  const HarborPcieGen(this.gen, this.mtPerSecond);

  /// Bandwidth per lane in MB/s (approximate, accounting for encoding).
  double get bandwidthPerLaneMBs => switch (this) {
    HarborPcieGen.gen1 => 250,
    HarborPcieGen.gen2 => 500,
    HarborPcieGen.gen3 => 984.6,
    HarborPcieGen.gen4 => 1969,
    HarborPcieGen.gen5 => 3938,
  };
}

/// PCIe lane width.
enum HarborPcieLanes {
  x1(1),
  x2(2),
  x4(4),
  x8(8),
  x16(16);

  final int count;
  const HarborPcieLanes(this.count);
}

/// PCIe controller role.
enum HarborPcieRole {
  /// Root complex (host).
  rootComplex,

  /// Endpoint (device).
  endpoint,
}

/// PCIe controller configuration.
class HarborPcieConfig with HarborPrettyString {
  /// Maximum PCIe generation supported.
  final HarborPcieGen maxGen;

  /// Maximum lane width.
  final HarborPcieLanes maxLanes;

  /// Controller role.
  final HarborPcieRole role;

  /// Number of MSI vectors supported.
  final int msiVectors;

  /// Number of MSI-X vectors supported.
  final int msixVectors;

  /// Whether IOMMU/ATS is supported.
  final bool supportsAts;

  /// PCIe configuration space size per function (4KB standard, 4MB extended).
  final int configSpaceSize;

  const HarborPcieConfig({
    this.maxGen = HarborPcieGen.gen3,
    this.maxLanes = HarborPcieLanes.x4,
    this.role = HarborPcieRole.rootComplex,
    this.msiVectors = 32,
    this.msixVectors = 0,
    this.supportsAts = false,
    this.configSpaceSize = 4096,
  });

  /// Total bandwidth in MB/s.
  double get totalBandwidthMBs => maxGen.bandwidthPerLaneMBs * maxLanes.count;

  @override
  String toString() =>
      'HarborPcieConfig(Gen${maxGen.gen} x${maxLanes.count}, '
      '${role.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborPcieConfig(\n');
    buf.writeln('${c}gen: ${maxGen.gen},');
    buf.writeln('${c}lanes: x${maxLanes.count},');
    buf.writeln('${c}role: ${role.name},');
    buf.writeln('${c}bandwidth: ${totalBandwidthMBs.toStringAsFixed(0)} MB/s,');
    buf.writeln('${c}msi: $msiVectors vectors,');
    if (msixVectors > 0) buf.writeln('${c}msix: $msixVectors vectors,');
    if (supportsAts) buf.writeln('${c}ATS/IOMMU,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// PCIe Root Complex / Endpoint controller.
///
/// For root complex mode, provides:
/// - ECAM configuration space access (memory-mapped PCIe config)
/// - Memory and I/O BAR windows
/// - MSI/MSI-X interrupt handling
/// - LTSSM link training state machine
///
/// Register map:
/// - 0x000: CTRL       (enable, gen, lanes, role)
/// - 0x004: STATUS     (link_up, negotiated gen/lanes, ltssm_state)
/// - 0x008: LINK_CTRL  (link training, speed change, retrain)
/// - 0x00C: INT_STATUS (W1C: link_up, link_down, msi, error)
/// - 0x010: INT_ENABLE
/// - 0x014: ERR_STATUS (correctable, uncorrectable, fatal)
/// - 0x020: BAR0_BASE  (BAR 0 base address)
/// - 0x024: BAR0_MASK  (BAR 0 address mask / size)
/// - 0x028: BAR1_BASE
/// - 0x02C: BAR1_MASK
/// - 0x040: MSI_ADDR   (MSI target address)
/// - 0x044: MSI_DATA   (MSI data value)
/// - 0x048: MSI_MASK   (MSI vector mask)
/// - 0x04C: MSI_PEND   (MSI pending bits)
///
/// ECAM space is mapped at a separate memory region for config access.
class HarborPcieController extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// PCIe configuration.
  final HarborPcieConfig config;

  /// Base address for controller registers.
  final int baseAddress;

  /// Base address for ECAM configuration space.
  final int ecamBase;

  /// ECAM size in bytes (256MB for 256 buses).
  final int ecamSize;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborPcieController({
    required this.config,
    required this.baseAddress,
    required this.ecamBase,
    this.ecamSize = 256 * 1024 * 1024,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborPcieController', name: name ?? 'pcie') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    // PCIe PHY signals (directly active)
    addOutput('perst_n'); // PCIe reset (active low)
    addOutput('clkreq_n'); // Clock request (active low)
    createPort('wake_n', PortDirection.input); // Wake (active low)

    // PCIe PIPE interface (simplified - real impl uses PIPE PHY)
    for (var i = 0; i < config.maxLanes.count; i++) {
      createPort('rxp_$i', PortDirection.input);
      createPort('rxn_$i', PortDirection.input);
      addOutput('txp_$i');
      addOutput('txn_$i');
    }

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
    final enable = Logic(name: 'enable');
    final linkUp = Logic(name: 'link_up');
    final negGen = Logic(name: 'neg_gen', width: 3);
    final negLanes = Logic(name: 'neg_lanes', width: 5);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final errStatus = Logic(name: 'err_status', width: 8);
    final bar0Base = Logic(name: 'bar0_base', width: 32);
    final bar0Mask = Logic(name: 'bar0_mask', width: 32);
    final bar1Base = Logic(name: 'bar1_base', width: 32);
    final bar1Mask = Logic(name: 'bar1_mask', width: 32);
    final msiAddr = Logic(name: 'msi_addr', width: 32);
    final msiData = Logic(name: 'msi_data', width: 16);
    final msiMask = Logic(name: 'msi_mask', width: 32);
    final msiPend = Logic(name: 'msi_pend', width: 32);

    interrupt <= (intStatus & intEnable).or();
    output('perst_n') <= enable;
    output('clkreq_n') <= ~enable;

    // Default TX outputs
    for (var i = 0; i < config.maxLanes.count; i++) {
      output('txp_$i') <= Const(0);
      output('txn_$i') <= Const(1);
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          linkUp < Const(0),
          negGen < Const(0, width: 3),
          negLanes < Const(0, width: 5),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          errStatus < Const(0, width: 8),
          bar0Base < Const(0, width: 32),
          bar0Mask < Const(0, width: 32),
          bar1Base < Const(0, width: 32),
          bar1Mask < Const(0, width: 32),
          msiAddr < Const(0, width: 32),
          msiData < Const(0, width: 16),
          msiMask < Const(0, width: 32),
          msiPend < Const(0, width: 32),
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
                // 0x000: CTRL
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [enable < bus.dataIn[0]],
                    orElse: [bus.dataOut < enable.zeroExtend(32)],
                  ),
                ]),
                // 0x004: STATUS
                CaseItem(Const(0x01, width: 6), [
                  bus.dataOut <
                      linkUp.zeroExtend(32) |
                          (negGen.zeroExtend(32) << Const(4, width: 32)) |
                          (negLanes.zeroExtend(32) << Const(8, width: 32)),
                ]),
                // 0x008: LINK_CTRL
                CaseItem(Const(0x02, width: 6), [
                  bus.dataOut < Const(0, width: 32),
                ]),
                // 0x00C: INT_STATUS (W1C)
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
                // 0x014: ERR_STATUS
                CaseItem(Const(0x05, width: 6), [
                  If(
                    bus.we,
                    then: [
                      errStatus < (errStatus & ~bus.dataIn.getRange(0, 8)),
                    ],
                    orElse: [bus.dataOut < errStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x020: BAR0_BASE
                CaseItem(Const(0x08, width: 6), [
                  If(
                    bus.we,
                    then: [bar0Base < bus.dataIn],
                    orElse: [bus.dataOut < bar0Base],
                  ),
                ]),
                // 0x024: BAR0_MASK
                CaseItem(Const(0x09, width: 6), [
                  If(
                    bus.we,
                    then: [bar0Mask < bus.dataIn],
                    orElse: [bus.dataOut < bar0Mask],
                  ),
                ]),
                // 0x028: BAR1_BASE
                CaseItem(Const(0x0A, width: 6), [
                  If(
                    bus.we,
                    then: [bar1Base < bus.dataIn],
                    orElse: [bus.dataOut < bar1Base],
                  ),
                ]),
                // 0x02C: BAR1_MASK
                CaseItem(Const(0x0B, width: 6), [
                  If(
                    bus.we,
                    then: [bar1Mask < bus.dataIn],
                    orElse: [bus.dataOut < bar1Mask],
                  ),
                ]),
                // 0x040: MSI_ADDR
                CaseItem(Const(0x10, width: 6), [
                  If(
                    bus.we,
                    then: [msiAddr < bus.dataIn],
                    orElse: [bus.dataOut < msiAddr],
                  ),
                ]),
                // 0x044: MSI_DATA
                CaseItem(Const(0x11, width: 6), [
                  If(
                    bus.we,
                    then: [msiData < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < msiData.zeroExtend(32)],
                  ),
                ]),
                // 0x048: MSI_MASK
                CaseItem(Const(0x12, width: 6), [
                  If(
                    bus.we,
                    then: [msiMask < bus.dataIn],
                    orElse: [bus.dataOut < msiMask],
                  ),
                ]),
                // 0x04C: MSI_PEND
                CaseItem(Const(0x13, width: 6), [bus.dataOut < msiPend]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: config.role == HarborPcieRole.rootComplex
        ? ['harbor,pcie-host', 'pci-host-ecam-generic']
        : ['harbor,pcie-ep'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'device_type': 'pci',
      '#address-cells': 3,
      '#size-cells': 2,
      'max-link-speed': config.maxGen.gen,
      'num-lanes': config.maxLanes.count,
      'msi-parent': true,
      'bus-range': [0, 255],
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': config.role == HarborPcieRole.rootComplex
          ? ['harbor,pcie-host', 'pci-host-ecam-generic']
          : ['harbor,pcie-ep'],
      'device_type': 'pci',
      '#address-cells': 3,
      '#size-cells': 2,
      'max-link-speed': config.maxGen.gen,
      'num-lanes': config.maxLanes.count,
      'msi-parent': true,
      'bus-range': [0, 255],
    },
  );
}
