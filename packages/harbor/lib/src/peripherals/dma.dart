import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
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
/// Global registers (block 0):
/// - 0x00: CTRL       (global enable, reset)
/// - 0x04: INT_STATUS (per-channel interrupt status, W1C)
/// - 0x08: INT_ENABLE (per-channel interrupt enable)
///
/// Per-channel register map (channel ch at byte 0x20 + ch*0x20):
/// - +0x00: CH_CTRL    (enable, type, width, irq_en)
/// - +0x04: CH_STATUS  (busy, complete, error)
/// - +0x08: CH_SRC     (source address)
/// - +0x0C: CH_DST     (destination address)
/// - +0x10: CH_LEN     (transfer length in bytes, multiple of 4)
///
/// Transfers move 32-bit words over the master port. CH_TYPE selects whether
/// the source/destination auto-increment (memToMem: both, memToPeriph: source
/// only, periphToMem: destination only).
class HarborDmaController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
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

    // Transfer engine state. The active channel is serviced through shadow
    // pointers/counter so the CPU-visible CH_SRC/CH_DST/CH_LEN stay as
    // programmed.
    final activeCh = Logic(name: 'active_ch', width: channels.bitLength);
    final dmaState = Logic(name: 'dma_state', width: 3);
    final xferCount = Logic(name: 'xfer_count', width: 24);
    final readData = Logic(name: 'read_data', width: 32);
    final curSrc = Logic(name: 'cur_src', width: addressWidth);
    final curDst = Logic(name: 'cur_dst', width: addressWidth);
    final dmaAddrReg = Logic(name: 'dma_addr_reg', width: addressWidth);
    final dmaWdataReg = Logic(name: 'dma_wdata_reg', width: 32);
    final dmaWeReg = Logic(name: 'dma_we_reg');
    final dmaStbReg = Logic(name: 'dma_stb_reg');

    // Transfer engine states.
    const sIdle = 0;
    const sRead = 1; // issue a read of the source word
    const sWrite = 2; // issue a write of the read word to the destination

    // Transfers move 32-bit words. CH_LEN is in bytes (multiple of 4).
    const step = 4;
    final dmaAck = input('dma_ack');
    final dmaRdata = input('dma_rdata');

    // Element transfer type of the active channel (combinational select).
    var activeType = chType[0];
    for (var ch = 1; ch < channels; ch++) {
      activeType = mux(
        activeCh.eq(Const(ch, width: channels.bitLength)),
        chType[ch],
        activeType,
      );
    }
    // memToMem (0): both increment. memToPeriph (1): dst fixed.
    // periphToMem (2): src fixed.
    final srcInc = activeType.neq(Const(2, width: 2)).named('dma_src_inc');
    final dstInc = activeType.neq(Const(1, width: 2)).named('dma_dst_inc');

    interrupt <= (intStatus & intEnable).or();

    output('dma_addr') <= dmaAddrReg;
    output('dma_wdata') <= dmaWdataReg;
    output('dma_we') <= dmaWeReg;
    output('dma_stb') <= dmaStbReg;

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
          curSrc < Const(0, width: addressWidth),
          curDst < Const(0, width: addressWidth),
          dmaAddrReg < Const(0, width: addressWidth),
          dmaWdataReg < Const(0, width: 32),
          dmaWeReg < Const(0),
          dmaStbReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // Transfer engine: round-robin pick a busy channel, then copy it
          // word by word over the master port until its length is exhausted.
          Case(dmaState, [
            CaseItem(Const(sIdle, width: 3), [
              // Pick the lowest-indexed busy channel (high-to-low so index 0
              // wins) and latch its shadow pointers/counter.
              for (var ch = channels - 1; ch >= 0; ch--)
                If(
                  chBusy[ch],
                  then: [
                    activeCh < Const(ch, width: channels.bitLength),
                    curSrc < chSrc[ch],
                    curDst < chDst[ch],
                    xferCount < chLen[ch],
                    dmaState < Const(sRead, width: 3),
                  ],
                ),
            ]),
            CaseItem(Const(sRead, width: 3), [
              dmaAddrReg < curSrc,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  readData < dmaRdata,
                  dmaStbReg < Const(0),
                  dmaState < Const(sWrite, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sWrite, width: 3), [
              dmaAddrReg < curDst,
              dmaWdataReg < readData,
              dmaWeReg < Const(1),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  dmaStbReg < Const(0),
                  dmaWeReg < Const(0),
                  If(
                    srcInc,
                    then: [
                      curSrc < (curSrc + Const(step, width: addressWidth)),
                    ],
                  ),
                  If(
                    dstInc,
                    then: [
                      curDst < (curDst + Const(step, width: addressWidth)),
                    ],
                  ),
                  If(
                    xferCount.lte(Const(step, width: 24)),
                    then: [
                      // Last word: complete the active channel and raise its IRQ.
                      for (var ch = 0; ch < channels; ch++)
                        If(
                          activeCh.eq(Const(ch, width: channels.bitLength)),
                          then: [
                            chBusy[ch] < Const(0),
                            chComplete[ch] < Const(1),
                            intStatus <
                                (intStatus | Const(1 << ch, width: channels)),
                          ],
                        ),
                      dmaState < Const(sIdle, width: 3),
                    ],
                    orElse: [
                      xferCount < (xferCount - Const(step, width: 24)),
                      dmaState < Const(sRead, width: 3),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // Register access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // The bus presents a word index. Each block is 8 words (0x20
              // bytes): block 0 is the global registers, block ch+1 is
              // channel ch. The sub-register is the low 3 bits.
              // Global registers (block 0)
              If(
                bus.addr.getRange(3, 12).eq(Const(0, width: 9)),
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

              // Per-channel registers (channel ch at byte 0x20 + ch*0x20)
              for (var ch = 0; ch < channels; ch++)
                If(
                  bus.addr.getRange(3, 12).eq(Const(ch + 1, width: 9)),
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

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DMA',
    groupName: 'DMA',
    description: 'Multi-channel DMA controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
