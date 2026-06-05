import '../../encoding/riscv_formats.dart';
import '../../encoding/riscv_hypervisor.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

/// H extension - Hypervisor.
///
/// Adds hypervisor fence and virtual load/store instructions.
/// All require hypervisor privilege level.
const rvH = RiscVExtension(
  name: 'H',
  key: 'H',
  misaBit: 7,
  operations: [
    // Hypervisor fences
    RiscVOperation(
      mnemonic: 'hfence.vvma',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hfenceVvma,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVHypervisorFenceOp(isGstage: false),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hfence.gvma',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hfenceGvma,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVHypervisorFenceOp(isGstage: true),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),

    // Hypervisor virtual loads
    RiscVOperation(
      mnemonic: 'hlv.b',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hlvB,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.byte1,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hlv.h',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hlvH,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hlv.w',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hlvW,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rd),
        MemoryResource.load(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.word,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),

    // Hypervisor virtual stores
    RiscVOperation(
      mnemonic: 'hsv.b',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hsvB,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.byte1,
          isStore: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hsv.h',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hsvH,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.half,
          isStore: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hsv.w',
      opcode: RiscvOpcode.system,
      funct7: HypervisorFunct7.hsvW,
      format: rType,
      privilegeLevel: 1,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVHypervisorMemOp(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.word,
          isStore: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),

    // Privilege instructions
    // sret/wfi share funct7=0x08; disambiguate on rs2 (bits[24:20]) - see the
    // matching fix in rv_priv.dart. Without it wfi decoded as sret.
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
      privilegeLevel: 1,
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
