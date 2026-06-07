import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/device_tree.dart';

/// RISC-V Platform-Level Interrupt Controller (PLIC), SiFive-compatible.
///
/// Register map (SiFive PLIC spec):
/// - Priority:       0x000000 + source*4   (4 bytes per source)
/// - Pending:        0x001000              (bitmap, 4 bytes per 32 sources)
/// - Enable:         0x002000 + ctx*0x80   (bitmap per context)
/// - Threshold:      0x200000 + ctx*0x1000 (4 bytes per context)
/// - Claim/Complete: 0x200004 + ctx*0x1000 (4 bytes per context)
///
/// Address space: 64 MB (0x4000000).
class HarborPlic extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int? busDataWidth;
  final int sources;
  final int contexts;
  final int priorityBits;
  final int baseAddress;

  late final List<Logic> externalInterrupt;
  late final List<Logic> sourceInterrupt;

  /// Bus slave port.
  late final BusSlavePort bus;

  HarborPlic({
    required this.baseAddress,
    this.sources = 32,
    this.contexts = 1,
    this.priorityBits = 3,
    int? busAddressWidth,
    this.busDataWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborPlic', name: name ?? 'plic') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: busAddressWidth ?? 26,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final addr = bus.addr.getRange(0, 26);
    final datIn = bus.dataIn.getRange(0, 32);
    final datOut32 = Logic(name: 'plic_dat_out', width: 32);
    bus.dataOut <= datOut32.zeroExtend(bus.dataOut.width);
    final ack = bus.ack;
    final stb = bus.stb;
    final we = bus.we;

    sourceInterrupt = List.generate(sources, (i) {
      createPort('src_irq_$i', PortDirection.input);
      return input('src_irq_$i');
    });

    externalInterrupt = List.generate(contexts, (i) => addOutput('ext_irq_$i'));

    final priority = List.generate(
      sources,
      (i) => Logic(name: 'priority_$i', width: priorityBits),
    );
    final pending = List.generate(sources, (i) => Logic(name: 'pending_$i'));
    final claimed = List.generate(sources, (i) => Logic(name: 'claimed_$i'));
    final enable = List.generate(
      contexts,
      (ctx) =>
          List.generate(sources, (src) => Logic(name: 'enable_${ctx}_$src')),
    );
    final threshold = List.generate(
      contexts,
      (i) => Logic(name: 'threshold_$i', width: priorityBits),
    );

    for (var ctx = 0; ctx < contexts; ctx++) {
      Logic anyPending = Const(0);
      for (var src = 0; src < sources; src++) {
        final active =
            pending[src] &
            enable[ctx][src] &
            ~claimed[src] &
            priority[src].gt(threshold[ctx]);
        anyPending = anyPending | active;
      }
      externalInterrupt[ctx] <= anyPending;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          for (var i = 0; i < sources; i++) ...[
            priority[i] < Const(0, width: priorityBits),
            pending[i] < Const(0),
            claimed[i] < Const(0),
          ],
          for (var ctx = 0; ctx < contexts; ctx++) ...[
            threshold[ctx] < Const(0, width: priorityBits),
            for (var src = 0; src < sources; src++) enable[ctx][src] < Const(0),
          ],
          ack < Const(0),
          datOut32 < Const(0, width: 32),
        ],
        orElse: [
          for (var i = 0; i < sources; i++)
            If(sourceInterrupt[i] & ~claimed[i], then: [pending[i] < Const(1)]),

          ack < Const(0),
          datOut32 < Const(0, width: 32),

          If(
            stb & ~ack,
            then: [
              ack < Const(1),

              for (var src = 0; src < sources; src++)
                If(
                  addr.eq(Const(src * 4, width: 26)),
                  then: [
                    If(
                      we,
                      then: [priority[src] < datIn.getRange(0, priorityBits)],
                      orElse: [datOut32 < priority[src].zeroExtend(32)],
                    ),
                  ],
                ),

              If(
                addr.eq(Const(0x1000, width: 26)),
                then: [
                  datOut32 <
                      [
                        for (
                          var src = (sources > 32 ? 31 : sources - 1);
                          src >= 0;
                          src--
                        )
                          pending[src],
                      ].swizzle().zeroExtend(32),
                ],
              ),

              for (var ctx = 0; ctx < contexts; ctx++)
                If(
                  addr.eq(Const(0x2000 + ctx * 0x80, width: 26)),
                  then: [
                    If(
                      we,
                      then: [
                        for (var src = 0; src < sources && src < 32; src++)
                          enable[ctx][src] < datIn[src],
                      ],
                      orElse: [
                        datOut32 <
                            [
                              for (
                                var src = (sources > 32 ? 31 : sources - 1);
                                src >= 0;
                                src--
                              )
                                enable[ctx][src],
                            ].swizzle().zeroExtend(32),
                      ],
                    ),
                  ],
                ),

              for (var ctx = 0; ctx < contexts; ctx++)
                If(
                  addr.eq(Const(0x200000 + ctx * 0x1000, width: 26)),
                  then: [
                    If(
                      we,
                      then: [threshold[ctx] < datIn.getRange(0, priorityBits)],
                      orElse: [datOut32 < threshold[ctx].zeroExtend(32)],
                    ),
                  ],
                ),

              for (var ctx = 0; ctx < contexts; ctx++)
                If(
                  addr.eq(Const(0x200004 + ctx * 0x1000, width: 26)),
                  then: [
                    If(
                      we,
                      then: [
                        for (var src = 0; src < sources; src++)
                          If(
                            datIn
                                .getRange(0, sources.bitLength)
                                .eq(Const(src, width: sources.bitLength)),
                            then: [
                              claimed[src] < Const(0),
                              pending[src] < Const(0),
                            ],
                          ),
                      ],
                      orElse: [
                        for (var src = 0; src < sources; src++)
                          If(
                            pending[src] & enable[ctx][src] & ~claimed[src],
                            then: [
                              datOut32 < Const(src, width: 32),
                              claimed[src] < Const(1),
                            ],
                          ),
                      ],
                    ),
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
    compatible: ['sifive,plic-1.0.0'],
    reg: BusAddressRange(baseAddress, 0x4000000),
    interruptController: true,
    interruptCells: 1,
    properties: {'riscv,ndev': sources},
  );
}
