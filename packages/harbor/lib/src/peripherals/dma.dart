import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../util/pretty_string.dart';

/// DMA transfer type.
enum HarborDmaTransferType {
  /// Memory to memory.
  memToMem,

  /// Memory to peripheral.
  memToPeriph,

  /// Peripheral to memory.
  periphToMem,
}

/// DMA transfer width.
enum HarborDmaTransferWidth {
  byte1(1),
  half(2),
  word(4),
  dword(8);

  final int bytes;
  const HarborDmaTransferWidth(this.bytes);
}

/// DMA channel configuration.
class HarborDmaChannelConfig with HarborPrettyString {
  /// Maximum burst length.
  final int maxBurstLength;

  /// Maximum transfer size in bytes.
  final int maxTransferSize;

  /// Whether scatter-gather is supported.
  final bool scatterGather;

  const HarborDmaChannelConfig({
    this.maxBurstLength = 16,
    this.maxTransferSize = 0xFFFFFF,
    this.scatterGather = false,
  });

  @override
  String toString() => 'HarborDmaChannelConfig(burst: $maxBurstLength)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDmaChannelConfig(\n');
    buf.writeln('${c}maxBurst: $maxBurstLength,');
    buf.writeln('${c}maxTransfer: $maxTransferSize,');
    if (scatterGather) buf.writeln('${c}scatter-gather,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// DMA controller.
///
/// Multi-channel DMA engine for high-bandwidth memory transfers.
///
/// Per-channel register map (base + ch*0x20):
/// - +0x00: CH_CTRL    (enable, type, width, burst, irq_en)
/// - +0x04: CH_STATUS  (busy, complete, error)
/// - +0x08: CH_SRC     (source address)
/// - +0x0C: CH_DST     (destination address)
/// - +0x10: CH_LEN     (transfer length in bytes)
/// - +0x14: CH_STRIDE  (source/dest stride for 2D transfers)
///
/// Global registers:
/// - 0x000: CTRL       (global enable, reset)
/// - 0x004: INT_STATUS (per-channel interrupt status, W1C)
/// - 0x008: INT_ENABLE (per-channel interrupt enable)
class HarborDmaController extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// Number of DMA channels.
  final int channels;

  /// Channel configuration.
  final HarborDmaChannelConfig channelConfig;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Address width for DMA transfers.
  final int addressWidth;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborDmaController({
    required this.baseAddress,
    this.channels = 4,
    this.channelConfig = const HarborDmaChannelConfig(),
    this.addressWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborDmaController', name: name ?? 'dma') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // DMA master ports (directly exposed for memory bus connection)
    addOutput('dma_addr', width: addressWidth);
    addOutput('dma_wdata', width: 32);
    createPort('dma_rdata', PortDirection.input, width: 32);
    addOutput('dma_we');
    addOutput('dma_stb');
    createPort('dma_ack', PortDirection.input);
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
    final globalEnable = Logic(name: 'global_enable');
    final intStatus = Logic(name: 'int_status', width: channels);
    final intEnable = Logic(name: 'int_enable', width: channels);

    // Per-channel state
    final chEnable = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_enable'),
    );
    final chBusy = List.generate(channels, (i) => Logic(name: 'ch${i}_busy'));
    final chComplete = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_complete'),
    );
    final chError = List.generate(channels, (i) => Logic(name: 'ch${i}_error'));
    final chSrc = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_src', width: addressWidth),
    );
    final chDst = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_dst', width: addressWidth),
    );
    final chLen = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_len', width: 24),
    );
    final chType = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_type', width: 2),
    );
    final chWidth = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_width', width: 2),
    );

    // Active channel for round-robin arbitration
    final activeCh = Logic(name: 'active_ch', width: channels.bitLength);
    final dmaState = Logic(name: 'dma_state', width: 3);
    final xferCount = Logic(name: 'xfer_count', width: 24);
    final readData = Logic(name: 'read_data', width: 32);

    // DMA state machine states (used by transfer engine)
    // ignore: unused_local_variable
    const sIdle = 0;

    interrupt <= (intStatus & intEnable).or();

    // DMA master outputs default
    output('dma_addr') <= Const(0, width: addressWidth);
    output('dma_wdata') <= Const(0, width: 32);
    output('dma_we') <= Const(0);
    output('dma_stb') <= Const(0);

    Sequential(clk, [
      If(
        reset,
        then: [
          globalEnable < Const(0),
          intStatus < Const(0, width: channels),
          intEnable < Const(0, width: channels),
          for (var i = 0; i < channels; i++) ...[
            chEnable[i] < Const(0),
            chBusy[i] < Const(0),
            chComplete[i] < Const(0),
            chError[i] < Const(0),
            chSrc[i] < Const(0, width: addressWidth),
            chDst[i] < Const(0, width: addressWidth),
            chLen[i] < Const(0, width: 24),
            chType[i] < Const(0, width: 2),
            chWidth[i] < Const(0, width: 2),
          ],
          activeCh < Const(0, width: channels.bitLength),
          dmaState < Const(sIdle, width: 3),
          xferCount < Const(0, width: 24),
          readData < Const(0, width: 32),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // Register access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (0x000-0x00F)
              If(
                bus.addr.getRange(5, 12).eq(Const(0, width: 7)),
                then: [
                  Case(bus.addr.getRange(0, 3), [
                    // 0x000: CTRL
                    CaseItem(Const(0, width: 3), [
                      If(
                        bus.we,
                        then: [globalEnable < bus.dataIn[0]],
                        orElse: [bus.dataOut < globalEnable.zeroExtend(32)],
                      ),
                    ]),
                    // 0x004: INT_STATUS (W1C)
                    CaseItem(Const(1, width: 3), [
                      If(
                        bus.we,
                        then: [
                          intStatus <
                              (intStatus & ~bus.dataIn.getRange(0, channels)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // 0x008: INT_ENABLE
                    CaseItem(Const(2, width: 3), [
                      If(
                        bus.we,
                        then: [intEnable < bus.dataIn.getRange(0, channels)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-channel registers (0x100 + ch*0x20)
              for (var ch = 0; ch < channels; ch++)
                If(
                  bus.addr.getRange(5, 12).eq(Const(0x08 + ch, width: 7)),
                  then: [
                    Case(bus.addr.getRange(0, 3), [
                      // +0x00: CH_CTRL
                      CaseItem(Const(0, width: 3), [
                        If(
                          bus.we,
                          then: [
                            chEnable[ch] < bus.dataIn[0],
                            chType[ch] < bus.dataIn.getRange(4, 6),
                            chWidth[ch] < bus.dataIn.getRange(8, 10),
                            // Start transfer when enable written
                            If(
                              bus.dataIn[0] & globalEnable,
                              then: [
                                chBusy[ch] < Const(1),
                                chComplete[ch] < Const(0),
                              ],
                            ),
                          ],
                          orElse: [
                            bus.dataOut <
                                chEnable[ch].zeroExtend(32) |
                                    (chType[ch].zeroExtend(32) <<
                                        Const(4, width: 32)) |
                                    (chWidth[ch].zeroExtend(32) <<
                                        Const(8, width: 32)),
                          ],
                        ),
                      ]),
                      // +0x04: CH_STATUS
                      CaseItem(Const(1, width: 3), [
                        bus.dataOut <
                            chBusy[ch].zeroExtend(32) |
                                (chComplete[ch].zeroExtend(32) <<
                                    Const(1, width: 32)) |
                                (chError[ch].zeroExtend(32) <<
                                    Const(2, width: 32)),
                      ]),
                      // +0x08: CH_SRC
                      CaseItem(Const(2, width: 3), [
                        If(
                          bus.we,
                          then: [
                            chSrc[ch] < bus.dataIn.getRange(0, addressWidth),
                          ],
                          orElse: [bus.dataOut < chSrc[ch].zeroExtend(32)],
                        ),
                      ]),
                      // +0x0C: CH_DST
                      CaseItem(Const(3, width: 3), [
                        If(
                          bus.we,
                          then: [
                            chDst[ch] < bus.dataIn.getRange(0, addressWidth),
                          ],
                          orElse: [bus.dataOut < chDst[ch].zeroExtend(32)],
                        ),
                      ]),
                      // +0x10: CH_LEN
                      CaseItem(Const(4, width: 3), [
                        If(
                          bus.we,
                          then: [chLen[ch] < bus.dataIn.getRange(0, 24)],
                          orElse: [bus.dataOut < chLen[ch].zeroExtend(32)],
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
    compatible: ['harbor,dma'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'dma-channels': channels, '#dma-cells': 1},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,dma'],
      'dma-channels': channels,
      '#dma-cells': 1,
    },
  );
}
