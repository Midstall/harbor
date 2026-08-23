import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('rvPriv extension', () {
    test('has correct name', () {
      expect(rvPriv.name, equals('Priv'));
    });

    test('has no misa key or bit', () {
      expect(rvPriv.key, isNull);
      expect(rvPriv.misaBit, isNull);
    });

    test('has 4 operations', () {
      expect(rvPriv.operations, hasLength(4));
    });

    test('sret uses system opcode with funct7 0x08', () {
      final sret = rvPriv.operations.firstWhere((op) => op.mnemonic == 'sret');
      expect(sret.opcode, equals(RiscvOpcode.system));
      expect(sret.funct7, equals(0x08));
      expect(sret.privilegeLevel, equals(1));
    });

    test('sret microcode is a single RiscVReturnOp with level 1', () {
      final sret = rvPriv.operations.firstWhere((op) => op.mnemonic == 'sret');
      expect(sret.microcode, hasLength(1));
      expect(sret.microcode.first, isA<RiscVReturnOp>());
      expect((sret.microcode.first as RiscVReturnOp).privilegeLevel, equals(1));
    });

    test('mret uses system opcode with funct7 0x18', () {
      final mret = rvPriv.operations.firstWhere((op) => op.mnemonic == 'mret');
      expect(mret.opcode, equals(RiscvOpcode.system));
      expect(mret.funct7, equals(0x18));
      expect(mret.privilegeLevel, equals(3));
    });

    test('mret microcode is a single RiscVReturnOp with level 3', () {
      final mret = rvPriv.operations.firstWhere((op) => op.mnemonic == 'mret');
      expect(mret.microcode, hasLength(1));
      expect(mret.microcode.first, isA<RiscVReturnOp>());
      expect((mret.microcode.first as RiscVReturnOp).privilegeLevel, equals(3));
    });

    test('wfi uses system opcode with funct7 0x08 and funct3 0', () {
      final wfi = rvPriv.operations.firstWhere((op) => op.mnemonic == 'wfi');
      expect(wfi.opcode, equals(RiscvOpcode.system));
      expect(wfi.funct7, equals(0x08));
      expect(wfi.funct3, equals(0));
    });

    test('wfi microcode waits then advances pc+4 (NOP-hint retire)', () {
      final wfi = rvPriv.operations.firstWhere((op) => op.mnemonic == 'wfi');
      expect(wfi.microcode, hasLength(2));
      expect(wfi.microcode.first, isA<RiscVWaitForInterrupt>());
      final upd = wfi.microcode[1];
      expect(upd, isA<RiscVUpdatePc>());
      expect((upd as RiscVUpdatePc).offset, equals(4));
    });

    test('sfence.vma uses system opcode with funct7 0x09', () {
      final s = rvPriv.operations.firstWhere(
        (op) => op.mnemonic == 'sfence.vma',
      );
      expect(s.opcode, equals(RiscvOpcode.system));
      expect(s.funct7, equals(0x09));
      expect(s.privilegeLevel, equals(1));
    });

    test('sfence.vma microcode fences the TLB then advances pc+4', () {
      final s = rvPriv.operations.firstWhere(
        (op) => op.mnemonic == 'sfence.vma',
      );
      expect(s.microcode, hasLength(2));
      expect(s.microcode.first, isA<RiscVTlbFenceOp>());
      final upd = s.microcode[1];
      expect(upd, isA<RiscVUpdatePc>());
      expect((upd as RiscVUpdatePc).offset, equals(4));
    });

    test('all operations use rType format', () {
      for (final op in rvPriv.operations) {
        expect(
          op.format,
          equals(rType),
          reason: '${op.mnemonic} should be rType',
        );
      }
    });
  });
}
