import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// Power domain state.
enum HarborPowerDomainState { off, retention, on }

/// Power domain configuration.
class HarborPowerDomain {
  /// Domain name.
  final String name;

  /// Domain index.
  final int index;

  /// Whether this domain can be powered off.
  final bool canPowerOff;

  /// Whether this domain supports retention.
  final bool canRetain;

  const HarborPowerDomain({
    required this.name,
    required this.index,
    this.canPowerOff = true,
    this.canRetain = true,
  });
}

/// Power Management Unit configuration.
class HarborPmuConfig with HarborPrettyString {
  /// Power domains managed by this PMU.
  final List<HarborPowerDomain> domains;

  /// Number of voltage regulators.
  final int regulators;

  /// Whether DVFS (Dynamic Voltage and Frequency Scaling) is supported.
  final bool supportsDvfs;

  const HarborPmuConfig({
    required this.domains,
    this.regulators = 1,
    this.supportsDvfs = false,
  });

  @override
  String toString() => 'HarborPmuConfig(${domains.length} domains)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborPmuConfig(\n');
    buf.writeln('${c}domains: ${domains.length},');
    buf.writeln('${c}regulators: $regulators,');
    if (supportsDvfs) buf.writeln('${c}DVFS,');
    for (final d in domains) {
      buf.writeln('$c  ${d.name}: off=${d.canPowerOff}, retain=${d.canRetain}');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// Power Management Unit.
///
/// Controls power domains, voltage regulators, and system power
/// states. Supports domain power gating and retention.
///
/// Register map:
/// - 0x00: CTRL         (global enable, system sleep mode)
/// - 0x04: STATUS       (current system power state)
/// - 0x08: WAKEUP_EN    (wakeup source enable mask)
/// - 0x0C: WAKEUP_STATUS (which source triggered wakeup, W1C)
/// - Per-domain (0x40 + domain*0x10):
///   - +0x00: DOM_CTRL   (target state: off/retention/on)
///   - +0x04: DOM_STATUS (current state, transition busy)
///   - +0x08: DOM_ISO    (isolation control)
class HarborPowerManagementUnit extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// PMU configuration.
  final HarborPmuConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Interrupt output (wakeup event).
  Logic get interrupt => output('interrupt');

  /// Per-domain power enable outputs.
  late final List<Logic> domainPower;

  HarborPowerManagementUnit({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('PMU', name: name ?? 'pmu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('interrupt');

    domainPower = List.generate(
      config.domains.length,
      (i) => addOutput('domain_${config.domains[i].name}_power'),
    );

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 8,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final domainCount = config.domains.length;

    final globalEnable = Logic(name: 'global_enable');
    final sleepMode = Logic(name: 'sleep_mode', width: 2);
    final wakeupEn = Logic(name: 'wakeup_en', width: 8);
    final wakeupStatus = Logic(name: 'wakeup_status', width: 8);

    final domState = List.generate(
      domainCount,
      (i) => Logic(name: 'dom${i}_state', width: 2),
    );
    final domTarget = List.generate(
      domainCount,
      (i) => Logic(name: 'dom${i}_target', width: 2),
    );
    final domIso = List.generate(
      domainCount,
      (i) => Logic(name: 'dom${i}_iso'),
    );

    interrupt <= wakeupStatus.or();

    for (var i = 0; i < domainCount; i++) {
      domainPower[i] <=
          domState[i].eq(Const(HarborPowerDomainState.on.index, width: 2));
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          globalEnable < Const(1),
          sleepMode < Const(0, width: 2),
          wakeupEn < Const(0, width: 8),
          wakeupStatus < Const(0, width: 8),
          for (var i = 0; i < domainCount; i++) ...[
            domState[i] < Const(HarborPowerDomainState.on.index, width: 2),
            domTarget[i] < Const(HarborPowerDomainState.on.index, width: 2),
            domIso[i] < Const(0),
          ],
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // Domain power state transitions
          for (var i = 0; i < domainCount; i++)
            If(
              domState[i].neq(domTarget[i]),
              then: [domState[i] < domTarget[i]],
            ),

          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers
              If(
                bus.addr.getRange(6, 8).eq(Const(0, width: 2)),
                then: [
                  Case(bus.addr.getRange(0, 2), [
                    CaseItem(Const(0, width: 2), [
                      If(
                        bus.we,
                        then: [
                          globalEnable < bus.dataIn[0],
                          sleepMode < bus.dataIn.getRange(4, 6),
                        ],
                        orElse: [
                          bus.dataOut <
                              globalEnable.zeroExtend(32) |
                                  (sleepMode.zeroExtend(32) <<
                                      Const(4, width: 32)),
                        ],
                      ),
                    ]),
                    CaseItem(Const(1, width: 2), [
                      bus.dataOut < sleepMode.zeroExtend(32),
                    ]),
                    CaseItem(Const(2, width: 2), [
                      If(
                        bus.we,
                        then: [wakeupEn < bus.dataIn.getRange(0, 8)],
                        orElse: [bus.dataOut < wakeupEn.zeroExtend(32)],
                      ),
                    ]),
                    CaseItem(Const(3, width: 2), [
                      If(
                        bus.we,
                        then: [
                          wakeupStatus <
                              (wakeupStatus & ~bus.dataIn.getRange(0, 8)),
                        ],
                        orElse: [bus.dataOut < wakeupStatus.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-domain registers (0x40 + domain*0x10)
              for (var d = 0; d < domainCount; d++)
                If(
                  bus.addr.getRange(4, 8).eq(Const(4 + d, width: 4)),
                  then: [
                    Case(bus.addr.getRange(0, 2), [
                      CaseItem(Const(0, width: 2), [
                        If(
                          bus.we,
                          then: [domTarget[d] < bus.dataIn.getRange(0, 2)],
                          orElse: [bus.dataOut < domTarget[d].zeroExtend(32)],
                        ),
                      ]),
                      CaseItem(Const(1, width: 2), [
                        bus.dataOut <
                            domState[d].zeroExtend(32) |
                                (domState[d].neq(domTarget[d]).zeroExtend(32) <<
                                    Const(8, width: 32)),
                      ]),
                      CaseItem(Const(2, width: 2), [
                        If(
                          bus.we,
                          then: [domIso[d] < bus.dataIn[0]],
                          orElse: [bus.dataOut < domIso[d].zeroExtend(32)],
                        ),
                      ]),
                    ]),
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,pmu'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      '#power-domain-cells': 1,
      'num-domains': config.domains.length,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,pmu'],
      '#power-domain-cells': 1,
      'num-domains': config.domains.length,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'PMU',
    groupName: 'PMU',
    description: 'Power Management Unit',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
