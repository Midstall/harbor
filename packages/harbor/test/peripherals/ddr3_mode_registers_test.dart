import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:test/test.dart';

void main() {
  final t = DdrTiming.fromPs(ddr3ClkPeriodPs: 3333, serdesRatio: 4);
  final mr = Ddr3ModeRegisters(t);

  group('mode-register values', () {
    test('MR0: BL8, CL10, DLL reset, WR from tWR/CK', () {
      // Matches the h520 value the read-phase work confirmed on hardware.
      expect(mr.mr0, 0x520);
    });
    test('MR1 write-leveling enable/disable differ only in bit 7', () {
      expect(mr.mr1WlEn, 0x100C4);
      expect(mr.mr1WlDis, 0x10044);
      expect(mr.mr1WlEn ^ mr.mr1WlDis, 1 << 7);
    });
    test('MR2: CWL8, ASR on', () {
      expect(mr.mr2, 0x20040);
    });
    test('MR3 MPR enable sets the MPR bit, disable clears it', () {
      expect(mr.mr3MprEn, 0x30004);
      expect(mr.mr3MprDis, 0x30000);
    });
  });

  group('reset / refresh ROM', () {
    test('addr 0 holds RESET# low with the 200 us timer', () {
      final i = Ddr3Instruction(mr.romWord(0));
      expect(i.resetN, 0);
      expect(i.cke, 0);
      expect(i.useTimer, 1);
      expect(i.cmd, Ddr3Cmd.nop);
      expect(i.payload, t.nsToCycles(200000)); // 200 us
    });

    test('addr 1 raises RESET# but keeps CKE low (500 us)', () {
      final i = Ddr3Instruction(mr.romWord(1));
      expect(i.resetN, 1);
      expect(i.cke, 0);
      expect(i.payload, t.nsToCycles(500000));
    });

    test(
      'MRS entries carry CKE/RESET# high, MRS command, and A10 = MR[10]',
      () {
        for (final entry in [
          (3, mr.mr2),
          (4, mr.mr3MprDis),
          (5, mr.mr1WlDis),
          (6, mr.mr0),
          (10, mr.mr3MprEn),
          (14, mr.mr1WlEn),
        ]) {
          final i = Ddr3Instruction(mr.romWord(entry.$1));
          expect(i.cmd, Ddr3Cmd.mrs, reason: 'addr ${entry.$1}');
          expect(i.cke, 1);
          expect(i.resetN, 1);
          expect(i.payload, entry.$2, reason: 'addr ${entry.$1} MR payload');
          expect(i.a10, (entry.$2 >> 10) & 1, reason: 'addr ${entry.$1} A10');
        }
      },
    );

    test('addr 8 issues ZQ-calibration-long (A10 high)', () {
      final i = Ddr3Instruction(mr.romWord(8));
      expect(i.cmd, Ddr3Cmd.zqc);
      expect(i.a10, 1);
      expect(i.payload, t.tZqInit);
    });

    test('addr 20 is the refresh command with tRFC', () {
      final i = Ddr3Instruction(mr.romWord(20));
      expect(i.cmd, Ddr3Cmd.ref);
      expect(i.payload, t.nsToCycles(t.tRfc));
    });

    test('addr 21 marks RST_DONE and starts the refresh interval', () {
      final i = Ddr3Instruction(mr.romWord(21));
      expect(i.rstDone, 1);
      expect(i.cmd, Ddr3Cmd.nop);
      expect(i.payload, t.nsToCycles(DdrTiming.tRefiNs.toDouble()));
    });

    test('the ROM has 23 entries and default is an idle NOP', () {
      expect(mr.rom.length, 23);
      final def = Ddr3Instruction(mr.romWord(31));
      expect(def.cmd, Ddr3Cmd.nop);
      expect(def.cke, 1);
      expect(def.resetN, 1);
      expect(def.useTimer, 0);
      expect(def.rstDone, 0);
    });

    test('micronSim shortens the two long power-up resets 500x', () {
      final sim = Ddr3ModeRegisters(t, micronSim: true);
      expect(
        Ddr3Instruction(sim.romWord(0)).payload,
        t.nsToCycles(200000 / 500),
      );
      expect(
        Ddr3Instruction(sim.romWord(1)).payload,
        t.nsToCycles(500000 / 500),
      );
    });
  });
}
