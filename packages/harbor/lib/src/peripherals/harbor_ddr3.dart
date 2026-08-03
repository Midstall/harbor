import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../clock/wishbone_cdc_fifo.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'ddr.dart' show HarborDdrConfig, HarborDdrType;
import 'ddr3_burst_adapter.dart';
import 'ddr3_controller.dart';
import 'ddr3_params.dart';
import 'ddr3_phy.dart';

/// Clean SoC wrapper for the production [Ddr3Controller] + [Ddr3Phy] (the
/// UberDDR3-derived, silicon-proven stack: read/write calibration + multi-row
/// bank management verified on the Arty S7).
///
/// It presents the same external contract as the legacy `HarborDdrController`
/// so genip wires it identically: a Wishbone-B4 slave `'bus'`, the DDR3 clock
/// inputs (`clk`, `reset`, `ddr_clk`, `ddr_reset`, `ddr_ck_fast`,
/// `ddr_ck90_fast`, `ddr_ck_dqs_fast`, `ddr_idelay_ref`), and the `sdram_*`
/// pads. Internally:
///
///   bus (sys clk, 32b B4) -> HarborWishboneCdcFifoBridge('ddr_cdc', 32b)
///     -> Ddr3BurstAdapter (32<->128, B4<->pipelined) -> Ddr3Controller (128b)
///     -> Ddr3Phy -> sdram_* pads          (all on ddr_clk = CK/4)
///
/// No writeVerify / readLevel / trainableRead workarounds: the controller
/// self-calibrates and keeps the bus stalled (o_wb_stall high) until
/// calibration completes, so a CPU access naturally waits for a ready array.
class HarborDdr3 extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborSystemMemoryProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  final HarborDdrConfig config;
  final int baseAddress;
  final int clockHz;
  final HarborDeviceTarget? target;

  /// DDR CK period in ps (3333 = 300 MHz, the proven Arty S7 x16 point).
  final int ckPeriodPs;

  /// When true, the controller runs in train=runtime: the PHY calibration
  /// knobs are exposed through an extra SoC-facing wishbone slave [trainBus]
  /// (the wb2 knob-ABI window) and the dtNode gains a `training` child. When
  /// false (default), wb2 stays tied off and dtNode is unchanged from train=hw.
  final bool runtimeTrainable;

  /// Size of the train (knob-ABI) window in bytes. genip maps it at
  /// baseAddress + config.size - [trainWindowSize].
  static const int trainWindowSize = 0x1000;

  /// The knob-ABI registers are 8-byte strided (a clean 64-bit stride, so the
  /// register index is the byte offset >> [trainStrideLog2]).
  static const int trainStride = 8;
  static const int trainStrideLog2 = 3;

  late final BusSlavePort bus;

  /// The knob-ABI wishbone slave, present only when [runtimeTrainable].
  BusSlavePort? trainBus;

  /// The wrapped controller, exposed for simulation tests.
  Ddr3Controller? controller;

  late final DdrParams _p;

  HarborDdr3({
    required this.config,
    required this.baseAddress,
    required this.clockHz,
    this.target,
    int? busAddressWidth,
    int? busDataWidth,
    this.ckPeriodPs = 3333,
    this.runtimeTrainable = false,
    super.name = 'ddr3',
  }) : super('HarborDdr3') {
    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());
    final ddrClk = addInput('ddr_clk', Logic());
    final ddrReset = addInput('ddr_reset', Logic());
    final ddrCk = addInput('ddr_ck_fast', Logic());
    final ddrCk90 = addInput('ddr_ck90_fast', Logic());
    addInput(
      'ddr_ck_dqs_fast',
      Logic(),
    ); // provided by genip; unused by this PHY
    final idelayRef = addInput('ddr_idelay_ref', Logic());

    final busDW = busDataWidth ?? 32;
    final busAW = busAddressWidth ?? config.size.bitLength;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAW,
      dataWidth: busDW,
    );

    final p = DdrParams.artyS7(ckPeriodPs: ckPeriodPs);
    _p = p;

    // Knob-ABI wishbone slave (train=runtime only). SoC (sys clk) facing; a
    // second CDC FIFO crosses it into the DDR clock domain in _build.
    if (runtimeTrainable) {
      trainBus = BusSlavePort.create(
        module: this,
        name: 'train',
        protocol: BusProtocol.wishbone,
        // FULL bus width: the fabric decoder drives every slave the
        // range-relative address AND data at bus width. The wb2 boundary in
        // _build narrows data/sel and converts the word address to the
        // controller's fixed 32-bit / register-index port.
        addressWidth: busAW,
        dataWidth: busDW,
      );
    }

    // SDRAM pads (single-ended SSTL135 + explicit _n complements; matches the
    // legacy Xilinx path so the genip exposePin list is unchanged).
    createPort('sdram_ck', PortDirection.output);
    createPort('sdram_ck_n', PortDirection.output);
    createPort('sdram_cke', PortDirection.output);
    createPort('sdram_cs_n', PortDirection.output);
    createPort('sdram_ras_n', PortDirection.output);
    createPort('sdram_cas_n', PortDirection.output);
    createPort('sdram_we_n', PortDirection.output);
    createPort('sdram_ba', PortDirection.output, width: p.baBits);
    createPort('sdram_addr', PortDirection.output, width: p.rowBits);
    createPort('sdram_dm', PortDirection.output, width: p.lanes);
    createPort('sdram_dq', PortDirection.inOut, width: p.dqBits * p.lanes);
    createPort('sdram_dqs', PortDirection.inOut, width: p.lanes);
    createPort('sdram_dqs_n', PortDirection.inOut, width: p.lanes);
    createPort('sdram_odt', PortDirection.output);
    createPort('sdram_reset_n', PortDirection.output);

    _build(
      clk,
      reset,
      ddrClk,
      ddrReset,
      ddrCk,
      ddrCk90,
      idelayRef,
      p,
      busDW,
      busAW,
    );
  }

  void _build(
    Logic clk,
    Logic reset,
    Logic ddrClk,
    Logic ddrReset,
    Logic ddrCk,
    Logic ddrCk90,
    Logic idelayRef,
    DdrParams p,
    int busDW,
    int busAW,
  ) {
    // Power-on reset on the DDR clock: hold rst_n low for 4096 cycles after the
    // domain reset releases (openXC7 MMCM LOCKED may never reach the fabric), the
    // same guard the standalone harness proved.
    final porCnt = Logic(name: 'ddr_por_cnt', width: 12);
    final rstN = Logic(name: 'ddr_rst_n');
    Sequential(ddrClk, [
      If(
        ddrReset,
        then: [porCnt < Const(0, width: 12), rstN < Const(0)],
        orElse: [
          If(
            porCnt.lt(4095),
            then: [porCnt < porCnt + 1, rstN < Const(0)],
            orElse: [rstN < Const(1)],
          ),
        ],
      ),
    ]);

    // --- CDC: bus-native B4, sys clk -> ddr clk (async gray-pointer FIFO) ---
    final cdc = HarborWishboneCdcFifoBridge(
      addressWidth: busAW,
      dataWidth: busDW,
      selWidth: busDW ~/ 8,
      depth: 16,
      target: target,
      name: 'ddr_cdc',
    );
    addSubModule(cdc);
    cdc.input('s_clk').srcConnection! <= clk;
    cdc.input('s_reset').srcConnection! <= reset;
    cdc.input('s_cyc').srcConnection! <= bus.stb;
    cdc.input('s_stb').srcConnection! <= Const(1);
    cdc.input('s_we').srcConnection! <= bus.we;
    cdc.input('s_adr').srcConnection! <= bus.addr;
    cdc.input('s_dat_w').srcConnection! <= bus.dataIn;
    cdc.input('s_sel').srcConnection! <= bus.sel;
    bus.ack <= cdc.output('s_ack');
    bus.dataOut <= cdc.output('s_dat_r');
    cdc.input('m_clk').srcConnection! <= ddrClk;
    cdc.input('m_reset').srcConnection! <= ddrReset;

    // --- burst adapter (32<->128) + controller <-> phy, all on ddr clk ---
    // Placeholder nets break the controller<->adapter<->phy construction cycles.
    final ctrlStall = Logic(name: 'ctrl_stall');
    final ctrlAck = Logic(name: 'ctrl_ack');
    final ctrlData = Logic(name: 'ctrl_data', width: p.wbDataBits);
    final phyData = Logic(
      name: 'phy_iserdes_data',
      width: p.dqBits * p.lanes * 8,
    );
    final phyDqs = Logic(name: 'phy_iserdes_dqs', width: p.lanes * 8);
    final phyBsRef = Logic(name: 'phy_iserdes_bsref', width: p.lanes * 8);
    final phyRdy = Logic(name: 'phy_idelayctrl_rdy');

    final adapter = Ddr3BurstAdapter(
      busAddrWidth: busAW,
      ddrAddrWidth: p.wbAddrBits,
      busDataWidth: busDW,
      ddrDataWidth: p.wbDataBits,
      auxWidth: Ddr3Controller.auxWidth,
      clk: ddrClk,
      reset: ddrReset,
      sCyc: cdc.output('m_cyc') & cdc.output('m_stb'),
      sStb: Const(1),
      sWe: cdc.output('m_we'),
      sAddr: cdc.output('m_adr'),
      sData: cdc.output('m_dat_w'),
      sSel: cdc.output('m_sel'),
      mStall: ctrlStall,
      mAck: ctrlAck,
      mData: ctrlData,
    );
    cdc.input('m_ack').srcConnection! <= adapter.output('s_ack');
    cdc.input('m_dat_r').srcConnection! <= adapter.output('s_data_out');

    // --- wb2 knob-ABI window: sys-clk slave -> CDC FIFO -> ddr-clk wb2 ---
    // Placeholder nets break the wb2<->CDC construction cycle (train=runtime).
    Logic wb2Cyc = Const(0);
    Logic wb2Stb = Const(0);
    Logic wb2We = Const(0);
    Logic wb2Addr = Const(0, width: Ddr3Controller.wb2AddrBits);
    Logic wb2Sel = Const(0, width: Ddr3Controller.wb2SelBits);
    Logic wb2Data = Const(0, width: Ddr3Controller.wb2DataBits);
    Logic? wb2Ack;
    Logic? wb2DataOut;
    HarborWishboneCdcFifoBridge? trainCdc;
    if (runtimeTrainable) {
      wb2Ack = Logic(name: 'ctrl_wb2_ack');
      wb2DataOut = Logic(
        name: 'ctrl_wb2_data',
        width: Ddr3Controller.wb2DataBits,
      );
      // The CDC carries the FULL bus width so it matches the fabric decoder.
      // Its config MUST match the main ddr_cdc (width + depth), so ROHD dedupes
      // both onto one HarborWishboneCdcFifoBridge definition (the class hardcodes
      // its definition name; a differing config would collide at synth).
      trainCdc = HarborWishboneCdcFifoBridge(
        addressWidth: busAW,
        dataWidth: busDW,
        selWidth: busDW ~/ 8,
        depth: 16,
        target: target,
        name: 'train_cdc',
      );
      addSubModule(trainCdc);
      trainCdc.input('s_clk').srcConnection! <= clk;
      trainCdc.input('s_reset').srcConnection! <= reset;
      trainCdc.input('s_cyc').srcConnection! <= trainBus!.stb;
      trainCdc.input('s_stb').srcConnection! <= Const(1);
      trainCdc.input('s_we').srcConnection! <= trainBus!.we;
      trainCdc.input('s_adr').srcConnection! <= trainBus!.addr;
      trainCdc.input('s_dat_w').srcConnection! <= trainBus!.dataIn;
      trainCdc.input('s_sel').srcConnection! <= trainBus!.sel;
      trainBus!.ack <= trainCdc.output('s_ack');
      // Read data: the controller returns 32 bits; zero-extend to the bus.
      trainBus!.dataOut <= trainCdc.output('s_dat_r').getRange(0, busDW);
      trainCdc.input('m_clk').srcConnection! <= ddrClk;
      trainCdc.input('m_reset').srcConnection! <= ddrReset;

      // --- wb2 boundary adaptation (fabric bus width -> fixed 32b / reg-index) ---
      // ADR: harbor wishbone adr is word-granular (byteOffset >> wordShift).
      // The controller decodes a REGISTER INDEX = byteOffset >> trainStrideLog2.
      // Reconstruct the byte offset from m_adr then divide by the 8-byte stride.
      final wordShift = (busDW ~/ 8).bitLength - 1; // log2(bytesPerWord)
      final mAdr = trainCdc.output('m_adr');
      final byteAddr = wordShift == 0
          ? mAdr
          : [mAdr, Const(0, width: wordShift)].swizzle();
      wb2Addr = byteAddr.getRange(
        trainStrideLog2,
        trainStrideLog2 + Ddr3Controller.wb2AddrBits,
      );

      wb2Cyc = trainCdc.output('m_cyc') & trainCdc.output('m_stb');
      wb2Stb = Const(1);
      wb2We = trainCdc.output('m_we');
      // DATA/SEL: the 32-bit register lives in the low word of the bus word.
      wb2Sel = trainCdc.output('m_sel').getRange(0, Ddr3Controller.wb2SelBits);
      wb2Data = trainCdc
          .output('m_dat_w')
          .getRange(0, Ddr3Controller.wb2DataBits);
      trainCdc.input('m_ack').srcConnection! <= wb2Ack;
      // Zero-extend the 32-bit read response back to the CDC (bus) width.
      trainCdc.input('m_dat_r').srcConnection! <= wb2DataOut.zeroExtend(busDW);
    }

    final ctrl = Ddr3Controller(
      p,
      controllerClk: ddrClk,
      rstN: rstN,
      wbCyc: adapter.output('m_cyc'),
      wbStb: adapter.output('m_stb'),
      wbWe: adapter.output('m_we'),
      wbAddr: adapter.output('m_addr'),
      wbData: adapter.output('m_data_out'),
      wbSel: adapter.output('m_sel'),
      aux: adapter.output('m_aux'),
      wb2Cyc: wb2Cyc,
      wb2Stb: wb2Stb,
      wb2We: wb2We,
      wb2Addr: wb2Addr,
      wb2Sel: wb2Sel,
      wb2Data: wb2Data,
      phyIserdesData: phyData,
      phyIserdesDqs: phyDqs,
      phyIserdesBitslipReference: phyBsRef,
      phyIdelayctrlRdy: phyRdy,
      runtimeTrainable: runtimeTrainable,
    );
    controller = ctrl;
    ctrlStall <= ctrl.output('o_wb_stall');
    ctrlAck <= ctrl.output('o_wb_ack');
    ctrlData <= ctrl.output('o_wb_data');
    if (runtimeTrainable) {
      wb2Ack! <= ctrl.output('o_wb2_ack');
      wb2DataOut! <= ctrl.output('o_wb2_data');
    }

    // --- inout pads to the PHY (harbor idiom: net through createPort/inOut) ---
    final dqPad = inOut('sdram_dq') as LogicNet;
    final dqsPad = inOut('sdram_dqs') as LogicNet;
    final dqsNPad = inOut('sdram_dqs_n') as LogicNet;

    final phy = Ddr3Phy(
      p,
      controllerClk: ddrClk,
      ddr3Clk: ddrCk,
      refClk: idelayRef,
      ddr3Clk90: ddrCk90,
      rstN: rstN,
      controllerReset: ctrl.phyReset,
      cmd: ctrl.phyCmd,
      dqsTriControl: ctrl.output('o_phy_dqs_tri_control'),
      dqTriControl: ctrl.output('o_phy_dq_tri_control'),
      toggleDqs: ctrl.output('o_phy_toggle_dqs'),
      data: ctrl.output('o_phy_data'),
      dm: ctrl.output('o_phy_dm'),
      odelayDataCntValueIn: ctrl.output('o_phy_odelay_data_cntvaluein'),
      odelayDqsCntValueIn: ctrl.output('o_phy_odelay_dqs_cntvaluein'),
      idelayDataCntValueIn: ctrl.output('o_phy_idelay_data_cntvaluein'),
      idelayDqsCntValueIn: ctrl.output('o_phy_idelay_dqs_cntvaluein'),
      odelayDataLd: ctrl.output('o_phy_odelay_data_ld'),
      odelayDqsLd: ctrl.output('o_phy_odelay_dqs_ld'),
      idelayDataLd: ctrl.output('o_phy_idelay_data_ld'),
      idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
      bitslip: ctrl.output('o_phy_bitslip'),
      writeLevelingCalib: ctrl.output('o_phy_write_leveling_calib'),
      dqPad: dqPad,
      dqsPad: dqsPad,
      dqsNPad: dqsNPad,
    );
    phyData <= phy.iserdesData;
    phyDqs <= phy.iserdesDqs;
    phyBsRef <= phy.iserdesBitslipReference;
    phyRdy <= phy.idelayctrlRdy;

    // --- drive the SDRAM control/address pads ---
    output('sdram_ck') <= phy.output('o_ddr3_clk_p');
    output('sdram_ck_n') <= phy.output('o_ddr3_clk_n');
    output('sdram_cke') <= phy.output('o_ddr3_cke');
    output('sdram_cs_n') <= phy.output('o_ddr3_cs_n');
    output('sdram_ras_n') <= phy.output('o_ddr3_ras_n');
    output('sdram_cas_n') <= phy.output('o_ddr3_cas_n');
    output('sdram_we_n') <= phy.output('o_ddr3_we_n');
    output('sdram_ba') <= phy.output('o_ddr3_ba_addr');
    output('sdram_addr') <= phy.output('o_ddr3_addr');
    output('sdram_dm') <= phy.output('o_ddr3_dm');
    output('sdram_odt') <= phy.output('o_ddr3_odt');
    output('sdram_reset_n') <= phy.output('o_ddr3_reset_n');
  }

  /// Number of DQ byte lanes (dataWidth / 8). Used by the openXC7 DDR
  /// nextpnr pre-place script generator to know how many train SERDES pairs
  /// to pin.
  int get lanes => _p.lanes;

  /// Base of the knob-ABI window: end of the DRAM aperture minus one page.
  int get trainBase => baseAddress + config.size - trainWindowSize;

  /// Usable DRAM span. In train=runtime the top [trainWindowSize] bytes are the
  /// knob-ABI slave (a distinct decoder slot), so they are NOT DRAM: the main
  /// bus mapping + the memory node must exclude them to avoid a decoder overlap.
  int get usableSize =>
      runtimeTrainable ? config.size - trainWindowSize : config.size;

  /// The `training` device-tree child (train=runtime only): geometry-free knob
  /// table + register window that the FSBL sweep engine reads. Reg offsets match
  /// the [Ddr3Controller] wb2 knob-ABI decode; APPLY order = child order.
  HarborDeviceTreeChild get _trainingNode => HarborDeviceTreeChild(
    name: 'training',
    properties: {
      'harbor,train-reg': [trainBase, trainWindowSize],
      'harbor,train-stride': 8,
    },
    children: const [
      HarborDeviceTreeChild(
        name: 'knob@0',
        properties: {
          'harbor,knob': 'write-level',
          'harbor,reg': [0x00],
          'harbor,scope': 'per-lane',
          'harbor,feedback': 'map',
        },
      ),
      HarborDeviceTreeChild(
        name: 'knob@1',
        properties: {
          'harbor,knob': 'write-odelay',
          'harbor,reg': [0x08],
          'harbor,scope': 'per-lane',
          'harbor,feedback': 'pattern',
          'harbor,min': [0],
          'harbor,max': [31],
        },
      ),
      HarborDeviceTreeChild(
        name: 'knob@2',
        properties: {
          'harbor,knob': 'read-idelay',
          'harbor,reg': [0x10],
          'harbor,scope': 'per-lane',
          'harbor,feedback': 'pattern',
          'harbor,min': [0],
          'harbor,max': [31],
        },
      ),
      HarborDeviceTreeChild(
        name: 'knob@3',
        properties: {
          'harbor,knob': 'bitslip',
          'harbor,reg': [0x18],
          'harbor,scope': 'per-lane',
          'harbor,feedback': 'pattern',
          'harbor,min': [0],
          'harbor,max': [7],
        },
      ),
    ],
  );

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: [
      'harbor,sdram-controller',
      if (config.type == HarborDdrType.ddr3 ||
          config.type == HarborDdrType.ddr3l)
        'harbor,ddr3-sdram',
    ],
    reg: BusAddressRange(baseAddress, usableSize),
    properties: {
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
      if (runtimeTrainable) ...{
        'harbor,ddr-rows': _p.rowBits,
        'harbor,ddr-cols': _p.colBits,
        'harbor,ddr-banks': 1 << _p.baBits,
        'harbor,ddr-ranks': _p.dualRankDimm ? 2 : 1,
        'harbor,ddr-lanes': _p.lanes,
      },
    },
    children: [if (runtimeTrainable) _trainingNode],
  );

  @override
  List<BusAddressRange> get systemMemory => [
    BusAddressRange(baseAddress, usableSize),
  ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, usableSize)],
    properties: {
      'compatible': [
        'harbor,sdram-controller',
        if (config.type == HarborDdrType.ddr3 ||
            config.type == HarborDdrType.ddr3l)
          'harbor,ddr3-sdram',
      ],
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DDR',
    groupName: 'DDR',
    description: 'SDRAM memory controller (Ddr3Controller)',
    baseAddress: baseAddress,
    size: config.size,
  );
}
