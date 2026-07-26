import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(64);
const _rv64 = {RiscVMxlen.rv64, RiscVMxlen.rv128};

/// RV64I additional instructions (word-width ops for 64-bit mode).
final rv64i = RiscVExtension(
  name: 'RV64I',
  key: 'I',
  misaBit: 8,
  operations: [
    // Loads
    RiscVOperation(
      mnemonic: 'lwu',
      opcode: RiscvOpcode.load,
      funct3: LoadFunct3.lwu,
      format: iType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.word,
          unsigned: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'ld',
      opcode: RiscvOpcode.load,
      funct3: LoadFunct3.ld,
      format: iType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.dword,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // Store
    RiscVOperation(
      mnemonic: 'sd',
      opcode: RiscvOpcode.store,
      funct3: StoreFunct3.sd,
      format: sType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.dword,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // ALU word ops
    RiscVOperation(
      mnemonic: 'addiw',
      opcode: RiscvOpcode.opImm32,
      funct3: 0x0,
      format: iType,
      xlenConstraint: _rv64,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.addw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'addw',
      opcode: RiscvOpcode.op32,
      funct3: 0x0,
      funct7: 0x00,
      format: rType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.addw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'subw',
      opcode: RiscvOpcode.op32,
      funct3: 0x0,
      funct7: 0x20,
      format: rType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.subw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // RV64 doubleword shift-immediates (slli/srli/srai) use a 6-bit shamt with
    // funct6 (bits[31:26]), NOT the RV32 funct7/5-bit form. Match on funct6 via
    // matchMask so shamt 32..63 (bit 25 set) decodes instead of faulting as an
    // illegal instruction. The RV32 versions in rv32i.dart key on funct7 and so
    // reject bit 25. Without these a real RV64 toolchain (e.g. LLVM building the
    // Weir BIOS) faults on every 64-bit shift >= 32. matchValue selects the op:
    // slli/srli funct6=000000 (0), srai funct6=010000 (0x40000000).
    RiscVOperation(
      mnemonic: 'slli',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.slli,
      format: iType,
      xlenConstraint: _rv64,
      matchMask: 0xFC000000,
      matchValue: 0x00000000,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sll,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srli',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.srli,
      format: iType,
      xlenConstraint: _rv64,
      matchMask: 0xFC000000,
      matchValue: 0x00000000,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.srl,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srai',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.srli,
      format: iType,
      xlenConstraint: _rv64,
      matchMask: 0xFC000000,
      matchValue: 0x40000000,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sra,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'slliw',
      opcode: RiscvOpcode.opImm32,
      funct3: 0x1,
      funct7: 0x00,
      format: iType,
      xlenConstraint: _rv64,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sllw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srliw',
      opcode: RiscvOpcode.opImm32,
      funct3: 0x5,
      funct7: 0x00,
      format: iType,
      xlenConstraint: _rv64,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.srlw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sraiw',
      opcode: RiscvOpcode.opImm32,
      funct3: 0x5,
      funct7: 0x20,
      format: iType,
      xlenConstraint: _rv64,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sraw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sllw',
      opcode: RiscvOpcode.op32,
      funct3: 0x1,
      funct7: 0x00,
      format: rType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.sllw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srlw',
      opcode: RiscvOpcode.op32,
      funct3: 0x5,
      funct7: 0x00,
      format: rType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.srlw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sraw',
      opcode: RiscvOpcode.op32,
      funct3: 0x5,
      funct7: 0x20,
      format: rType,
      xlenConstraint: _rv64,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.sraw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);
