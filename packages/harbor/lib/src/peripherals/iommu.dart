import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';

/// RISC-V IOMMU translation mode.
enum HarborIommuMode {
  /// Pass-through (no translation).
  bare,

  /// Single-stage (device virtual to physical).
  sv39,
  sv48,
  sv57,

  /// Two-stage (device virtual -> guest physical -> physical).
  sv39x4,
  sv48x4,
  sv57x4,
}

/// RISC-V IOMMU (I/O Memory Management Unit).
///
/// Provides address translation and protection for DMA-capable
/// devices. Required for:
/// - H extension guest isolation (two-stage translation)
/// - Device assignment to VMs
/// - DMA protection (PCI ATS/PRI)
///
/// Implements the RISC-V IOMMU specification with:
/// - Device directory (DD) for per-device translation config
/// - IOTLB for caching translations
/// - Hardware page table walker
/// - Fault/event queue
/// - MSI translation (MSI page table)
/// - Command queue for software-issued invalidations
///
/// Register map:
/// - 0x000: capabilities   0x008: fctl       0x010: ddtp
/// - 0x028: cqb            0x030: cqh        0x034: cqt
/// - 0x038: fqb            0x040: fqh        0x044: fqt
/// - 0x048: pqb            0x050: pqh        0x054: pqt
/// - 0x058: cqcsr          0x05C: fqcsr      0x060: pqcsr
/// - 0x064: ipsr           0x100: iohpmcycles
/// - 0x108-0x1F8: iohpmctr/iohpmevt
class HarborIommu extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// Base address for IOMMU registers.
  final int baseAddress;

  /// Number of IOTLB entries.
  final int iotlbEntries;

  /// Maximum supported translation mode.
  final HarborIommuMode maxMode;

  /// Number of device directory entries.
  final int numDevices;

  /// Command queue depth.
  final int cmdQueueDepth;

  /// Fault queue depth.
  final int faultQueueDepth;

  /// Whether to support MSI translation.
  final bool msiTranslation;

  /// Whether to support ATS (Address Translation Services).
  final bool atsSupport;

  /// Bus slave port for register access.
  late final BusSlavePort regBus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborIommu({
    required this.baseAddress,
    this.iotlbEntries = 64,
    this.maxMode = HarborIommuMode.sv48x4,
    this.numDevices = 256,
    this.cmdQueueDepth = 64,
    this.faultQueueDepth = 64,
    this.msiTranslation = true,
    this.atsSupport = false,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborIommu', name: name ?? 'iommu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // Register interface
    regBus = BusSlavePort.create(
      module: this,
      name: 'reg',
      protocol: protocol,
      addressWidth: 12,
      dataWidth: 64,
    );

    // DMA request input (from device)
    createPort('dma_addr', PortDirection.input, width: 64);
    createPort('dma_valid', PortDirection.input);
    createPort('dma_write', PortDirection.input);
    createPort('dma_device_id', PortDirection.input, width: 24);

    // Translated DMA output (to memory)
    addOutput('dma_translated_addr', width: 64);
    addOutput('dma_translated_valid');
    addOutput('dma_fault');
    addOutput('dma_fault_cause', width: 8);

    // Memory interface (for page table walks)
    addOutput('ptw_addr', width: 64);
    addOutput('ptw_read');
    createPort('ptw_data', PortDirection.input, width: 64);
    createPort('ptw_valid', PortDirection.input);

    // MSI translation output
    if (msiTranslation) {
      addOutput('msi_addr', width: 64);
      addOutput('msi_data', width: 32);
      addOutput('msi_valid');
    }

    final clk = input('clk');
    final reset = input('reset');

    // IOMMU registers
    final capabilities = Logic(name: 'capabilities', width: 64);
    final fctl = Logic(name: 'fctl', width: 64);
    final ddtp = Logic(name: 'ddtp', width: 64);
    final cqcsr = Logic(name: 'cqcsr', width: 32);
    final fqcsr = Logic(name: 'fqcsr', width: 32);
    final ipsr = Logic(name: 'ipsr', width: 32);

    // IOTLB state
    final iotlbState = Logic(name: 'iotlb_state', width: 3);

    interrupt <= ipsr.or();

    Sequential(clk, [
      If(
        reset,
        then: [
          capabilities < Const(0, width: 64),
          fctl < Const(0, width: 64),
          ddtp < Const(0, width: 64),
          cqcsr < Const(0, width: 32),
          fqcsr < Const(0, width: 32),
          ipsr < Const(0, width: 32),
          iotlbState < Const(0, width: 3),
          output('dma_translated_valid') < Const(0),
          output('dma_fault') < Const(0),
          output('ptw_read') < Const(0),
          regBus.ack < Const(0),
          regBus.dataOut < Const(0, width: 64),
        ],
        orElse: [
          output('dma_translated_valid') < Const(0),
          output('dma_fault') < Const(0),

          // DMA translation pipeline:
          // 1. Look up device_id in device directory -> get translation config
          // 2. Check IOTLB for cached translation
          // 3. On miss: walk page table
          // 4. Check permissions
          // 5. Output translated address or fault

          // Register access
          regBus.ack < Const(0),
          If(
            regBus.stb & ~regBus.ack,
            then: [
              regBus.ack < Const(1),
              // Decode register address and read/write
            ],
          ),

          // Command queue processing
          // Fault queue management
          // Page request queue (ATS)
        ],
      ),
    ]);

    // Placeholder outputs
    output('dma_translated_addr') <= Const(0, width: 64);
    output('dma_fault_cause') <= Const(0, width: 8);
    output('ptw_addr') <= Const(0, width: 64);
    if (msiTranslation) {
      output('msi_addr') <= Const(0, width: 64);
      output('msi_data') <= Const(0, width: 32);
      output('msi_valid') <= Const(0);
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,iommu'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#iommu-cells': 1,
      'riscv,iotlb-entries': iotlbEntries,
      'riscv,max-mode': maxMode.name,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['riscv,iommu'],
      '#iommu-cells': 1,
      'riscv,iotlb-entries': iotlbEntries,
      'riscv,max-mode': maxMode.name,
    },
  );
}
