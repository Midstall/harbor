import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';

/// Bank-management sim: drive the wishbone across same-bank / different-row
/// accesses after calibration and decode the emitted DDR command stream to
/// verify each read/write actually targets the intended {bank,row,col}. This
/// reproduces the hardware memtest failure (a read hitting the wrong open row)
/// in pure ROHD sim - no PHY blackbox needed for the bank-management logic.

int _clog2(int x) {
  var n = 0;
  var v = x - 1;
  while (v > 0) {
    v >>= 1;
    n++;
  }
  return n;
}

/// One decoded active command on some CK slot within a controller cycle.
class DecodedCmd {
  final int slot, cmd3, bank, addr;
  DecodedCmd(this.slot, this.cmd3, this.bank, this.addr);
  String get name => const {
    0: 'MRS',
    1: 'REF',
    2: 'PRE',
    3: 'ACT',
    4: 'WR',
    5: 'RD',
    6: 'ZQC',
    7: 'NOP',
  }[cmd3]!;
}

List<DecodedCmd> decodeCmd(LogicValue v, DdrParams p) {
  final cmdLen = 4 + 3 + p.baBits + p.rowBits;
  final out = <DecodedCmd>[];
  for (var s = 0; s < p.serdesRatio; s++) {
    final slot = v.getRange(cmdLen * s, cmdLen * (s + 1));
    if (!slot.isValid) continue;
    final csN = slot[cmdLen - 1].toInt();
    if (csN != 0) continue; // deselect
    final cmd3 = slot.getRange(cmdLen - 4, cmdLen - 1).toInt();
    if (cmd3 == Ddr3Cmd.nop) continue;
    final bank = slot.getRange(p.rowBits, p.rowBits + p.baBits).toInt();
    final addr = slot.getRange(0, p.rowBits).toInt();
    out.add(DecodedCmd(s, cmd3, bank, addr));
  }
  return out;
}

Future<void> main() async {
  // Fast-reset timing (tiny periods -> few reset cycles), serdes = 4 (same DQ
  // width + address map as the Arty S7 x16).
  final p = DdrParams(controllerClkPeriodPs: 800000, ddr3ClkPeriodPs: 200000);
  final clog2sr2 = _clog2(p.serdesRatio * 2);
  final colLo = p.colBits - clog2sr2;
  // wb address for a given bank / row / column-group.
  int addrOf(int bank, int row, int colGroup) =>
      (row << (colLo + p.baBits)) | (bank << colLo) | colGroup;

  final clk = SimpleClockGenerator(10).clk;
  final rstN = Logic(name: 'rstn');
  final wbCyc = Logic(name: 'wb_cyc')..inject(0);
  final wbStb = Logic(name: 'wb_stb')..inject(0);
  final wbWe = Logic(name: 'wb_we')..inject(0);
  final wbAddr = Logic(name: 'wb_addr', width: p.wbAddrBits)..inject(0);
  final wbData = Logic(name: 'wb_data', width: p.wbDataBits)..inject(0);
  final wbSel = Logic(name: 'wb_sel', width: p.wbSelBits)..inject(0);
  final aux = Logic(name: 'aux', width: Ddr3Controller.auxWidth)..inject(0);

  final phyData = Logic(name: 'phy_data', width: p.dqBits * p.lanes * 8);
  final phyDqs = Logic(name: 'phy_dqs', width: p.lanes * 8);
  final phyBsRef = Logic(name: 'phy_bsref', width: p.lanes * 8);
  final phyRdy = Logic(name: 'phy_rdy');

  final ctrl = Ddr3Controller(
    p,
    controllerClk: clk,
    rstN: rstN,
    wbCyc: wbCyc,
    wbStb: wbStb,
    wbWe: wbWe,
    wbAddr: wbAddr,
    wbData: wbData,
    wbSel: wbSel,
    aux: aux,
    wb2Cyc: Logic()..inject(0),
    wb2Stb: Logic()..inject(0),
    wb2We: Logic()..inject(0),
    wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
    wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
    wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
    phyIserdesData: phyData,
    phyIserdesDqs: phyDqs,
    phyIserdesBitslipReference: phyBsRef,
    phyIdelayctrlRdy: phyRdy,
  );
  final model = Ddr3DramModel(
    p,
    controllerClk: clk,
    phyReset: ctrl.phyReset,
    cmd: ctrl.phyCmd,
    writeData: ctrl.output('o_phy_data'),
    bitslip: ctrl.output('o_phy_bitslip'),
    idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
  );
  phyData <= model.iserdesData;
  phyDqs <= model.iserdesDqs;
  phyBsRef <= model.iserdesBitslipReference;
  phyRdy <= model.idelayctrlRdy;

  await ctrl.build();
  await model.build();

  rstN.inject(0);
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  rstN.inject(1);

  // 1) run calibration to DONE_CALIBRATE (state 23) so the wishbone is live.
  var done = false;
  for (var i = 0; i < 60000 && !done; i++) {
    await clk.nextPosedge;
    final st = ctrl.debug1.value;
    if (st.isValid && (st.toInt() & 0x3F) == 23) done = true;
  }
  print('calibration reached DONE_CALIBRATE(23): $done');
  if (!done) {
    print('FAILED to calibrate in sim; aborting');
    await Simulator.endSimulation();
    return;
  }

  // 2) drive wishbone transactions and record the command stream.
  final trace = <DecodedCmd>[];
  final allSel = (BigInt.one << p.wbSelBits) - BigInt.one;

  Future<void> record() async {
    trace.addAll(decodeCmd(ctrl.phyCmd.value, p));
  }

  // Non-pipelined helper: assert a request until accepted (~stall), then idle a
  // few cycles (recording commands) so any activate/precharge/read/write lands.
  Future<void> issue({
    required bool we,
    required int addr,
    int data = 0,
  }) async {
    wbCyc.inject(1);
    wbStb.inject(1);
    wbWe.inject(we ? 1 : 0);
    wbAddr.inject(addr);
    wbData.inject(BigInt.from(data));
    wbSel.inject(we ? allSel : BigInt.zero);
    aux.inject(1);
    // wait until accepted
    var guard = 0;
    do {
      await clk.nextPosedge;
      await record();
      guard++;
    } while (ctrl.output('o_wb_stall').value.toInt() == 1 && guard < 400);
    // deassert stb (keep cyc), let the command drain
    wbStb.inject(0);
    for (var i = 0; i < 24; i++) {
      await clk.nextPosedge;
      await record();
    }
  }

  // Repro: same bank (1), two different rows, then read the first back.
  const bank = 1, colGroup = 0;
  final aAddr = addrOf(bank, 0, colGroup); // {bank1,row0,col0}
  final bAddr = addrOf(bank, 32, colGroup); // {bank1,row32,col0}
  print('addr A = $aAddr  {bank $bank,row 0,col0}');
  print('addr B = $bAddr  {bank $bank,row 32,col0}');

  final startA = trace.length;
  await issue(we: true, addr: aAddr, data: 0xAA);
  final afterWriteA = trace.length;
  await issue(we: true, addr: bAddr, data: 0xBB);
  final afterWriteB = trace.length;
  await issue(we: false, addr: aAddr); // READ A back
  final afterReadA = trace.length;

  wbCyc.inject(0);

  // 3) replay the command trace to compute each command's effective target and
  // verify the READ of A lands on {bank1,row0}.
  final openRow = <int, int?>{};
  void printPhase(String label, int from, int to) {
    print('--- $label ---');
    for (var i = from; i < to; i++) {
      final c = trace[i];
      final extra = c.cmd3 == Ddr3Cmd.act
          ? ' row=${c.addr}'
          : (c.cmd3 == Ddr3Cmd.rd || c.cmd3 == Ddr3Cmd.wr)
          ? ' col=${c.addr & 0x3FF} (openRow=${openRow[c.bank]})'
          : '';
      print('  ${c.name} bank=${c.bank}$extra');
      if (c.cmd3 == Ddr3Cmd.act) openRow[c.bank] = c.addr;
      if (c.cmd3 == Ddr3Cmd.pre) openRow[c.bank] = null;
    }
  }

  printPhase('WRITE A {bank1,row0}', startA, afterWriteA);
  printPhase('WRITE B {bank1,row32}', afterWriteA, afterWriteB);
  printPhase('READ A {bank1,row0}', afterWriteB, afterReadA);

  // Verdict: find the RD command in the read-A phase and check the open row.
  var verdict = 'NO READ COMMAND SEEN';
  final replay = <int, int?>{};
  for (var i = 0; i < afterReadA; i++) {
    final c = trace[i];
    if (i >= afterWriteB && c.cmd3 == Ddr3Cmd.rd) {
      final open = replay[c.bank];
      verdict = (open == 0)
          ? 'PASS: read A hit the correct open row 0 in bank ${c.bank}'
          : 'FAIL: read A issued while bank ${c.bank} had row $open open '
                '(expected row 0) -> reads the WRONG row';
      break;
    }
    if (c.cmd3 == Ddr3Cmd.act) replay[c.bank] = c.addr;
    if (c.cmd3 == Ddr3Cmd.pre) replay[c.bank] = null;
  }
  print('=== VERDICT: $verdict ===');

  await Simulator.endSimulation();
}
