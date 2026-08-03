import 'package:rohd/rohd.dart';

import 'ddr3_mode_registers.dart';
import 'ddr3_params.dart';

/// Behavioral DDR3 PHY + DRAM simulation model, at the controller's PHY
/// boundary (o_phy_* -> i_phy_*).
///
/// The real [Ddr3Phy] is built from Xilinx primitive blackboxes that have no
/// ROHD simulation behavior, so the calibration FSM cannot be co-simulated
/// against the structural PHY. This model stands in for PHY + DRAM together: it
/// consumes the controller's command/write outputs and produces the read-return,
/// DQS, bitslip-reference and idelayctrl-ready feedback the calibration engine
/// samples, at controller-clock granularity. It is a functional model for
/// verifying the FSM's control flow, not a timing-accurate device.
///
/// Modeled behavior:
///  - `idelayctrl_rdy` asserts a few cycles after reset (IDELAYCTRL lock).
///  - the bitslip-reference per lane barrel-rotates on each bitslip pulse,
///    visiting every rotation of the 0000_1111 train pattern (so the FSM's
///    0111_1000 target and the 0011_1100-derived arrangements are all reachable).
///  - an MRS-to-MR3 command toggles MPR mode (predefined pattern 0101...).
///  - a read command (cs_n low on the read slot) returns, after a fixed latency,
///    the MPR pattern (MPR mode) or the stored data (normal mode), and drives a
///    toggling DQS window the read-training states can frame against.
///  - a write command captures o_phy_data into a small backing memory.
class Ddr3DramModel extends Module {
  final DdrParams params;

  int get lanes => params.lanes;
  int get dq => params.dqBits * lanes;
  int get serdes => params.serdesRatio;
  int get cmdLen => 4 + 3 + params.baBits + params.rowBits;

  /// Read latency in controller cycles from a read command to data-valid. Kept
  /// in step with the FSM's `delay_before_read_data` (READ_DELAY + pipeline).
  static const int readLatency = 4;

  /// The MPR predefined pattern byte (0101_0101).
  static const int mprByte = 0x55;

  Logic get iserdesData => output('o_controller_iserdes_data');
  Logic get iserdesDqs => output('o_controller_iserdes_dqs');
  Logic get iserdesBitslipReference =>
      output('o_controller_iserdes_bitslip_reference');
  Logic get idelayctrlRdy => output('o_controller_idelayctrl_rdy');

  /// Live MPR-mode flag (observable for the testbench).
  Logic get mprEnabled => output('dbg_mpr_enabled');

  Ddr3DramModel(
    this.params, {
    required Logic controllerClk,
    required Logic phyReset,
    required Logic cmd, // o_phy_cmd [cmdLen*serdes]
    required Logic writeData, // o_phy_data [wbData]
    required Logic bitslip, // o_phy_bitslip [lanes]
    required Logic idelayDqsLd, // o_phy_idelay_dqs_ld [lanes]
    super.name = 'ddr3_dram_model',
  }) {
    controllerClk = addInput('i_controller_clk', controllerClk);
    phyReset = addInput('i_phy_reset', phyReset);
    cmd = addInput('o_phy_cmd', cmd, width: cmdLen * serdes);
    writeData = addInput('o_phy_data', writeData, width: params.wbDataBits);
    bitslip = addInput('o_phy_bitslip', bitslip, width: lanes);
    idelayDqsLd = addInput('o_phy_idelay_dqs_ld', idelayDqsLd, width: lanes);

    addOutput('o_controller_iserdes_data', width: dq * 8);
    addOutput('o_controller_iserdes_dqs', width: lanes * 8);
    addOutput('o_controller_iserdes_bitslip_reference', width: lanes * 8);
    addOutput('o_controller_idelayctrl_rdy');
    addOutput('dbg_mpr_enabled');

    _buildIdelayctrl(controllerClk, phyReset);
    _buildBitslipReference(controllerClk, phyReset, bitslip);
    final dec = _decodeCommand(controllerClk, phyReset, cmd);
    _buildReadReturn(
      controllerClk,
      phyReset,
      dec.readStrobe,
      dec.writeStrobe,
      dec.mpr,
      writeData,
      idelayDqsLd,
      dec.rdAddrBit,
      dec.wrAddrBit,
    );
  }

  // Slot i of o_phy_cmd occupies bits [cmdLen*(i+1)-1 : cmdLen*i]; the slot word
  // is {cs_n, ras/cas/we, odt, cke, reset_n, bank, addr}.
  Logic _slot(Logic cmd, int slot) =>
      cmd.getRange(cmdLen * slot, cmdLen * (slot + 1));
  Logic _slotCsN(Logic slotWord) => slotWord[cmdLen - 1];
  Logic _slotCmd3(Logic slotWord) => slotWord.getRange(cmdLen - 4, cmdLen - 1);
  Logic _slotBank(Logic slotWord) =>
      slotWord.getRange(params.rowBits, params.rowBits + params.baBits);
  Logic _slotAddr(Logic slotWord) => slotWord.getRange(0, params.rowBits);

  /// IDELAYCTRL ready: low in reset, latches high a few cycles after release.
  void _buildIdelayctrl(Logic clk, Logic reset) {
    final rdy = Logic(name: 'idelayctrl_rdy');
    final cnt = Logic(name: 'idelay_lock_cnt', width: 4);
    Sequential(clk, [
      If(
        reset,
        then: [rdy < Const(0), cnt < Const(0, width: 4)],
        orElse: [
          If(cnt.lt(8), then: [cnt < cnt + 1], orElse: [rdy < Const(1)]),
        ],
      ),
    ]);
    output('o_controller_idelayctrl_rdy') <= rdy;
  }

  /// Per-lane bitslip-reference: init to a rotation of the 0000_1111 train
  /// pattern, barrel-rotate on each bitslip pulse. Visits 0111_1000 (train-1
  /// target) and every 0011_1100-derived arrangement.
  void _buildBitslipReference(Logic clk, Logic reset, Logic bitslip) {
    final refs = <Logic>[];
    for (var l = 0; l < lanes; l++) {
      final ref = Logic(name: 'bitslip_ref_$l', width: 8);
      Sequential(clk, [
        If(
          reset,
          then: [
            ref < Const(0x0F, width: 8), // 0000_1111
          ],
          orElse: [
            If(
              bitslip[l],
              then: [
                // rotate left by one (barrel): {ref[6:0], ref[7]}.
                ref < [ref.getRange(0, 7), ref[7]].swizzle(),
              ],
            ),
          ],
        ),
      ]);
      refs.add(ref);
    }
    output('o_controller_iserdes_bitslip_reference') <= refs.rswizzle();
  }

  /// Decode the command stream: MPR mode toggles on an MRS-to-MR3 command, a
  /// read strobe pulses when the read slot's cs_n is asserted.
  ({
    Logic readStrobe,
    Logic writeStrobe,
    Logic mpr,
    Logic rdAddrBit,
    Logic wrAddrBit,
  })
  _decodeCommand(Logic clk, Logic reset, Logic cmd) {
    // Precharge slot (0) carries MRS: cs_n low, cmd3 = MRS (000). The bank field
    // is the MR select; MR3 MPR-enable is addr bit 2.
    final preSlot = _slot(cmd, 0);
    final isMrs = ~_slotCsN(preSlot) & _slotCmd3(preSlot).eq(Ddr3Cmd.mrs);
    final mrSel = _slotBank(preSlot);
    final isMr3 = isMrs & mrSel.eq(0x3);
    final mprEnBit = _slotAddr(preSlot)[2];

    final mpr = Logic(name: 'mpr_enabled');
    Sequential(clk, [
      If(
        reset,
        then: [mpr < Const(0)],
        orElse: [
          If(isMr3, then: [mpr < mprEnBit]),
        ],
      ),
    ]);
    output('dbg_mpr_enabled') <= mpr;

    // Read slot (2): cs_n low + cmd3 = RD (101).
    final rdSlot = _slot(cmd, 2);
    final readStrobe =
        ~_slotCsN(rdSlot) & _slotCmd3(rdSlot).eq(Ddr3Cmd.rd & 0x7);
    // Write slot (3): cs_n low + cmd3 = WR (100).
    final wrSlot = _slot(cmd, 3);
    final writeStrobe =
        ~_slotCsN(wrSlot) & _slotCmd3(wrSlot).eq(Ddr3Cmd.wr & 0x7);
    // Address discriminator for the calibration BIST (addr 0 = col 0, addr 1 =
    // col 8): column bit 3 of the read/write command's address field.
    final rdAddrBit = _slotAddr(rdSlot)[3];
    final wrAddrBit = _slotAddr(wrSlot)[3];
    return (
      readStrobe: readStrobe,
      writeStrobe: writeStrobe,
      mpr: mpr,
      rdAddrBit: rdAddrBit,
      wrAddrBit: wrAddrBit,
    );
  }

  /// Read return + DQS. [readStrobe] pulses when a read is issued; [readLatency]
  /// cycles later the data-valid window opens for two cycles, presenting the MPR
  /// pattern (MPR mode) or the stored write data, with a toggling DQS.
  void _buildReadReturn(
    Logic clk,
    Logic reset,
    Logic readStrobe,
    Logic writeStrobe,
    Logic mpr,
    Logic writeData,
    Logic idelayDqsLd,
    Logic rdAddrBit,
    Logic wrAddrBit,
  ) {
    // A shift register that turns a read strobe into a data-valid pulse
    // [readLatency] cycles later, with extra stages so the DQS burst can be
    // placed a couple of cycles after the data (so the collect sequence captures
    // a quiet 0x00 byte *below* the 0x55 in dqs_store - the 01_01_01_01_00
    // boundary is 0x55 shifted up by two, i.e. a quiet postamble underneath it).
    const pipeLen = readLatency + 8;
    final pipe = Logic(name: 'read_valid_pipe', width: pipeLen + 1);
    Sequential(clk, [
      If(
        reset,
        then: [pipe < Const(0, width: pipeLen + 1)],
        orElse: [
          pipe < [pipe.getRange(0, pipeLen), readStrobe].swizzle(),
        ],
      ),
    ]);
    final dataValid = pipe[readLatency];

    // A tiny two-entry memory (calibration BIST writes address 0 and 1). The
    // write data (o_phy_data) arrives a couple of cycles after the write
    // command, so capture it a few cycles later. mem index = column bit 3.
    final wrPending = Logic(name: 'wr_pending', width: 4);
    final wrIndex = Logic(name: 'wr_index');
    final mem0 = Logic(name: 'mem0', width: params.wbDataBits);
    final mem1 = Logic(name: 'mem1', width: params.wbDataBits);
    // Read-data hold: latched on a (non-MPR) read command and held so the
    // controller's read pipe can capture it whenever it releases.
    final readHold = Logic(name: 'read_hold', width: params.wbDataBits);
    Sequential(clk, [
      If(
        reset,
        then: [
          wrPending < Const(0, width: 4),
          wrIndex < Const(0),
          mem0 < Const(0, width: params.wbDataBits),
          mem1 < Const(0, width: params.wbDataBits),
          readHold < Const(0, width: params.wbDataBits),
        ],
        orElse: [
          // schedule a write-data capture a few cycles after the command.
          If(
            writeStrobe,
            then: [
              wrPending < Const(1 << 2, width: 4), // capture ~2 cycles later
              wrIndex < wrAddrBit,
            ],
            orElse: [wrPending < (wrPending >> 1)],
          ),
          If(
            wrPending[0],
            then: [
              If(wrIndex, then: [mem1 < writeData], orElse: [mem0 < writeData]),
            ],
          ),
          If(readStrobe & ~mpr, then: [readHold < mux(rdAddrBit, mem1, mem0)]),
        ],
      ),
    ]);

    // Data: MPR pattern (every byte 0x55) during read cal, or the held read
    // data (from the two-entry memory) during the BIST write/read verify.
    final mprWord = Const(
      _repeatByte(mprByte, params.wbDataBits ~/ 8),
      width: params.wbDataBits,
    );
    // MPR reads present the windowed pattern; BIST reads hold their memory word.
    output('o_controller_iserdes_data') <=
        mux(mpr, mux(dataValid, mprWord, Const(0, width: dq * 8)), readHold);

    // DQS: model the read strobe the controller deserializes into dqs_store over
    // the 5 collect cycles. Per lane, present the byte slices of the 40-bit word
    // 0x55 << (2 + tap): dqs_store then equals that word, so the 01_01_01_01_00
    // boundary (0x55 << 2) sits at bit index = tap. Each idelay_dqs load bumps
    // tap by one, walking the found start index up to the eye-centre target -
    // the model of the per-bit IDELAY read-eye sweep.
    final tapWidth = 6;
    final taps = <Logic>[];
    for (var l = 0; l < lanes; l++) {
      final tap = Logic(name: 'dqs_tap_$l', width: tapWidth);
      Sequential(clk, [
        If(
          reset,
          then: [tap < Const(0, width: tapWidth)],
          orElse: [
            If(idelayDqsLd[l], then: [tap < tap + 1]),
          ],
        ),
      ]);
      taps.add(tap);
    }
    // The 5 collect cycles line up with pipe stages [readLatency+2 .. +6]
    // (cycle 0 = the lowest dqs_store byte).
    final dqsWord = [
      for (var l = 0; l < lanes; l++) _laneDqsByte(taps[l], pipe),
    ].rswizzle();
    output('o_controller_iserdes_dqs') <= dqsWord;
  }

  /// Per-lane DQS byte for the current collect cycle: the byte slices of the
  /// 40-bit word 0x55 << (2 + tap) across the 5 collect pipe stages (only one
  /// stage is hot at a time). dqs_store then reconstructs that word.
  Logic _laneDqsByte(Logic tap, Logic pipe) {
    final shiftAmt = tap.zeroExtend(7) + 2;
    final target = Const(0x55, width: 48) << shiftAmt;
    Logic acc = Const(0, width: 8);
    for (var c = 0; c < _storedDqsSize; c++) {
      final byteC = (target >> (8 * c)).getRange(0, 8);
      acc = acc | mux(pipe[readLatency + 2 + c], byteC, Const(0, width: 8));
    }
    return acc;
  }

  static const int _storedDqsSize = 5;

  static int _repeatByte(int b, int count) {
    var v = 0;
    for (var i = 0; i < count; i++) {
      v = (v << 8) | (b & 0xFF);
    }
    return v;
  }
}
