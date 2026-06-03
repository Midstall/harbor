import 'package:harbor/src/encoding/rvc_immediate.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('decodeRvcImm (software)', () {
    // Hand-verified encodings against the RISC-V spec.
    test('c.j bfcd -> -14', () {
      expect(decodeRvcImm(RvcImm.cj, 0xbfcd), -14);
    });
    test('c.addi x10,1 (0x0285) -> 1', () {
      expect(decodeRvcImm(RvcImm.ciAddi, 0x0285), 1);
    });
    test('c.addi x10,-1 (0x157d) -> -1', () {
      expect(decodeRvcImm(RvcImm.ciAddi, 0x157d), -1);
    });
    test('c.lui x10,1 (0x6285) -> 0x1000', () {
      expect(decodeRvcImm(RvcImm.ciLui, 0x6285), 0x1000);
    });
    test('c.lw off=4 (0x4040) -> 4', () {
      expect(decodeRvcImm(RvcImm.clwsw, 0x4040), 4);
    });
    test('c.beqz off=4 (0xc011) -> 4', () {
      expect(decodeRvcImm(RvcImm.cb, 0xc011), 4);
    });
    test('c.slli shamt zero-extended (no sign)', () {
      // shamt=31: i12=0, i6:2=11111 -> 31, NOT sign-extended.
      expect(decodeRvcImm(RvcImm.ciShamt, (31 << 2)), 31);
    });
  });

  group('rvcImmLogic (hardware) matches software', () {
    Future<int> hw(RvcImm kind, int inst) async {
      final instr = Logic(width: 32)..put(inst);
      final out = rvcImmLogic(kind, instr, 32);
      return out.value.toInt();
    }

    final cases = <(RvcImm, int)>[
      (RvcImm.cj, 0xbfcd),
      (RvcImm.ciAddi, 0x0285),
      (RvcImm.ciAddi, 0x157d),
      (RvcImm.ciLui, 0x6285),
      (RvcImm.clwsw, 0x4040),
      (RvcImm.cb, 0xc011),
      (RvcImm.ciShamt, 31 << 2),
    ];

    for (final (kind, inst) in cases) {
      test('$kind 0x${inst.toRadixString(16)} hw==sw', () async {
        final sw = decodeRvcImm(kind, inst);
        final hwv = await hw(kind, inst);
        // Compare as 32-bit two's complement.
        expect(hwv & 0xFFFFFFFF, sw & 0xFFFFFFFF);
      });
    }
  });
}
