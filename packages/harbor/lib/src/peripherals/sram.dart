import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/ice40/ice40.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/device_tree.dart';
import '../soc/target.dart';

/// On-chip SRAM memory module.
///
/// Uses target BRAM primitives for synthesis. For simulation (no target),
/// uses a small register array (max 4KB).
class HarborSram extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int size;
  final int baseAddress;
  final int dataWidth;

  late final BusSlavePort bus;

  HarborSram({
    required this.baseAddress,
    required this.size,
    this.dataWidth = 32,
    int? busAddressWidth,
    BusProtocol protocol = BusProtocol.wishbone,
    HarborDeviceTarget? target,
    String? name,
  }) : super('HarborSram_${size}', name: name ?? 'sram') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final addrWidth = numWords > 1 ? (numWords - 1).bitLength : 1;
    final byteOffsetBits = bytesPerWord > 1 ? (bytesPerWord - 1).bitLength : 0;
    final totalAddrWidth = addrWidth + byteOffsetBits;
    final effectiveAddrWidth = busAddressWidth ?? totalAddrWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: effectiveAddrWidth,
      dataWidth: dataWidth,
    );

    final clk = input('clk');
    final stb = bus.stb;
    final we = bus.we;
    final addr = bus.addr;
    final datIn = bus.dataIn;
    final datOut = bus.dataOut;
    final ack = bus.ack;

    final wordAddr = byteOffsetBits > 0
        ? addr.getRange(byteOffsetBits, byteOffsetBits + addrWidth)
        : addr.getRange(0, addrWidth);

    if (target case HarborFpgaTarget fpgaTarget) {
      _buildWithBram(fpgaTarget, clk, wordAddr, datIn, datOut, stb, we, ack);
    } else if (target case HarborAsicTarget asicTarget) {
      _buildWithAsicSram(
        asicTarget,
        clk,
        wordAddr,
        datIn,
        datOut,
        stb,
        we,
        ack,
        numWords,
      );
    } else {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords);
    }
  }

  void _buildWithBram(
    HarborFpgaTarget target,
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
  ) {
    switch (target.vendor) {
      case HarborFpgaVendor.ecp5:
        _buildEcp5Bram(clk, wordAddr, datIn, datOut, stb, we, ack);
      case HarborFpgaVendor.ice40:
        _buildIce40Bram(clk, wordAddr, datIn, datOut, stb, we, ack);
      default:
        _buildEcp5Bram(clk, wordAddr, datIn, datOut, stb, we, ack);
    }
  }

  void _buildEcp5Bram(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
  ) {
    // ECP5 DP16KD: 16Kbit = 1024 x 18-bit (or 2048 x 9-bit, etc.)
    // For 32-bit data: use 2 BRAMs wide (18+18=36, use 32)
    // For depth > 1024: stack BRAMs with address decode on upper bits
    const bramWordDepth = 1024;
    const bramPortWidth = 18;
    const bramAddrWidth = 14;

    final widthBrams = (dataWidth + bramPortWidth - 1) ~/ bramPortWidth;
    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final depthBrams = (numWords + bramWordDepth - 1) ~/ bramWordDepth;
    final totalBrams = widthBrams * depthBrams;

    // Limit: don't instantiate too many BRAMs
    if (totalBrams > 64) {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords);
      return;
    }

    final depthAddrBits = depthBrams > 1 ? (depthBrams - 1).bitLength : 0;
    final bankSelect = depthAddrBits > 0
        ? wordAddr.getRange(
            bramWordDepth.bitLength - 1,
            bramWordDepth.bitLength - 1 + depthAddrBits,
          )
        : null;

    // Collect read outputs from all banks
    final bankOutputs = <Logic>[];

    for (var d = 0; d < depthBrams; d++) {
      final bankEnable = bankSelect != null
          ? bankSelect.eq(Const(d, width: depthAddrBits))
          : Const(1);

      final bankDataParts = <Logic>[];

      for (var w = 0; w < widthBrams; w++) {
        final bitLo = w * bramPortWidth;
        final bitHi = (bitLo + bramPortWidth).clamp(0, dataWidth);
        final sliceWidth = bitHi - bitLo;

        final addrBits = wordAddr.width < bramWordDepth.bitLength
            ? wordAddr.width
            : bramWordDepth.bitLength;
        final localAddr = wordAddr
            .getRange(0, addrBits)
            .zeroExtend(bramAddrWidth);

        final bram = Ecp5Dp16kd(
          name: 'bram_${d}_$w',
          clkA: clk,
          ceA: bankEnable,
          oceA: Const(0),
          rstA: Const(0),
          adA: localAddr,
          diA: datIn.getRange(bitLo, bitHi).zeroExtend(bramPortWidth),
          weA: stb & we & bankEnable,
          clkB: clk,
          ceB: Const(0),
          weB: Const(0),
          oceB: Const(0),
          rstB: Const(0),
          adB: Const(0, width: bramAddrWidth),
          diB: Const(0, width: bramPortWidth),
        );

        bankDataParts.add(bram.doA.getRange(0, sliceWidth));
      }

      // Concatenate width slices for this bank
      final bankData = bankDataParts.length == 1
          ? bankDataParts.first.zeroExtend(dataWidth)
          : bankDataParts.rswizzle().getRange(0, dataWidth);

      bankOutputs.add(bankData);
    }

    // Mux between depth banks
    if (depthBrams == 1) {
      datOut <= bankOutputs.first;
    } else {
      Logic readMux = bankOutputs.first;
      for (var d = 1; d < depthBrams; d++) {
        readMux = mux(
          bankSelect!.eq(Const(d, width: depthAddrBits)),
          bankOutputs[d],
          readMux,
        );
      }
      datOut <= readMux;
    }

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildIce40Bram(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
  ) {
    // iCE40 SPRAM (SB_SPRAM256KA): 16384 x 16-bit = 32KB each. up5k has 4
    // (128KB total). Pair SPRAMs across the data width and bank them across
    // depth, with an address-decoded read mux. Byte lanes are written whole
    // (MASKWREN=0xF), matching the bus's word-granular writes.
    const spramDepth = 16384;
    const spramWidth = 16;
    const spramAddrBits = 14;

    final bytesPerWord = dataWidth ~/ 8;
    final numWords = size ~/ bytesPerWord;
    final widthSprams = (dataWidth + spramWidth - 1) ~/ spramWidth;
    final depthSprams = (numWords + spramDepth - 1) ~/ spramDepth;
    final totalSprams = widthSprams * depthSprams;

    if (totalSprams > 4) {
      throw ArgumentError(
        'HarborSram "$name": $size bytes at $dataWidth-bit needs $totalSprams '
        'iCE40 SPRAM blocks, but up5k has only 4 (128KB max on-chip). '
        'Use external memory (SPI flash / DRAM) for regions this large.',
      );
    }

    final depthAddrBits = depthSprams > 1 ? (depthSprams - 1).bitLength : 0;
    final bankSelect = depthAddrBits > 0
        ? wordAddr.getRange(spramAddrBits, spramAddrBits + depthAddrBits)
        : null;
    final localAddr = wordAddr.width >= spramAddrBits
        ? wordAddr.getRange(0, spramAddrBits)
        : wordAddr.zeroExtend(spramAddrBits);

    final bankOutputs = <Logic>[];
    for (var d = 0; d < depthSprams; d++) {
      final bankEnable = bankSelect != null
          ? bankSelect.eq(Const(d, width: depthAddrBits))
          : Const(1);

      final sliceOutputs = <Logic>[];
      for (var w = 0; w < widthSprams; w++) {
        final bitLo = w * spramWidth;
        final bitHi = (bitLo + spramWidth) > dataWidth
            ? dataWidth
            : bitLo + spramWidth;
        final sliceWidth = bitHi - bitLo;

        final spram = Ice40SbSpram256ka(name: 'spram_${d}_$w');
        addSubModule(spram);

        spram.input('CLOCK').srcConnection! <= clk;
        spram.input('CHIPSELECT').srcConnection! <= bankEnable;
        spram.input('STANDBY').srcConnection! <= Const(0);
        spram.input('SLEEP').srcConnection! <= Const(0);
        spram.input('POWEROFF').srcConnection! <= Const(1);
        spram.input('ADDRESS').srcConnection! <= localAddr;
        spram.input('DATAIN').srcConnection! <=
            datIn.getRange(bitLo, bitHi).zeroExtend(spramWidth);
        spram.input('WREN').srcConnection! <= stb & we & bankEnable;
        spram.input('MASKWREN').srcConnection! <= Const(0xF, width: 4);

        sliceOutputs.add(spram.output('DATAOUT').getRange(0, sliceWidth));
      }

      final bankData = sliceOutputs.length == 1
          ? sliceOutputs.first.zeroExtend(dataWidth)
          : sliceOutputs.rswizzle().getRange(0, dataWidth);
      bankOutputs.add(bankData);
    }

    if (depthSprams == 1) {
      datOut <= bankOutputs.first;
    } else {
      Logic readMux = bankOutputs.first;
      for (var d = 1; d < depthSprams; d++) {
        readMux = mux(
          bankSelect!.eq(Const(d, width: depthAddrBits)),
          bankOutputs[d],
          readMux,
        );
      }
      datOut <= readMux;
    }

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildWithAsicSram(
    HarborAsicTarget target,
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    int numWords,
  ) {
    final pdk = target.provider;
    if (!pdk.hasSramMacro) {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords);
      return;
    }

    final macro = pdk.sramMacro(words: numWords, width: dataWidth);
    if (macro == null) {
      _buildSimModel(clk, wordAddr, datIn, datOut, stb, we, ack, numWords);
      return;
    }

    // Instantiate the PDK SRAM macro as a blackbox
    final sramBlock = _PdkSramMacro(
      macroName: macro.properties['name'] ?? 'sram_macro',
      addrWidth: wordAddr.width,
      dataWidth: dataWidth,
      pinMapping: macro.pinMapping,
    );
    addSubModule(sramBlock);

    final clkPin = macro.pinMapping['clk'] ?? 'clk';
    final addrPin = macro.pinMapping['addr'] ?? 'addr';
    final dataInPin = macro.pinMapping['dataIn'] ?? 'dataIn';
    final dataOutPin = macro.pinMapping['dataOut'] ?? 'dataOut';
    final wePin = macro.pinMapping['writeEnable'] ?? 'writeEnable';
    final csPin = macro.pinMapping['chipSelect'] ?? 'chipSelect';

    sramBlock.input(clkPin).srcConnection! <= clk;
    sramBlock.input(addrPin).srcConnection! <= wordAddr;
    sramBlock.input(dataInPin).srcConnection! <= datIn;
    sramBlock.input(wePin).srcConnection! <= stb & we;
    sramBlock.input(csPin).srcConnection! <= stb;

    datOut <= sramBlock.output(dataOutPin);

    Sequential(clk, [
      ack < Const(0),
      If(stb & ~ack, then: [ack < Const(1)]),
    ]);
  }

  void _buildSimModel(
    Logic clk,
    Logic wordAddr,
    Logic datIn,
    Logic datOut,
    Logic stb,
    Logic we,
    Logic ack,
    int numWords,
  ) {
    // For simulation or small memories: Yosys will infer BRAM from
    // this pattern during synthesis. Keep numWords reasonable.
    final maxSimWords = 1024;
    final effectiveWords = numWords > maxSimWords ? maxSimWords : numWords;

    final mem = <Logic>[
      for (var i = 0; i < effectiveWords; i++)
        Logic(name: 'mem_$i', width: dataWidth),
    ];

    Logic readData = Const(0, width: dataWidth);
    for (var i = 0; i < effectiveWords; i++) {
      readData = mux(
        wordAddr.eq(Const(i, width: wordAddr.width)),
        mem[i],
        readData,
      );
    }

    Sequential(clk, [
      ack < Const(0),
      datOut < Const(0, width: dataWidth),
      If(
        stb & ~ack,
        then: [
          ack < Const(1),
          If(
            we,
            then: [
              for (var i = 0; i < effectiveWords; i++)
                If(
                  wordAddr.eq(Const(i, width: wordAddr.width)),
                  then: [mem[i] < datIn],
                ),
            ],
            orElse: [datOut < readData],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,sram', 'mmio-sram'],
    reg: BusAddressRange(baseAddress, size),
    properties: {'data-width': dataWidth},
  );
}

/// PDK SRAM macro instantiated as a blackbox leaf.
class _PdkSramMacro extends BridgeModule {
  _PdkSramMacro({
    required String macroName,
    required int addrWidth,
    required int dataWidth,
    required Map<String, String> pinMapping,
  }) : super(macroName, isSystemVerilogLeaf: true) {
    final clkPin = pinMapping['clk'] ?? 'clk';
    final addrPin = pinMapping['addr'] ?? 'addr';
    final dataInPin = pinMapping['dataIn'] ?? 'dataIn';
    final dataOutPin = pinMapping['dataOut'] ?? 'dataOut';
    final wePin = pinMapping['writeEnable'] ?? 'writeEnable';
    final csPin = pinMapping['chipSelect'] ?? 'chipSelect';

    createPort(clkPin, PortDirection.input);
    createPort(addrPin, PortDirection.input, width: addrWidth);
    createPort(dataInPin, PortDirection.input, width: dataWidth);
    createPort(dataOutPin, PortDirection.output, width: dataWidth);
    createPort(wePin, PortDirection.input);
    createPort(csPin, PortDirection.input);
  }
}
