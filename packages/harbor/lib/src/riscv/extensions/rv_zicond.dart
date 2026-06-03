import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

RiscVOperation _czero(String m, int f3, RiscVAluFunct f) => RiscVOperation(
  mnemonic: m,
  opcode: RiscvOpcode.op,
  funct3: f3,
  funct7: 0x07,
  format: rType,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rs2),
    RfResource(_int, rd),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVAlu(f, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Zicond - Conditional zero instructions.
/// czero.eqz rd = (rs2 == 0) ? 0 : rs1 ; czero.nez rd = (rs2 != 0) ? 0 : rs1.
final rvZicond = RiscVExtension(
  name: 'Zicond',
  key: null,
  misaBit: null,
  operations: [
    _czero('czero.eqz', 0x5, RiscVAluFunct.czeroEqz),
    _czero('czero.nez', 0x7, RiscVAluFunct.czeroNez),
  ],
);
