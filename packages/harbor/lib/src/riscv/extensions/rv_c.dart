import '../../encoding/riscv_compressed.dart';
import '../../encoding/rvc_immediate.dart';
import '../extension.dart';
import '../mxlen.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

/// C extension: Compressed instructions.
///
/// Compressed instructions are 16-bit encodings that expand to
/// their 32-bit equivalents. The operations here describe the
/// compressed forms. The CPU's fetch stage detects and expands them.
const rvC = RiscVExtension(
  name: 'C',
  key: 'C',
  misaBit: 2,
  operations: [
    // Quadrant 0
    RiscVOperation(
      mnemonic: 'c.addi4spn',
      opcode: CompressedOp.c0,
      funct3: C0Funct3.cAddi4spn,
      format: ciwType,
      immKind: RvcImm.ciwAddi4spn,
      fixedRs1: 2, // base is sp (x2)
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lw',
      opcode: CompressedOp.c0,
      funct3: C0Funct3.cLw,
      format: clType,
      immKind: RvcImm.clwsw,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.word,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sw',
      opcode: CompressedOp.c0,
      funct3: C0Funct3.cSw,
      format: csType,
      immKind: RvcImm.clwsw,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.word,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // RV64 c.ld / c.sd: 64-bit load/store, base rs1' + scaled-by-8 offset.
    RiscVOperation(
      mnemonic: 'c.ld',
      opcode: CompressedOp.c0,
      funct3: C0Funct3.cLd,
      format: clType,
      immKind: RvcImm.cldsd,
      xlenConstraint: {RiscVMxlen.rv64},
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.dword,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sd',
      opcode: CompressedOp.c0,
      funct3: C0Funct3.cSd,
      format: csType,
      immKind: RvcImm.cldsd,
      xlenConstraint: {RiscVMxlen.rv64},
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.dword,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),

    // Quadrant 1
    // NOTE: c.nop is c.addi x0, 0 (writes to x0 are discarded), so the c.addi
    // op below subsumes it. A distinct c.nop would shadow c.addi entirely,
    // since both use opcode=c1/funct3=0 and findOperation matches on
    // opcode+funct3 (c.nop, defined first, would win for every c.addi).
    RiscVOperation(
      mnemonic: 'c.addi',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cAddi,
      format: ciType,
      immKind: RvcImm.ciAddi,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.li',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cLi,
      format: ciType,
      immKind: RvcImm.ciAddi,
      resources: [RfResource(_int, rd)],
      microcode: [
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // c.addi16sp shares c1/funct3=3 with c.lui. rd==2 selects addi16sp. It is
    // listed first so the rd==2 case resolves here, otherwise c.lui matches.
    RiscVOperation(
      mnemonic: 'c.addi16sp',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cAddi16sp,
      format: ciType,
      immKind: RvcImm.ciAddi16sp,
      matchMask: 0xF80, // rd field
      matchValue: 0x100, // rd == x2 (2 << 7)
      fixedRd: 2,
      fixedRs1: 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lui',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cLui,
      format: ciType,
      immKind: RvcImm.ciLui,
      resources: [RfResource(_int, rd)],
      microcode: [
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.j',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cJ,
      format: cjType,
      immKind: RvcImm.cj,
      resources: [PcResource()],
      microcode: [
        RiscVUpdatePc(RiscVMicroOpField.pc, offsetField: RiscVMicroOpField.imm),
      ],
    ),
    // c.jal is RV32-only (c1/funct3=1 is c.addiw on RV64), links to x1.
    RiscVOperation(
      mnemonic: 'c.jal',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cJal,
      format: cjType,
      immKind: RvcImm.cj,
      fixedRd: 1, // link to x1 (ra)
      xlenConstraint: {RiscVMxlen.rv32},
      resources: [RfResource(_int, rd), PcResource()],
      microcode: [
        RiscVWriteLinkRegister(RiscVMicroOpField.rd, pcOffset: 2),
        RiscVUpdatePc(RiscVMicroOpField.pc, offsetField: RiscVMicroOpField.imm),
      ],
    ),
    // RV64 reuses the c1/funct3=1 encoding for c.addiw: rd = sext32(rd + imm).
    RiscVOperation(
      mnemonic: 'c.addiw',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cAddiw,
      format: ciType,
      immKind: RvcImm.ciAddi,
      xlenConstraint: {RiscVMxlen.rv64},
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.addw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.beqz',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cBeqz,
      format: cbType,
      immKind: RvcImm.cb,
      resources: [RfResource(_int, rs1), PcResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVBranch(
          RiscVBranchCondition.eq,
          RiscVMicroOpSource.rs1,
          offsetField: RiscVMicroOpField.imm,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.bnez',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cBnez,
      format: cbType,
      immKind: RvcImm.cb,
      resources: [RfResource(_int, rs1), PcResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVBranch(
          RiscVBranchCondition.ne,
          RiscVMicroOpSource.rs1,
          offsetField: RiscVMicroOpField.imm,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),

    // c1/funct3=cMisc(4): CB-arith (bits[11:10]=00/01/10) and CA (bits[11:10]=11).
    // CB-arith: rd'=rs1'=bits[9:7] (caType rd_rs1_prime), immediate via immKind.
    RiscVOperation(
      mnemonic: 'c.srli',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      immKind: RvcImm.cbShamt,
      matchMask: 0xC00,
      matchValue: 0x000,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.srl,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.srai',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      immKind: RvcImm.cbShamt,
      matchMask: 0xC00,
      matchValue: 0x400,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sra,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.andi',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      immKind: RvcImm.cbAndi,
      matchMask: 0xC00,
      matchValue: 0x800,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.and_,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // CA register arithmetic: bit12=0, bits[11:10]=11, bits[6:5]=funct.
    RiscVOperation(
      mnemonic: 'c.sub',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x0C00,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.sub,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.xor',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x0C20,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.xor_,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.or',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x0C40,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.or_,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.and',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x0C60,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.and_,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // RV64 c.subw / c.addw: the bit12=1 variants of the CA register-register
    // group (funct6 100111). rd' = sext32(rd' -/+ rs2').
    RiscVOperation(
      mnemonic: 'c.subw',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x1C00,
      xlenConstraint: {RiscVMxlen.rv64},
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
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.addw',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1C60,
      matchValue: 0x1C20,
      xlenConstraint: {RiscVMxlen.rv64},
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
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),

    // Quadrant 2
    RiscVOperation(
      mnemonic: 'c.slli',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cSlli,
      format: ciType,
      immKind: RvcImm.ciShamt,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sll,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lwsp',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cLwsp,
      format: ciType,
      immKind: RvcImm.ciLwsp,
      fixedRs1: 2, // base is sp (x2)
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.word,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.swsp',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cSwsp,
      format: cssType,
      immKind: RvcImm.cssSwsp,
      fixedRs1: 2, // base is sp (x2)
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.word,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // RV64 c.ldsp / c.sdsp: 64-bit stack load/store (base sp), scaled-by-8.
    RiscVOperation(
      mnemonic: 'c.ldsp',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cLdsp,
      format: ciType,
      immKind: RvcImm.ciLdsp,
      fixedRs1: 2, // base is sp (x2)
      xlenConstraint: {RiscVMxlen.rv64},
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.dword,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sdsp',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cSdsp,
      format: cssType,
      immKind: RvcImm.cssSdsp,
      fixedRs1: 2, // base is sp (x2)
      xlenConstraint: {RiscVMxlen.rv64},
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.dword,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.mv',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cMv,
      format: crType,
      // c.mv: bit12=0 and rs2!=0 (rs2==0 with bit12=0 is c.jr).
      matchMask: 0x1000,
      matchValue: 0,
      nonZeroMask: 0x7C,
      resources: [RfResource(_int, rs2), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rs2),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.add',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cMv,
      format: crType,
      // c.add: bit12=1 and rs2!=0 (rs2==0 with bit12=1 is c.jalr/c.ebreak).
      matchMask: 0x1000,
      matchValue: 0x1000,
      nonZeroMask: 0x7C,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    // c2/funct3=cMv(4) with rs2==0: c.jr (bit12=0), c.jalr (bit12=1, rd!=0),
    // c.ebreak (bit12=1, rd==0).
    RiscVOperation(
      mnemonic: 'c.jr',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cMv,
      format: crType,
      matchMask: 0x1000,
      matchValue: 0,
      zeroMask: 0x7C, // rs2 == 0
      resources: [RfResource(_int, rs1), PcResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVUpdatePc(
          RiscVMicroOpField.pc,
          offsetSource: RiscVMicroOpSource.alu,
          absolute: true,
          align: true,
        ),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.jalr',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cMv,
      format: crType,
      matchMask: 0x1000,
      matchValue: 0x1000,
      zeroMask: 0x7C, // rs2 == 0
      nonZeroMask: 0xF80, // rd != 0
      fixedRd: 1, // link to x1 (ra)
      resources: [RfResource(_int, rs1), RfResource(_int, rd), PcResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteLinkRegister(RiscVMicroOpField.rd, pcOffset: 2),
        RiscVUpdatePc(
          RiscVMicroOpField.pc,
          offsetSource: RiscVMicroOpSource.alu,
          absolute: true,
          align: true,
        ),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.ebreak',
      opcode: CompressedOp.c2,
      funct3: C2Funct3.cMv,
      format: crType,
      matchMask: 0x1000,
      matchValue: 0x1000,
      zeroMask: 0xFFC, // rd == 0 and rs2 == 0
      microcode: [RiscVTrapOp(3)],
    ),
  ],
);
