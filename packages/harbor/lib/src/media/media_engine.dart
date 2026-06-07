import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import 'codec.dart';

/// Harbor Media Engine - hardware video/image codec accelerator.
///
/// Provides encode and decode acceleration for video and image formats.
/// Supports multiple simultaneous sessions with independent codec
/// configurations. Designed for integration into GPU or standalone
/// media processing pipelines.
///
/// Architecture:
/// - **Session manager**: Up to [maxSessions] concurrent encode/decode sessions
/// - **Decoder pipeline**: Bitstream parser, entropy decoder, inverse transform,
///   motion compensation, deblocking filter, output DMA
/// - **Encoder pipeline**: Motion estimation, transform, entropy encoder,
///   rate control, output DMA
/// - **Frame buffer manager**: Manages reference frames and DPB
///   (Decoded Picture Buffer)
/// - **DMA engine**: Reads input buffers and writes output buffers
///
/// Register map:
/// - 0x000: ENGINE_CTRL     (enable, reset, power state)
/// - 0x004: ENGINE_STATUS   (busy sessions, idle, error)
/// - 0x008: ENGINE_CAPS     (supported codecs bitmask, read-only)
/// - 0x00C: ENGINE_VERSION  (hardware version, read-only)
/// - 0x010: INT_STATUS      (per-session done/error bits, W1C)
/// - 0x014: INT_ENABLE      (interrupt enable mask)
///
/// Per-session registers (0x100 + session * 0x80):
/// - +0x00: SESS_CTRL       (codec select, direction, start, abort)
/// - +0x04: SESS_STATUS     (idle/busy/done/error, progress)
/// - +0x08: SESS_SRC_ADDR   (source buffer DMA address)
/// - +0x0C: SESS_SRC_SIZE   (source buffer size in bytes)
/// - +0x10: SESS_DST_ADDR   (destination buffer DMA address)
/// - +0x14: SESS_DST_SIZE   (destination buffer size / bytes written)
/// - +0x18: SESS_WIDTH      (frame width in pixels)
/// - +0x1C: SESS_HEIGHT     (frame height in pixels)
/// - +0x20: SESS_PIXEL_FMT  (input/output pixel format)
/// - +0x24: SESS_BITRATE    (target bitrate for encoding, Kbps)
/// - +0x28: SESS_QP         (quantization parameter / CRF value)
/// - +0x2C: SESS_RC_MODE    (rate control mode)
/// - +0x30: SESS_FPS        (framerate numerator)
/// - +0x34: SESS_FPS_DEN    (framerate denominator)
/// - +0x38: SESS_GOP_SIZE   (group of pictures size for encoding)
/// - +0x3C: SESS_REF_FRAMES (max reference frames)
/// - +0x40: SESS_PROFILE    (codec profile)
/// - +0x44: SESS_LEVEL      (codec level)
/// - +0x48: SESS_BYTES_DONE (bytes processed, read-only)
/// - +0x4C: SESS_FRAMES_DONE (frames processed, read-only)
class HarborMediaEngine extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborAcpiDeviceProvider {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Supported codec instances.
  final List<HarborCodecInstance> codecs;

  /// Maximum concurrent sessions.
  final int maxSessions;

  /// DMA address width.
  final int dmaAddrWidth;

  /// Bus slave port for register access.
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  /// DMA read interface.
  Logic get dmaReadAddr => output('dma_read_addr');
  Logic get dmaReadReq => output('dma_read_req');
  Logic get dmaReadData => input('dma_read_data');
  Logic get dmaReadValid => input('dma_read_valid');

  /// DMA write interface.
  Logic get dmaWriteAddr => output('dma_write_addr');
  Logic get dmaWriteData => output('dma_write_data');
  Logic get dmaWriteReq => output('dma_write_req');
  Logic get dmaWriteAck => input('dma_write_ack');

  HarborMediaEngine({
    required this.baseAddress,
    required this.codecs,
    this.maxSessions = 4,
    this.dmaAddrWidth = 32,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborMediaEngine', name: name ?? 'media_engine') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('interrupt');

    // DMA read port
    addOutput('dma_read_addr', width: dmaAddrWidth);
    addOutput('dma_read_req');
    createPort('dma_read_data', PortDirection.input, width: 128);
    createPort('dma_read_valid', PortDirection.input);

    // DMA write port
    addOutput('dma_write_addr', width: dmaAddrWidth);
    addOutput('dma_write_data', width: 128);
    addOutput('dma_write_req');
    createPort('dma_write_ack', PortDirection.input);

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Engine-level registers
    final engineCtrl = Logic(name: 'engine_ctrl', width: 32);
    final engineStatus = Logic(name: 'engine_status', width: 32);
    final intStatus = Logic(name: 'int_status', width: maxSessions);
    final intEnable = Logic(name: 'int_enable', width: maxSessions);

    // Codec capabilities bitmask
    var capsBits = 0;
    for (final c in codecs) {
      capsBits |= 1 << c.format.index;
    }
    final engineCaps = Const(capsBits, width: 32);

    interrupt <= (intStatus & intEnable).or();

    // Per-session state
    final sessCtrl = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_ctrl', width: 32),
    ];
    final sessStatus = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_status', width: 32),
    ];
    final sessSrcAddr = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_src_addr', width: dmaAddrWidth),
    ];
    final sessSrcSize = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_src_size', width: 32),
    ];
    final sessDstAddr = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_dst_addr', width: dmaAddrWidth),
    ];
    final sessDstSize = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_dst_size', width: 32),
    ];
    final sessWidth = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_width', width: 16),
    ];
    final sessHeight = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_height', width: 16),
    ];
    final sessPixFmt = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_pix_fmt', width: 8),
    ];
    final sessBitrate = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_bitrate', width: 32),
    ];
    final sessQp = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_qp', width: 8),
    ];
    final sessRcMode = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_rc_mode', width: 4),
    ];
    final sessBytesDone = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_bytes_done', width: 32),
    ];
    final sessFramesDone = <Logic>[
      for (var i = 0; i < maxSessions; i++)
        Logic(name: 'sess${i}_frames_done', width: 32),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          engineCtrl < Const(0, width: 32),
          engineStatus < Const(0, width: 32),
          intStatus < Const(0, width: maxSessions),
          intEnable < Const(0, width: maxSessions),
          output('dma_read_req') < Const(0),
          output('dma_write_req') < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
          for (var i = 0; i < maxSessions; i++) ...[
            sessCtrl[i] < Const(0, width: 32),
            sessStatus[i] < Const(0, width: 32),
            sessSrcAddr[i] < Const(0, width: dmaAddrWidth),
            sessSrcSize[i] < Const(0, width: 32),
            sessDstAddr[i] < Const(0, width: dmaAddrWidth),
            sessDstSize[i] < Const(0, width: 32),
            sessWidth[i] < Const(0, width: 16),
            sessHeight[i] < Const(0, width: 16),
            sessPixFmt[i] < Const(0, width: 8),
            sessBitrate[i] < Const(0, width: 32),
            sessQp[i] < Const(0, width: 8),
            sessRcMode[i] < Const(0, width: 4),
            sessBytesDone[i] < Const(0, width: 32),
            sessFramesDone[i] < Const(0, width: 32),
          ],
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Global registers (0x000 - 0x0FF)
              If(
                bus.addr.getRange(8, 12).eq(Const(0, width: 4)),
                then: [
                  Case(bus.addr.getRange(0, 8), [
                    // ENGINE_CTRL
                    CaseItem(Const(0x00, width: 8), [
                      If(
                        bus.we,
                        then: [engineCtrl < bus.dataIn],
                        orElse: [bus.dataOut < engineCtrl],
                      ),
                    ]),
                    // ENGINE_STATUS
                    CaseItem(Const(0x04 >> 2, width: 8), [
                      bus.dataOut < engineStatus,
                    ]),
                    // ENGINE_CAPS
                    CaseItem(Const(0x08 >> 2, width: 8), [
                      bus.dataOut < engineCaps,
                    ]),
                    // INT_STATUS
                    CaseItem(Const(0x10 >> 2, width: 8), [
                      If(
                        bus.we,
                        then: [
                          intStatus <
                              (intStatus &
                                  ~bus.dataIn.getRange(0, maxSessions)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // INT_ENABLE
                    CaseItem(Const(0x14 >> 2, width: 8), [
                      If(
                        bus.we,
                        then: [intEnable < bus.dataIn.getRange(0, maxSessions)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-session registers are decoded by session index
              // Session N starts at 0x100 + N * 0x80
            ],
          ),

          // Session processing FSM would go here
          // Each active session runs through the codec pipeline
        ],
      ),
    ]);

    // Placeholder DMA outputs
    output('dma_read_addr') <= Const(0, width: dmaAddrWidth);
    output('dma_write_addr') <= Const(0, width: dmaAddrWidth);
    output('dma_write_data') <= Const(0, width: 128);
  }

  /// Whether this engine supports a specific codec format.
  bool supportsCodec(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format);

  /// Whether this engine can decode a specific format.
  bool canDecode(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format && c.canDecode);

  /// Whether this engine can encode a specific format.
  bool canEncode(HarborCodecFormat format) =>
      codecs.any((c) => c.format == format && c.canEncode);

  /// All formats that can be decoded.
  List<HarborCodecFormat> get decodableFormats =>
      codecs.where((c) => c.canDecode).map((c) => c.format).toList();

  /// All formats that can be encoded.
  List<HarborCodecFormat> get encodableFormats =>
      codecs.where((c) => c.canEncode).map((c) => c.format).toList();

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,media-engine'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'max-sessions': maxSessions,
      'harbor,codecs': codecs.map((c) => c.format.displayName).join(', '),
      'harbor,max-width': codecs.fold<int>(
        0,
        (max, c) => c.maxWidth > max ? c.maxWidth : max,
      ),
      'harbor,max-height': codecs.fold<int>(
        0,
        (max, c) => c.maxHeight > max ? c.maxHeight : max,
      ),
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,media-engine'],
      'max-sessions': maxSessions,
      'harbor,codecs': codecs.map((c) => c.format.displayName).join(', '),
      'harbor,max-width': codecs.fold<int>(
        0,
        (max, c) => c.maxWidth > max ? c.maxWidth : max,
      ),
      'harbor,max-height': codecs.fold<int>(
        0,
        (max, c) => c.maxHeight > max ? c.maxHeight : max,
      ),
    },
  );
}
