import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

RiscVOperation _mulDiv(
  String mnemonic,
  int funct3,
  RiscVAluFunct funct, {
  Set<RiscVMxlen>? xlen,
  int opcode = RiscvOpcode.op,
  int funct7 = 0x01,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: opcode,
  funct3: funct3,
  funct7: funct7,
  format: rType,
  xlenConstraint: xlen,
  executionMode: RiscVExecutionMode.microcoded,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rs2),
    RfResource(_int, rd),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVAlu(funct, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// RV32M + RV64M: Multiply/Divide extension.
final rvM = RiscVExtension(
  name: 'M',
  key: 'M',
  misaBit: 12,
  operations: [
    // RV32M
    _mulDiv('mul', 0x0, RiscVAluFunct.mul),
    _mulDiv('mulh', 0x1, RiscVAluFunct.mulh),
    _mulDiv('mulhsu', 0x2, RiscVAluFunct.mulhsu),
    _mulDiv('mulhu', 0x3, RiscVAluFunct.mulhu),
    _mulDiv('div', 0x4, RiscVAluFunct.div),
    _mulDiv('divu', 0x5, RiscVAluFunct.divu),
    _mulDiv('rem', 0x6, RiscVAluFunct.rem),
    _mulDiv('remu', 0x7, RiscVAluFunct.remu),
    // RV64M
    _mulDiv(
      'mulw',
      0x0,
      RiscVAluFunct.mulw,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      opcode: RiscvOpcode.op32,
    ),
    _mulDiv(
      'divw',
      0x4,
      RiscVAluFunct.divw,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      opcode: RiscvOpcode.op32,
    ),
    _mulDiv(
      'divuw',
      0x5,
      RiscVAluFunct.divuw,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      opcode: RiscvOpcode.op32,
    ),
    _mulDiv(
      'remw',
      0x6,
      RiscVAluFunct.remw,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      opcode: RiscvOpcode.op32,
    ),
    _mulDiv(
      'remuw',
      0x7,
      RiscVAluFunct.remuw,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      opcode: RiscvOpcode.op32,
    ),
  ],
);
