import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import '../util/pretty_string.dart';

/// SD/SDIO bus width.
enum HarborSdioBusWidth {
  /// 1-bit data bus.
  one(1),

  /// 4-bit data bus.
  four(4),

  /// 8-bit data bus (eMMC only).
  eight(8);

  final int width;
  const HarborSdioBusWidth(this.width);
}

/// SD/SDIO speed mode.
enum HarborSdioSpeed {
  /// Default speed (25 MHz, SD).
  defaultSpeed,

  /// High speed (50 MHz, SD).
  highSpeed,

  /// UHS-I SDR12 (25 MHz, SD 3.0).
  sdr12,

  /// UHS-I SDR25 (50 MHz, SD 3.0).
  sdr25,

  /// UHS-I SDR50 (100 MHz, SD 3.0).
  sdr50,

  /// UHS-I SDR104 (208 MHz, SD 3.0).
  sdr104,

  /// UHS-I DDR50 (50 MHz DDR, SD 3.0).
  ddr50,

  /// HS200 (200 MHz, eMMC 4.5).
  hs200,

  /// HS400 (200 MHz DDR, eMMC 5.0).
  hs400,
}

/// SD/SDIO controller configuration.
class HarborSdioConfig with HarborPrettyString {
  /// Maximum bus width supported.
  final HarborSdioBusWidth maxBusWidth;

  /// Maximum speed mode supported.
  final HarborSdioSpeed maxSpeed;

  /// Whether SDIO (I/O card) mode is supported.
  final bool supportsIo;

  /// Whether eMMC mode is supported.
  final bool supportsEmmc;

  /// Whether 1.8V signaling is supported (UHS-I).
  final bool supports1v8;

  /// Maximum clock frequency in Hz.
  final int maxFrequency;

  /// Maximum number of SDIO I/O functions (1-7, 0 = no I/O support).
  ///
  /// WiFi/BT combo chips typically use 2 functions
  /// (function 1: WiFi, function 2: Bluetooth).
  final int maxIoFunctions;

  const HarborSdioConfig({
    this.maxBusWidth = HarborSdioBusWidth.four,
    this.maxSpeed = HarborSdioSpeed.highSpeed,
    this.supportsIo = false,
    this.supportsEmmc = false,
    this.supports1v8 = false,
    this.maxFrequency = 50000000,
    this.maxIoFunctions = 0,
  });

  /// SD card controller (standard 4-bit, up to high speed).
  const HarborSdioConfig.sd()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = false,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 0;

  /// SDIO WiFi/BT controller (4-bit, high speed, I/O functions).
  ///
  /// Suitable for chips like ESP32, CYW43455, RTL8822, etc.
  const HarborSdioConfig.wifi()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.highSpeed,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = false,
      maxFrequency = 50000000,
      maxIoFunctions = 2;

  /// SD 3.0 UHS-I controller with full SDIO support.
  const HarborSdioConfig.uhs()
    : maxBusWidth = HarborSdioBusWidth.four,
      maxSpeed = HarborSdioSpeed.sdr104,
      supportsIo = true,
      supportsEmmc = false,
      supports1v8 = true,
      maxFrequency = 208000000,
      maxIoFunctions = 7;

  /// eMMC controller (8-bit, HS200).
  const HarborSdioConfig.emmc()
    : maxBusWidth = HarborSdioBusWidth.eight,
      maxSpeed = HarborSdioSpeed.hs200,
      supportsIo = false,
      supportsEmmc = true,
      supports1v8 = true,
      maxFrequency = 200000000,
      maxIoFunctions = 0;

  @override
  String toString() =>
      'HarborSdioConfig(${maxBusWidth.width}-bit, ${maxSpeed.name}, '
      '${maxFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSdioConfig(\n');
    buf.writeln('${c}busWidth: ${maxBusWidth.width}-bit,');
    buf.writeln('${c}speed: ${maxSpeed.name},');
    buf.writeln('${c}maxFrequency: ${maxFrequency ~/ 1000000} MHz,');
    if (supportsIo) buf.writeln('${c}SDIO I/O,');
    if (supportsEmmc) buf.writeln('${c}eMMC,');
    if (supports1v8) buf.writeln('${c}1.8V signaling,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SD/SDIO/eMMC host controller.
///
/// Register map:
/// - 0x00: CTRL      (enable, bus width, speed mode, reset)
/// - 0x04: STATUS    (card_detect, card_ready, busy, error)
/// - 0x08: CLK_DIV   (clock divider)
/// - 0x0C: CMD       (command index + argument trigger)
/// - 0x10: CMD_ARG   (command argument)
/// - 0x14: RESP0     (response bits 31:0)
/// - 0x18: RESP1     (response bits 63:32)
/// - 0x1C: RESP2     (response bits 95:64)
/// - 0x20: RESP3     (response bits 127:96)
/// - 0x24: DATA      (read/write data FIFO)
/// - 0x28: BLK_SIZE  (block size for data transfers)
/// - 0x2C: BLK_COUNT (block count for multi-block transfers)
/// - 0x30: INT_STATUS (interrupt status, write-1-to-clear)
/// - 0x34: INT_ENABLE (interrupt enable)
/// - 0x38: ADMA_ADDR  (descriptor table base for DMA transfers)
///
/// CMD bits: [5:0] index, [7:6] response type (0 none, 1 short, 2 long R2,
/// 3 short+busy), [8] data present, [9] direction (0 write, 1 read), [10] use
/// ADMA DMA. INT_STATUS bits: [0] cmd-done, [1] data-done, [2] data-request,
/// [3] data-CRC-error, [4] cmd-timeout, [5] write-error.
class HarborSdioController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Controller configuration.
  final HarborSdioConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// Build target. When set on a UHS-capable [config], the read sampling path
  /// is conditioned with per-vendor IO primitives (input delay for SDR50/104
  /// tuning, DDR gearing for DDR50/HS400). This is a structural,
  /// not-yet-calibrated layer (placeholder taps), the SDIO analogue of the
  /// Xilinx DDR PHY. Null or a non-UHS config leaves the proven SDR datapath
  /// untouched.
  final HarborDeviceTarget? target;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborSdioController({
    required this.baseAddress,
    this.config = const HarborSdioConfig.sd(),
    BusProtocol protocol = BusProtocol.wishbone,
    this.target,
    String? name,
  }) : super('HarborSdioController', name: name ?? 'sdio') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SD/SDIO pins
    addOutput('sd_clk');
    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    createPort('sd_cmd_in', PortDirection.input);
    addOutput('sd_dat_out', width: config.maxBusWidth.width);
    addOutput('sd_dat_oe');
    createPort(
      'sd_dat_in',
      PortDirection.input,
      width: config.maxBusWidth.width,
    );
    createPort('sd_cd', PortDirection.input); // card detect
    addOutput('interrupt');

    // ADMA bus-master port (single-beat handshake) for descriptor-driven DMA.
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
    final cardDetect = input('sd_cd');
    // CMD stays SDR even in HS400, so it only gets the input-delay tuning.
    final cmdIn = _uhsTuned
        ? _uhsConditionBit(input('sd_cmd_in'), 'cmd', ddr: false)
        : input('sd_cmd_in');

    // CMD FSM states.
    const sIdle = 0;
    const sSend = 1;
    const sWait = 2;
    const sRecv = 3;

    // INT_STATUS bits.
    const intCmdDone = 0x01;
    const intCmdTimeout = 0x10;

    // Response NCR timeout, in SD clocks (spec allows up to 64, round up).
    const respTimeout = 128;

    // Registers
    final ctrlEnable = Logic(name: 'ctrl_enable');
    final clkDiv = Logic(name: 'clk_div', width: 16);
    final cmdIndex = Logic(name: 'cmd_index', width: 6);
    final cmdArg = Logic(name: 'cmd_arg', width: 32);
    final cmdRespType = Logic(name: 'cmd_resp_type', width: 2);
    final cmdDataPresent = Logic(name: 'cmd_data_present');
    final cmdDataDir = Logic(name: 'cmd_data_dir');
    final resp = List.generate(4, (i) => Logic(name: 'resp$i', width: 32));
    final blkSize = Logic(name: 'blk_size', width: 12);
    final blkCount = Logic(name: 'blk_count', width: 16);
    final intStatus = Logic(name: 'int_status', width: 8);
    final intEnable = Logic(name: 'int_enable', width: 8);
    final busy = Logic(name: 'busy');
    final divCount = Logic(name: 'div_count', width: 16);
    final sdClkReg = Logic(name: 'sd_clk_reg');

    // CMD engine state.
    final state = Logic(name: 'cmd_state', width: 2);
    final cmdShift = Logic(name: 'cmd_shift', width: 48);
    final cmdCnt = Logic(name: 'cmd_cnt', width: 7);
    final cmdOut = Logic(name: 'cmd_out');
    final cmdOe = Logic(name: 'cmd_oe');
    final respShift = Logic(name: 'resp_shift', width: 136);
    final respCnt = Logic(name: 'resp_cnt', width: 8);
    final toCnt = Logic(name: 'to_cnt', width: 16);

    // DAT engine state. PIO block read/write at 1/4/8-bit width (selected at
    // runtime via CTRL[5:4]): [laneCount] bits move per SD clock, one per lane,
    // each lane carrying its own CRC16. A one-word holding register the CPU
    // services through DATA carries the payload, with a data-request flag.
    const dIdle = 0;
    const dRWait = 1; // read: hunt for the block start bit
    const dRead = 2; // read: shift data bytes in
    const dRCrc = 3; // read: shift the 16-bit CRC in and check it
    const dWStart = 4; // write: drive the block start bit
    const dWrite = 5; // write: shift data bytes out
    const dWCrc = 6; // write: shift the 16-bit CRC out
    const dWEnd = 7; // write: end bit
    const dWStatWait = 8; // write: hunt for the CRC status token start bit
    const dWStat = 9; // write: capture the 3-bit CRC status
    const dWBusy = 10; // write: wait out card programming (DAT0 busy)

    const intDataDone = 0x02;
    const intDataReq = 0x04;
    const intDataCrcErr = 0x08;
    const intWriteErr = 0x20; // card reported a write/CRC-status error

    final maxW = config.maxBusWidth.width;
    final datState = Logic(name: 'dat_state', width: 4);
    // One CRC16 generator and CRC shift register per data lane.
    final crc16 = [
      for (var l = 0; l < maxW; l++) Logic(name: 'dat_crc16_$l', width: 16),
    ];
    final crcShift = [
      for (var l = 0; l < maxW; l++) Logic(name: 'dat_crc_shift_$l', width: 16),
    ];
    final byteShift = Logic(name: 'dat_byte_shift', width: 8);
    final bitsInByte = Logic(name: 'dat_bits_in_byte', width: 4);
    final byteCnt = Logic(name: 'dat_byte_cnt', width: 13);
    final blockLeft = Logic(name: 'dat_block_left', width: 16);
    final crcBitCnt = Logic(name: 'dat_crc_bit_cnt', width: 5);
    final dataReg = Logic(name: 'dat_word', width: 32);
    final dataValid = Logic(name: 'dat_word_valid');
    final byteInWord = Logic(name: 'dat_byte_in_word', width: 2);
    final busWidthSel = Logic(name: 'bus_width_sel', width: 2);
    // Write CRC-status token + busy tracking.
    final statShift = Logic(name: 'dat_stat_shift', width: 3);
    final statCnt = Logic(name: 'dat_stat_cnt', width: 2);
    final busySeen = Logic(name: 'dat_busy_seen');
    final statWaitCnt = Logic(name: 'dat_stat_wait', width: 16);

    // ADMA descriptor DMA. The engine walks a descriptor table in memory and
    // bridges memory to the DAT word handshake (dataReg/dataValid): on a card
    // read it writes each produced word to memory, on a card write it fetches
    // words from memory. Descriptor = two words: [address], [byte length in
    // [15:0], end flag in [31]].
    const aIdle = 0;
    const aFetchAddr = 1; // read descriptor word 0 (address)
    const aFetchCtrl = 2; // read descriptor word 1 (length + end flag)
    const aMemRead = 3; // card write: fetch a word from memory
    const aMemWrite = 4; // card read: store a produced word to memory
    const aNext = 5; // advance within / past the current descriptor

    final dmaMode = Logic(name: 'dma_mode');
    final admaState = Logic(name: 'adma_state', width: 3);
    final descPtr = Logic(name: 'adma_desc_ptr', width: 32);
    final descAddr = Logic(name: 'adma_addr', width: 32);
    final descBytes = Logic(name: 'adma_bytes', width: 16);
    final descEnd = Logic(name: 'adma_end');
    final admaBase = Logic(name: 'adma_base', width: 32);
    final dmaAck = input('dma_ack');
    final dmaRdata = input('dma_rdata');
    // Master output drives (set by the ADMA FSM, default idle).
    final dmaAddrReg = Logic(name: 'dma_addr_reg', width: 32);
    final dmaWdataReg = Logic(name: 'dma_wdata_reg', width: 32);
    final dmaWeReg = Logic(name: 'dma_we_reg');
    final dmaStbReg = Logic(name: 'dma_stb_reg');
    // Read assembles bytes 0..2 here, byte 3 is the live one.
    final asmB0 = Logic(name: 'dat_asm_b0', width: 8);
    final asmB1 = Logic(name: 'dat_asm_b1', width: 8);
    final asmB2 = Logic(name: 'dat_asm_b2', width: 8);
    final datOutReg = Logic(name: 'dat_out_reg', width: maxW);
    final datOeReg = Logic(name: 'dat_oe_reg');

    // Active lane count (1/4/8, clamped to the configured maximum) and the
    // matching low-lane mask, selected at runtime from CTRL[5:4].
    final wSel1 = busWidthSel.eq(Const(0, width: 2));
    final wSel4 = busWidthSel.eq(Const(1, width: 2));
    final Logic laneCount;
    final Logic laneMask;
    if (maxW >= 8) {
      laneCount = mux(
        wSel1,
        Const(1, width: 4),
        mux(wSel4, Const(4, width: 4), Const(8, width: 4)),
      );
      laneMask = mux(
        wSel1,
        Const(0x01, width: maxW),
        mux(wSel4, Const(0x0F, width: maxW), Const(0xFF, width: maxW)),
      );
    } else if (maxW >= 4) {
      laneCount = mux(wSel1, Const(1, width: 4), Const(4, width: 4));
      laneMask = mux(wSel1, Const(0x01, width: maxW), Const(0x0F, width: maxW));
    } else {
      laneCount = Const(1, width: 4);
      laneMask = Const(0x01, width: maxW);
    }

    // SD clock and its sysclk-domain edge strobes. The engine drives CMD on the
    // falling edge and samples on the rising edge, all in the sysclk domain (the
    // SD clock is a gated divide of sysclk, so there is no clock crossing).
    final divTick = (ctrlEnable & divCount.eq(Const(0, width: 16))).named(
      'div_tick',
    );
    final sdRise = (divTick & ~sdClkReg).named('sd_rise');
    final sdFall = (divTick & sdClkReg).named('sd_fall');

    final rawDatIn = input('sd_dat_in');
    final datIn = _uhsTuned
        ? [
            for (var l = 0; l < maxW; l++)
              _uhsConditionBit(rawDatIn[l], 'dat$l', ddr: _uhsDdr),
          ].rswizzle()
        : rawDatIn;

    output('sd_clk') <= sdClkReg & ctrlEnable;
    output('sd_cmd_out') <= cmdOut;
    output('sd_cmd_oe') <= cmdOe;
    output('sd_dat_out') <= datOutReg;
    output('sd_dat_oe') <= datOeReg;
    output('dma_addr') <= dmaAddrReg;
    output('dma_wdata') <= dmaWdataReg;
    output('dma_we') <= dmaWeReg;
    output('dma_stb') <= dmaStbReg;
    interrupt <= (intStatus & intEnable).or();

    // Command frame from the value being written to CMD (index + flags) plus
    // the already-latched argument: {0, 1, index[5:0], arg[31:0]} then CRC7 and
    // the end bit, MSB-first.
    final wrIndex = bus.dataIn.getRange(0, 6);
    final cmdContent = [
      Const(0, width: 1),
      Const(1, width: 1),
      wrIndex,
      cmdArg,
    ].swizzle();
    final cmdFrame = [
      cmdContent,
      _crc7(cmdContent),
      Const(1, width: 1),
    ].swizzle();

    // Received response after the in-flight bit is shifted in.
    final respNext = [respShift.getRange(0, 135), cmdIn].swizzle();

    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlEnable < Const(0),
          clkDiv < Const(124, width: 16), // ~400 kHz from 50 MHz
          cmdIndex < Const(0, width: 6),
          cmdArg < Const(0, width: 32),
          cmdRespType < Const(0, width: 2),
          cmdDataPresent < Const(0),
          cmdDataDir < Const(0),
          for (var i = 0; i < 4; i++) resp[i] < Const(0, width: 32),
          blkSize < Const(512, width: 12),
          blkCount < Const(1, width: 16),
          intStatus < Const(0, width: 8),
          intEnable < Const(0, width: 8),
          busy < Const(0),
          divCount < Const(0, width: 16),
          sdClkReg < Const(0),
          state < Const(sIdle, width: 2),
          cmdShift < Const(0, width: 48),
          cmdCnt < Const(0, width: 7),
          cmdOut < Const(1), // CMD idles high
          cmdOe < Const(0),
          respShift < Const(0, width: 136),
          respCnt < Const(0, width: 8),
          toCnt < Const(0, width: 16),
          datState < Const(dIdle, width: 4),
          for (final c in crc16) c < Const(0, width: 16),
          for (final c in crcShift) c < Const(0, width: 16),
          byteShift < Const(0, width: 8),
          bitsInByte < Const(8, width: 4),
          byteCnt < Const(0, width: 13),
          blockLeft < Const(0, width: 16),
          crcBitCnt < Const(0, width: 5),
          dataReg < Const(0, width: 32),
          dataValid < Const(0),
          byteInWord < Const(0, width: 2),
          busWidthSel < Const(0, width: 2),
          statShift < Const(0, width: 3),
          statCnt < Const(0, width: 2),
          busySeen < Const(0),
          statWaitCnt < Const(0, width: 16),
          dmaMode < Const(0),
          admaState < Const(aIdle, width: 3),
          descPtr < Const(0, width: 32),
          descAddr < Const(0, width: 32),
          descBytes < Const(0, width: 16),
          descEnd < Const(0),
          admaBase < Const(0, width: 32),
          dmaAddrReg < Const(0, width: 32),
          dmaWdataReg < Const(0, width: 32),
          dmaWeReg < Const(0),
          dmaStbReg < Const(0),
          asmB0 < Const(0, width: 8),
          asmB1 < Const(0, width: 8),
          asmB2 < Const(0, width: 8),
          datOutReg < Const(0, width: maxW),
          datOeReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // SD clock divider.
          If(
            ctrlEnable,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [divCount < clkDiv, sdClkReg < ~sdClkReg],
                orElse: [divCount < (divCount - Const(1, width: 16))],
              ),
            ],
          ),

          // CMD engine.
          Case(state, [
            // Serialize the command, MSB-first, one bit per SD falling edge.
            CaseItem(Const(sSend, width: 2), [
              If(
                sdFall,
                then: [
                  cmdOut < cmdShift[47],
                  cmdShift < [cmdShift.getRange(0, 47), Const(0)].swizzle(),
                  cmdCnt < (cmdCnt - Const(1, width: 7)),
                  If(
                    cmdCnt.eq(Const(1, width: 7)),
                    then: [
                      If(
                        cmdRespType.eq(Const(0, width: 2)),
                        // No response expected: command done, release the line.
                        then: [
                          state < Const(sIdle, width: 2),
                          busy < Const(0),
                          cmdOe < Const(0),
                          intStatus < (intStatus | Const(intCmdDone, width: 8)),
                        ],
                        // Wait for the card to drive the response.
                        orElse: [
                          state < Const(sWait, width: 2),
                          cmdOe < Const(0),
                          toCnt < Const(0, width: 16),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Hunt for the response start bit, with an NCR timeout.
            CaseItem(Const(sWait, width: 2), [
              If(
                sdRise,
                then: [
                  If(
                    ~cmdIn,
                    then: [
                      state < Const(sRecv, width: 2),
                      respShift < Const(0, width: 136),
                      respCnt <
                          mux(
                            cmdRespType.eq(Const(2, width: 2)),
                            Const(
                              135,
                              width: 8,
                            ), // R2 long response (136-bit frame)
                            Const(47, width: 8), // short 48-bit frame
                          ),
                    ],
                    orElse: [
                      toCnt < (toCnt + Const(1, width: 16)),
                      If(
                        toCnt.eq(Const(respTimeout, width: 16)),
                        then: [
                          state < Const(sIdle, width: 2),
                          busy < Const(0),
                          intStatus <
                              (intStatus | Const(intCmdTimeout, width: 8)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // Shift the response in on rising edges, capture on the last bit.
            CaseItem(Const(sRecv, width: 2), [
              If(
                sdRise,
                then: [
                  respShift < respNext,
                  respCnt < (respCnt - Const(1, width: 8)),
                  If(
                    respCnt.eq(Const(1, width: 8)),
                    then: [
                      state < Const(sIdle, width: 2),
                      intStatus < (intStatus | Const(intCmdDone, width: 8)),
                      // Hand off to the data engine when the command carries a
                      // data phase, otherwise the command is done.
                      If(
                        cmdDataPresent,
                        then: [
                          byteCnt < blkSize.zeroExtend(13),
                          blockLeft < blkCount,
                          for (final c in crc16) c < Const(0, width: 16),
                          bitsInByte < Const(8, width: 4),
                          byteInWord < Const(0, width: 2),
                          If(
                            cmdDataDir,
                            then: [datState < Const(dRWait, width: 4)],
                            orElse: [datState < Const(dWStart, width: 4)],
                          ),
                          // Start the ADMA walk when DMA was requested.
                          If(
                            dmaMode,
                            then: [
                              descPtr < admaBase,
                              admaState < Const(aFetchAddr, width: 3),
                            ],
                          ),
                        ],
                        orElse: [busy < Const(0)],
                      ),
                      // R2: low 128 bits of the 136-bit frame into RESP0-3.
                      // Short: the 32-bit payload (frame bits [39:8]) into RESP0.
                      If(
                        cmdRespType.eq(Const(2, width: 2)),
                        then: [
                          resp[0] < respNext.getRange(0, 32),
                          resp[1] < respNext.getRange(32, 64),
                          resp[2] < respNext.getRange(64, 96),
                          resp[3] < respNext.getRange(96, 128),
                        ],
                        orElse: [
                          resp[0] < respNext.getRange(8, 40),
                          resp[1] < Const(0, width: 32),
                          resp[2] < Const(0, width: 32),
                          resp[3] < Const(0, width: 32),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
          ]),

          // DAT engine (1/4/8-bit PIO). Each SD clock moves [laneCount] bits,
          // one per active lane, MSB group first, each lane has its own CRC16.
          () {
            // Read: the group sampled this clock, and the byte it completes.
            final rdGroup = datIn & laneMask;
            final rdFull = ((byteShift << laneCount) | rdGroup.zeroExtend(8))
                .getRange(0, 8);
            final byteDone = bitsInByte.eq(laneCount.zeroExtend(4));
            final bitsNext = mux(
              byteDone,
              Const(8, width: 4),
              bitsInByte - laneCount.zeroExtend(4),
            );
            // Write: the group driven this clock (top [laneCount] bits of the
            // byte), aligned so lane 0 is the lowest of the group.
            final wrShift = Const(8, width: 4) - laneCount.zeroExtend(4);
            final wrGroup = (byteShift >> wrShift).getRange(0, maxW) & laneMask;
            // Next CRC16 per lane, for the bit that lane carries this clock.
            final crcNextRd = [
              for (var l = 0; l < maxW; l++)
                mux(laneMask[l], _crc16Next(crc16[l], datIn[l]), crc16[l]),
            ];
            final crcNextWr = [
              for (var l = 0; l < maxW; l++)
                mux(laneMask[l], _crc16Next(crc16[l], wrGroup[l]), crc16[l]),
            ];
            // Read CRC shift-in (value after this clock) and the CRC drive vec.
            final rxCrcNext = [
              for (var l = 0; l < maxW; l++)
                [crcShift[l].getRange(0, 15), datIn[l]].swizzle(),
            ];
            final crcOutVec =
                [for (var l = 0; l < maxW; l++) crcShift[l][15]].rswizzle() &
                laneMask;
            // Read CRC mismatch on any active lane.
            var crcBad = Const(0) as Logic;
            for (var l = 0; l < maxW; l++) {
              crcBad = crcBad | (laneMask[l] & crc16[l].neq(rxCrcNext[l]));
            }
            // Next data byte for write (within the current word).
            final nextByte = mux(
              byteInWord.eq(Const(0, width: 2)),
              dataReg.getRange(8, 16),
              mux(
                byteInWord.eq(Const(1, width: 2)),
                dataReg.getRange(16, 24),
                dataReg.getRange(24, 32),
              ),
            );

            return Case(datState, [
              // READ: hunt for the block start bit (0) on DAT0.
              CaseItem(Const(dRWait, width: 4), [
                If(
                  sdRise & ~datIn[0],
                  then: [
                    datState < Const(dRead, width: 4),
                    bitsInByte < Const(8, width: 4),
                    byteShift < Const(0, width: 8),
                  ],
                ),
              ]),
              // READ data, [laneCount] bits per clock, CRC16 per lane.
              CaseItem(Const(dRead, width: 4), [
                If(
                  sdRise,
                  then: [
                    byteShift < mux(byteDone, Const(0, width: 8), rdFull),
                    bitsInByte < bitsNext,
                    for (var l = 0; l < maxW; l++) crc16[l] < crcNextRd[l],
                    If(
                      byteDone,
                      then: [
                        // Assemble the byte into the word, byte 0 in the low lane.
                        Case(byteInWord, [
                          CaseItem(Const(0, width: 2), [asmB0 < rdFull]),
                          CaseItem(Const(1, width: 2), [asmB1 < rdFull]),
                          CaseItem(Const(2, width: 2), [asmB2 < rdFull]),
                          CaseItem(Const(3, width: 2), [
                            dataReg < [asmB0, asmB1, asmB2, rdFull].rswizzle(),
                            dataValid < Const(1),
                            intStatus <
                                (intStatus | Const(intDataReq, width: 8)),
                          ]),
                        ]),
                        byteInWord < (byteInWord + Const(1, width: 2)),
                        byteCnt < (byteCnt - Const(1, width: 13)),
                        If(
                          byteCnt.eq(Const(1, width: 13)),
                          then: [
                            datState < Const(dRCrc, width: 4),
                            crcBitCnt < Const(16, width: 5),
                            for (final c in crcShift) c < Const(0, width: 16),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // READ the per-lane 16-bit CRC and compare.
              CaseItem(Const(dRCrc, width: 4), [
                If(
                  sdRise,
                  then: [
                    for (var l = 0; l < maxW; l++) crcShift[l] < rxCrcNext[l],
                    crcBitCnt < (crcBitCnt - Const(1, width: 5)),
                    If(
                      crcBitCnt.eq(Const(1, width: 5)),
                      then: [
                        If(
                          crcBad,
                          then: [
                            intStatus <
                                (intStatus | Const(intDataCrcErr, width: 8)),
                          ],
                        ),
                        If(
                          blockLeft.eq(Const(1, width: 16)),
                          then: [
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus | Const(intDataDone, width: 8)),
                          ],
                          orElse: [
                            blockLeft < (blockLeft - Const(1, width: 16)),
                            byteCnt < blkSize.zeroExtend(13),
                            for (final c in crc16) c < Const(0, width: 16),
                            byteInWord < Const(0, width: 2),
                            datState < Const(dRWait, width: 4),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: drive the start bit once the CPU has provided data.
              CaseItem(Const(dWStart, width: 4), [
                If(
                  sdFall & dataValid,
                  then: [
                    datOeReg < Const(1),
                    datOutReg <
                        Const(0, width: maxW), // start bit (all lanes 0)
                    byteShift < dataReg.getRange(0, 8),
                    bitsInByte < Const(8, width: 4),
                    byteInWord < Const(0, width: 2),
                    datState < Const(dWrite, width: 4),
                  ],
                ),
              ]),
              // WRITE data, [laneCount] bits per clock, CRC16 per lane.
              CaseItem(Const(dWrite, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < wrGroup,
                    for (var l = 0; l < maxW; l++) crc16[l] < crcNextWr[l],
                    byteShift < (byteShift << laneCount).getRange(0, 8),
                    bitsInByte < bitsNext,
                    If(
                      byteDone,
                      then: [
                        byteCnt < (byteCnt - Const(1, width: 13)),
                        byteInWord < (byteInWord + Const(1, width: 2)),
                        If(
                          byteCnt.eq(Const(1, width: 13)),
                          then: [
                            // Last data byte: send the finished CRC next.
                            for (var l = 0; l < maxW; l++)
                              crcShift[l] < crcNextWr[l],
                            crcBitCnt < Const(16, width: 5),
                            datState < Const(dWCrc, width: 4),
                          ],
                          orElse: [
                            byteShift < nextByte,
                            If(
                              byteInWord.eq(Const(3, width: 2)),
                              then: [
                                dataValid < Const(0),
                                intStatus <
                                    (intStatus | Const(intDataReq, width: 8)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE the per-lane 16-bit CRC, MSB-first.
              CaseItem(Const(dWCrc, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < crcOutVec,
                    for (var l = 0; l < maxW; l++)
                      crcShift[l] <
                          [crcShift[l].getRange(0, 15), Const(0)].swizzle(),
                    crcBitCnt < (crcBitCnt - Const(1, width: 5)),
                    If(
                      crcBitCnt.eq(Const(1, width: 5)),
                      then: [datState < Const(dWEnd, width: 4)],
                    ),
                  ],
                ),
              ]),
              // WRITE the end bit, then release the line for the card's
              // CRC-status token.
              CaseItem(Const(dWEnd, width: 4), [
                If(
                  sdFall,
                  then: [
                    datOutReg < laneMask, // end bit (1 on active lanes)
                    datOeReg < Const(0),
                    datState < Const(dWStatWait, width: 4),
                    statWaitCnt < Const(0, width: 16),
                  ],
                ),
              ]),
              // WRITE: hunt for the CRC status token start bit on DAT0.
              CaseItem(Const(dWStatWait, width: 4), [
                If(
                  sdRise,
                  then: [
                    If(
                      ~datIn[0],
                      then: [
                        datState < Const(dWStat, width: 4),
                        statShift < Const(0, width: 3),
                        statCnt < Const(3, width: 2),
                      ],
                      orElse: [
                        statWaitCnt < (statWaitCnt + Const(1, width: 16)),
                        If(
                          statWaitCnt.eq(Const(respTimeout, width: 16)),
                          then: [
                            // No token: treat as a write error and finish.
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus |
                                    Const(intWriteErr | intDataDone, width: 8)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: capture the 3-bit CRC status (010 == accepted).
              CaseItem(Const(dWStat, width: 4), [
                If(
                  sdRise,
                  then: [
                    statShift < [statShift.getRange(0, 2), datIn[0]].swizzle(),
                    statCnt < (statCnt - Const(1, width: 2)),
                    If(
                      statCnt.eq(Const(1, width: 2)),
                      then: [
                        If(
                          [
                            statShift.getRange(0, 2),
                            datIn[0],
                          ].swizzle().neq(Const(0x2, width: 3)),
                          then: [
                            intStatus <
                                (intStatus | Const(intWriteErr, width: 8)),
                          ],
                        ),
                        datState < Const(dWBusy, width: 4),
                        busySeen < Const(0),
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: wait out programming. The card pulls DAT0 low (busy),
              // then releases it high when done.
              CaseItem(Const(dWBusy, width: 4), [
                If(
                  sdRise,
                  then: [
                    If(~datIn[0], then: [busySeen < Const(1)]),
                    If(
                      busySeen & datIn[0],
                      then: [
                        If(
                          blockLeft.eq(Const(1, width: 16)),
                          then: [
                            datState < Const(dIdle, width: 4),
                            busy < Const(0),
                            intStatus <
                                (intStatus | Const(intDataDone, width: 8)),
                          ],
                          orElse: [
                            blockLeft < (blockLeft - Const(1, width: 16)),
                            byteCnt < blkSize.zeroExtend(13),
                            for (final c in crc16) c < Const(0, width: 16),
                            byteInWord < Const(0, width: 2),
                            datState < Const(dWStart, width: 4),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
            ]);
          }(),

          // ADMA descriptor walker. Runs concurrently with the DAT serial
          // engine (which paces the SD bus) and bridges memory to the
          // dataReg/dataValid word handshake. cmdDataDir == 1 is a card read
          // (the engine stores produced words to memory), == 0 is a card write
          // (it fetches words from memory).
          Case(admaState, [
            CaseItem(Const(aFetchAddr, width: 3), [
              dmaAddrReg < descPtr,
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  descAddr < dmaRdata,
                  dmaStbReg < Const(0),
                  admaState < Const(aFetchCtrl, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(aFetchCtrl, width: 3), [
              dmaAddrReg < (descPtr + Const(4, width: 32)),
              dmaWeReg < Const(0),
              dmaStbReg < Const(1),
              If(
                dmaAck,
                then: [
                  descBytes < dmaRdata.getRange(0, 16),
                  descEnd < dmaRdata[31],
                  dmaStbReg < Const(0),
                  If(
                    cmdDataDir,
                    then: [admaState < Const(aMemWrite, width: 3)],
                    orElse: [admaState < Const(aMemRead, width: 3)],
                  ),
                ],
              ),
            ]),
            // Card write: fetch a word into the DAT buffer when it is free.
            CaseItem(Const(aMemRead, width: 3), [
              If(
                ~dataValid,
                then: [
                  dmaAddrReg < descAddr,
                  dmaWeReg < Const(0),
                  dmaStbReg < Const(1),
                  If(
                    dmaAck,
                    then: [
                      dataReg < dmaRdata,
                      dataValid < Const(1),
                      dmaStbReg < Const(0),
                      descAddr < (descAddr + Const(4, width: 32)),
                      descBytes < (descBytes - Const(4, width: 16)),
                      admaState < Const(aNext, width: 3),
                    ],
                  ),
                ],
              ),
            ]),
            // Card read: store a produced word to memory.
            CaseItem(Const(aMemWrite, width: 3), [
              If(
                dataValid,
                then: [
                  dmaAddrReg < descAddr,
                  dmaWdataReg < dataReg,
                  dmaWeReg < Const(1),
                  dmaStbReg < Const(1),
                  If(
                    dmaAck,
                    then: [
                      dataValid < Const(0),
                      dmaStbReg < Const(0),
                      dmaWeReg < Const(0),
                      descAddr < (descAddr + Const(4, width: 32)),
                      descBytes < (descBytes - Const(4, width: 16)),
                      admaState < Const(aNext, width: 3),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(aNext, width: 3), [
              If(
                descBytes.eq(Const(0, width: 16)),
                then: [
                  If(
                    descEnd,
                    then: [admaState < Const(aIdle, width: 3)],
                    orElse: [
                      descPtr < (descPtr + Const(8, width: 32)),
                      admaState < Const(aFetchAddr, width: 3),
                    ],
                  ),
                ],
                orElse: [
                  If(
                    cmdDataDir,
                    then: [admaState < Const(aMemWrite, width: 3)],
                    orElse: [admaState < Const(aMemRead, width: 3)],
                  ),
                ],
              ),
            ]),
          ]),

          // Bus access.
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // The bus address arrives as a word index (the fabric strips the
              // byte offset), matching every other Harbor peripheral, so the
              // documented byte offsets map to indices 0,1,2,...
              Case(bus.addr.getRange(0, 6), [
                // 0x00: CTRL ([0] enable, [5:4] reports max bus width).
                CaseItem(Const(0x00, width: 6), [
                  If(
                    bus.we,
                    then: [
                      ctrlEnable < bus.dataIn[0],
                      // [5:4] selects the active bus width (0:1-bit, 1:4-bit,
                      // 2:8-bit), clamped to the configured maximum.
                      busWidthSel < bus.dataIn.getRange(4, 6),
                    ],
                    orElse: [
                      bus.dataOut <
                          ctrlEnable.zeroExtend(32) |
                              (busWidthSel.zeroExtend(32) <<
                                  Const(4, width: 32)),
                    ],
                  ),
                ]),
                // 0x04: STATUS ([0] card detect, [8] busy, [9] data ready).
                CaseItem(Const(0x01, width: 6), [
                  bus.dataOut <
                      cardDetect.zeroExtend(32) |
                          (busy.zeroExtend(32) << Const(8, width: 32)) |
                          (dataValid.zeroExtend(32) << Const(9, width: 32)),
                ]),
                // 0x08: CLK_DIV.
                CaseItem(Const(0x02, width: 6), [
                  If(
                    bus.we,
                    then: [clkDiv < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < clkDiv.zeroExtend(32)],
                  ),
                ]),
                // 0x0C: CMD. Writing triggers a command when not busy.
                // [5:0] index, [7:6] response type (0 none, 1 short, 2 long
                // R2, 3 short+busy), [8] data present, [9] data direction
                // (0 write, 1 read).
                CaseItem(Const(0x03, width: 6), [
                  If(
                    bus.we,
                    then: [
                      If(
                        ~busy,
                        then: [
                          cmdIndex < wrIndex,
                          cmdRespType < bus.dataIn.getRange(6, 8),
                          cmdDataPresent < bus.dataIn[8],
                          cmdDataDir < bus.dataIn[9],
                          dmaMode < bus.dataIn[10], // [10] use ADMA DMA
                          cmdShift < cmdFrame,
                          cmdCnt < Const(48, width: 7),
                          cmdOut < Const(1),
                          cmdOe < Const(1),
                          busy < Const(1),
                          state < Const(sSend, width: 2),
                        ],
                      ),
                    ],
                    orElse: [
                      bus.dataOut <
                          cmdIndex.zeroExtend(32) |
                              (cmdRespType.zeroExtend(32) <<
                                  Const(6, width: 32)),
                    ],
                  ),
                ]),
                // 0x10: CMD_ARG.
                CaseItem(Const(0x04, width: 6), [
                  If(
                    bus.we,
                    then: [cmdArg < bus.dataIn],
                    orElse: [bus.dataOut < cmdArg],
                  ),
                ]),
                // 0x14-0x20: RESP0-3.
                for (var i = 0; i < 4; i++)
                  CaseItem(Const(0x05 + i, width: 6), [bus.dataOut < resp[i]]),
                // 0x24: DATA. One-word PIO buffer. CPU writes fill it (for a
                // write transfer), reads drain it (for a read transfer).
                CaseItem(Const(0x09, width: 6), [
                  If(
                    bus.we,
                    then: [dataReg < bus.dataIn, dataValid < Const(1)],
                    orElse: [bus.dataOut < dataReg, dataValid < Const(0)],
                  ),
                ]),
                // 0x28: BLK_SIZE.
                CaseItem(Const(0x0A, width: 6), [
                  If(
                    bus.we,
                    then: [blkSize < bus.dataIn.getRange(0, 12)],
                    orElse: [bus.dataOut < blkSize.zeroExtend(32)],
                  ),
                ]),
                // 0x2C: BLK_COUNT.
                CaseItem(Const(0x0B, width: 6), [
                  If(
                    bus.we,
                    then: [blkCount < bus.dataIn.getRange(0, 16)],
                    orElse: [bus.dataOut < blkCount.zeroExtend(32)],
                  ),
                ]),
                // 0x30: INT_STATUS (write-1-to-clear).
                CaseItem(Const(0x0C, width: 6), [
                  If(
                    bus.we,
                    then: [
                      intStatus < (intStatus & ~bus.dataIn.getRange(0, 8)),
                    ],
                    orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                  ),
                ]),
                // 0x34: INT_ENABLE.
                CaseItem(Const(0x0D, width: 6), [
                  If(
                    bus.we,
                    then: [intEnable < bus.dataIn.getRange(0, 8)],
                    orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                  ),
                ]),
                // 0x38: ADMA_ADDR (descriptor table base for DMA transfers).
                CaseItem(Const(0x0E, width: 6), [
                  If(
                    bus.we,
                    then: [admaBase < bus.dataIn],
                    orElse: [bus.dataOut < admaBase],
                  ),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  /// Bit-serial SD CRC7 (polynomial x^7 + x^3 + 1) over [data], which is
  /// presented MSB-first. Returns the 7-bit CRC, MSB-first.
  Logic _crc7(Logic data) {
    var c = List<Logic>.generate(7, (_) => Const(0)); // c[0] = LSB
    for (var i = data.width - 1; i >= 0; i--) {
      final inv = data[i] ^ c[6];
      c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
    }
    return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]].swizzle();
  }

  /// One step of the SD data CRC16 (CCITT, x^16 + x^12 + x^5 + 1) over [bit].
  /// Returns the next 16-bit CRC, seed with zero at the start of each block.
  Logic _crc16Next(Logic crc, Logic bit) {
    final inv = bit ^ crc[15];
    final next = <Logic>[
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          crc[4] ^ inv
        else if (i == 12)
          crc[11] ^ inv
        else
          crc[i - 1],
    ];
    return next.rswizzle(); // next[0] is the LSB
  }

  /// Whether the read path is conditioned with UHS IO primitives: a target is
  /// set and the config supports SDR50 or faster.
  bool get _uhsTuned =>
      target is HarborFpgaTarget &&
      config.maxSpeed.index >= HarborSdioSpeed.sdr50.index;

  /// Whether the config is a double-data-rate UHS mode (DDR50 / HS400).
  bool get _uhsDdr =>
      config.maxSpeed == HarborSdioSpeed.ddr50 ||
      config.maxSpeed == HarborSdioSpeed.hs400;

  /// Conditions one input bit with the per-vendor UHS IO primitives: a static
  /// input delay for SDR50/SDR104 sampling, then DDR capture when [ddr]. This
  /// is structural and NOT board-calibrated (placeholder tap values, rising
  /// half only), real bring-up tunes the tap via CMD19 and adds the
  /// falling-edge datapath. Lattice iCE40 has no UHS-class primitive, so it
  /// passes through.
  Logic _uhsConditionBit(Logic raw, String tag, {required bool ddr}) {
    final fpga = target as HarborFpgaTarget;
    final Logic delayed;
    switch (fpga.vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        delayed = XilinxIdelaye2(
          idatain: raw,
          idelayValue: 8,
          name: 'sd_idelay_$tag',
        ).dataout;
      case HarborFpgaVendor.ecp5:
        delayed = Ecp5Delayg(a: raw, delValue: 40, name: 'sd_delay_$tag').z;
      case HarborFpgaVendor.ice40:
        delayed = raw;
    }
    if (!ddr) return delayed;
    switch (fpga.vendor) {
      case HarborFpgaVendor.vivado:
      case HarborFpgaVendor.openXc7:
        return XilinxIddr(c: input('clk'), d: delayed, name: 'sd_iddr_$tag').q1;
      case HarborFpgaVendor.ecp5:
        return Ecp5Iddrx1f(
          sclk: input('clk'),
          rst: input('reset'),
          d: delayed,
          name: 'sd_iddr_$tag',
        ).q0;
      case HarborFpgaVendor.ice40:
        return delayed;
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: config.supportsEmmc ? ['harbor,sdhci-emmc'] : ['harbor,sdhci'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': config.supportsEmmc
          ? ['harbor,sdhci-emmc']
          : ['harbor,sdhci'],
      'bus-width': config.maxBusWidth.width,
      'max-frequency': config.maxFrequency,
      if (config.supports1v8) 'sd-uhs-sdr12': true,
      if (config.supports1v8) 'sd-uhs-sdr25': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr50.index)
        'sd-uhs-sdr50': true,
      if (config.maxSpeed.index >= HarborSdioSpeed.sdr104.index)
        'sd-uhs-sdr104': true,
      if (config.supportsEmmc) 'non-removable': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SDIO',
    groupName: 'SDIO',
    description: 'SD SDIO and eMMC host controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}
