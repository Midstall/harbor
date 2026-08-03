import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Build a command word (cmdLen*serdes bits) with a single command on one slot.
/// Slot word = {cs_n, ras/cas/we, odt, cke, reset_n, bank, addr}.
BigInt _cmdWord(
  DdrParams p, {
  required int slot,
  required int cmd3,
  required int bank,
  required int addr,
  int cke = 1,
  int resetN = 1,
}) {
  final cmdLen = 4 + 3 + p.baBits + p.rowBits;
  // Every slot defaults to a deselect NOP (cs_n high, cmd3 = NOP).
  var word = BigInt.zero;
  for (var s = 0; s < p.serdesRatio; s++) {
    final active = s == slot;
    final csN = active ? 0 : 1;
    final c3 = active ? cmd3 : (Ddr3Cmd.nop & 0x7);
    final ba = active ? bank : 0;
    final ad = active ? addr : 0;
    final slotWord =
        (BigInt.from(csN) << (cmdLen - 1)) |
        (BigInt.from(c3) << (cmdLen - 4)) |
        (BigInt.from(cke) << (cmdLen - 6)) |
        (BigInt.from(resetN) << (cmdLen - 7)) |
        (BigInt.from(ba) << p.rowBits) |
        BigInt.from(ad);
    word |= slotWord << (cmdLen * s);
  }
  return word;
}

void main() {
  tearDown(() async => Simulator.reset());

  Ddr3DramModel build({
    required Logic clk,
    required Logic reset,
    required Logic cmd,
    required Logic writeData,
    required Logic bitslip,
    required DdrParams p,
  }) => Ddr3DramModel(
    p,
    controllerClk: clk,
    phyReset: reset,
    cmd: cmd,
    writeData: writeData,
    bitslip: bitslip,
    idelayDqsLd: Logic(width: p.lanes)..inject(0),
  );

  test(
    'idelayctrl_rdy is low in reset and latches high after release',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1);
      final cmd = Logic(width: (4 + 3 + p.baBits + p.rowBits) * p.serdesRatio)
        ..inject(0);
      final writeData = Logic(width: p.wbDataBits)..inject(0);
      final bitslip = Logic(width: p.lanes)..inject(0);
      final dut = build(
        clk: clk,
        reset: reset,
        cmd: cmd,
        writeData: writeData,
        bitslip: bitslip,
        p: p,
      );
      await dut.build();

      Simulator.setMaxSimTime(2000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      expect(dut.idelayctrlRdy.value.toInt(), 0);
      reset.inject(0);
      for (var i = 0; i < 12; i++) {
        await clk.nextPosedge;
      }
      expect(dut.idelayctrlRdy.value.toInt(), 1);
      await Simulator.endSimulation();
    },
  );

  test(
    'bitslip-reference barrel-rotates through 0111_1000 on bitslip pulses',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1);
      final cmd = Logic(width: (4 + 3 + p.baBits + p.rowBits) * p.serdesRatio)
        ..inject(0);
      final writeData = Logic(width: p.wbDataBits)..inject(0);
      final bitslip = Logic(width: p.lanes)..inject(0);
      final dut = build(
        clk: clk,
        reset: reset,
        cmd: cmd,
        writeData: writeData,
        bitslip: bitslip,
        p: p,
      );
      await dut.build();

      Simulator.setMaxSimTime(4000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Lane 0 starts at 0000_1111.
      expect(dut.iserdesBitslipReference.value.getRange(0, 8).toInt(), 0x0F);

      // Pulse bitslip[0] and collect the rotations we visit.
      final seen = <int>{};
      for (var i = 0; i < 8; i++) {
        seen.add(dut.iserdesBitslipReference.value.getRange(0, 8).toInt());
        bitslip.inject(1);
        await clk.nextPosedge;
        bitslip.inject(0);
        await clk.nextPosedge;
      }
      // A full rotation visits the train-1 target 0111_1000 = 0x78.
      expect(seen, contains(0x78));
      await Simulator.endSimulation();
    },
  );

  test(
    'MRS-to-MR3 toggles MPR mode and MPR reads return the 0101 pattern',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1);
      final cmdLen = 4 + 3 + p.baBits + p.rowBits;
      final cmd = Logic(width: cmdLen * p.serdesRatio)..inject(0);
      final writeData = Logic(width: p.wbDataBits)..inject(0);
      final bitslip = Logic(width: p.lanes)..inject(0);
      final dut = build(
        clk: clk,
        reset: reset,
        cmd: cmd,
        writeData: writeData,
        bitslip: bitslip,
        p: p,
      );
      await dut.build();

      Simulator.setMaxSimTime(4000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      expect(dut.mprEnabled.value.toInt(), 0);

      // Issue MRS to MR3 with MPR-enable (bank=3, addr bit2=1) on the precharge
      // slot (slot 0).
      cmd.inject(
        _cmdWord(p, slot: 0, cmd3: Ddr3Cmd.mrs, bank: 3, addr: 1 << 2),
      );
      await clk.nextPosedge;
      cmd.inject(0);
      await clk.nextPosedge;
      expect(dut.mprEnabled.value.toInt(), 1, reason: 'MPR should be enabled');

      // Issue a read on the read slot (slot 2) and wait the read latency.
      cmd.inject(
        _cmdWord(p, slot: 2, cmd3: Ddr3Cmd.rd & 0x7, bank: 0, addr: 0),
      );
      await clk.nextPosedge;
      cmd.inject(0);

      var sawMprData = false;
      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
        final data = dut.iserdesData.value;
        if (data.isValid &&
            data.getRange(0, 8).toInt() == Ddr3DramModel.mprByte) {
          sawMprData = true;
        }
      }
      expect(sawMprData, isTrue, reason: 'MPR read never returned 0x55');
      await Simulator.endSimulation();
    },
  );
}
