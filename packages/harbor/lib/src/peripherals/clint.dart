import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import 'device_register.dart';

/// RISC-V Core Local Interruptor (CLINT), SiFive-compatible.
///
/// Provides per-hart timer and software interrupt functionality.
/// Compatible with Linux `riscv,clint0` driver.
///
/// Register map (per SiFive CLINT spec):
/// - `msip[hart]`:     0x0000 + hart*4  (4 bytes, software interrupt pending)
/// - `mtimecmp[hart]`: 0x4000 + hart*8  (8 bytes, timer compare)
/// - `mtime`:          0xBFF8           (8 bytes, machine timer)
///
/// Address space: 64 KB (0x10000).
class HarborClint extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final int? busDataWidth;

  /// Number of harts this CLINT serves.
  final int hartCount;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Timer interrupt output per hart.
  late final List<Logic> timerInterrupt;

  /// Software interrupt output per hart.
  late final List<Logic> softwareInterrupt;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborClint({
    required this.baseAddress,
    this.hartCount = 1,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborClint', name: name ?? 'clint') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth ?? 16,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final addr = bus.addr.getRange(0, 16);
    final datIn32 = bus.dataIn.getRange(0, 32);
    final datOut32 = Logic(name: 'clint_dat_out', width: 32);
    bus.dataOut <= datOut32.zeroExtend(bus.dataOut.width);
    final ack = bus.ack;
    final stb = bus.stb;
    final we = bus.we;

    timerInterrupt = List.generate(hartCount, (i) => addOutput('timer_irq_$i'));
    softwareInterrupt = List.generate(hartCount, (i) => addOutput('sw_irq_$i'));

    final mtime = Logic(name: 'mtime', width: 64);
    final mtimecmp = List.generate(
      hartCount,
      (i) => Logic(name: 'mtimecmp_$i', width: 64),
    );
    final msip = List.generate(hartCount, (i) => Logic(name: 'msip_$i'));

    for (var i = 0; i < hartCount; i++) {
      timerInterrupt[i] <= mtime.gte(mtimecmp[i]);
      softwareInterrupt[i] <= msip[i];
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          mtime < Const(0, width: 64),
          for (var i = 0; i < hartCount; i++) ...[
            mtimecmp[i] < Const(0, width: 64),
            msip[i] < Const(0),
          ],
          ack < Const(0),
          datOut32 < Const(0, width: 32),
        ],
        orElse: [
          mtime < mtime + Const(1, width: 64),
          ack < Const(0),
          datOut32 < Const(0, width: 32),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              for (var i = 0; i < hartCount; i++) ...[
                If(
                  addr.eq(Const(i * 4, width: 16)),
                  then: [
                    If(
                      we,
                      then: [msip[i] < datIn32[0]],
                      orElse: [datOut32 < msip[i].zeroExtend(32)],
                    ),
                  ],
                ),
              ],

              for (var i = 0; i < hartCount; i++) ...[
                If(
                  addr.eq(Const(0x4000 + i * 8, width: 16)),
                  then: [
                    If(
                      we,
                      then: [
                        mtimecmp[i] <
                            mtimecmp[i] &
                                    (Const(0xFFFFFFFF00000000, width: 64)) |
                                (datIn32.zeroExtend(64)),
                      ],
                      orElse: [datOut32 < mtimecmp[i].getRange(0, 32)],
                    ),
                  ],
                ),
                If(
                  addr.eq(Const(0x4000 + i * 8 + 4, width: 16)),
                  then: [
                    If(
                      we,
                      then: [
                        mtimecmp[i] <
                            mtimecmp[i] &
                                    (Const(0x00000000FFFFFFFF, width: 64)) |
                                (datIn32.zeroExtend(64) <<
                                    Const(32, width: 64)),
                      ],
                      orElse: [datOut32 < mtimecmp[i].getRange(32, 64)],
                    ),
                  ],
                ),
              ],

              If(
                addr.eq(Const(0xBFF8, width: 16)),
                then: [datOut32 < mtime.getRange(0, 32)],
              ),
              If(
                addr.eq(Const(0xBFFC, width: 16)),
                then: [datOut32 < mtime.getRange(32, 64)],
              ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['riscv,clint0'],
    reg: BusAddressRange(baseAddress, 0x10000),
    properties: {'reg-names': 'control'},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x10000)],
    properties: {
      'compatible': ['riscv,clint0'],
      'reg-names': 'control',
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'CLINT',
    groupName: 'CLINT',
    description: 'RISC-V Core Local Interruptor',
    baseAddress: baseAddress,
    size: 0x10000,
    registers: StandardRegisters.clint,
  );
}
