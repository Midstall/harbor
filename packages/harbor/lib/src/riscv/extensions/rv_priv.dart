import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

final rvPriv = RiscVExtension(
  name: 'Priv',
  key: null,
  misaBit: null,
  operations: [
    // sret (0x10200073) and wfi (0x10500073) share opcode=SYSTEM, funct3=0,
    // funct7=0x08 - they differ ONLY in rs2 (sret rs2=0b00010, wfi rs2=0b00101).
    // Without an rs2 discriminator the first-defined op (sret) shadowed wfi, so a
    // wfi in an OS idle loop decoded as a supervisor return -> crash. matchMask
    // pins bits[24:20] (rs2) so each matches its own encoding.
    RiscVOperation(
      mnemonic: 'sret',
      opcode: RiscvOpcode.system,
      funct7: 0x08,
      funct3: 0,
      format: rType,
      matchMask: 0x01F00000, // bits[24:20] = rs2
      matchValue: 0x00200000, // rs2 = 0b00010
      privilegeLevel: 1,
      microcode: [RiscVReturnOp(1)],
    ),
    RiscVOperation(
      mnemonic: 'mret',
      opcode: RiscvOpcode.system,
      funct7: 0x18,
      funct3: 0,
      format: rType,
      privilegeLevel: 3,
      microcode: [RiscVReturnOp(3)],
    ),
    RiscVOperation(
      mnemonic: 'wfi',
      opcode: RiscvOpcode.system,
      funct7: 0x08,
      funct3: 0,
      format: rType,
      matchMask: 0x01F00000, // bits[24:20] = rs2
      matchValue: 0x00500000, // rs2 = 0b00101
      // wfi is a hint: wait for interrupt, then RETIRE and advance to pc+4 (so an
      // interrupt taken while stalled resumes at the instruction after wfi, and
      // the core never wedges on it). The UpdatePc mirrors Zawrs wrs.nto/wrs.sto,
      // it was missing here, so wfi never advanced and stalled the dynamic
      // microcode interpreter (creek) forever.
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sfence.vma',
      opcode: RiscvOpcode.system,
      funct7: 0x09,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVTlbFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);
