import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _fp32 = RiscVFloatRegFile(32);
const _fp16 = RiscVFloatRegFile(16);

/// Zfhmin: Minimal half-precision floating-point support.
final rvZfhmin = RiscVExtension(
  name: 'Zfhmin',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'flh',
      opcode: 0x07,
      funct3: 0x1,
      format: iType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp16, rd),
        MemoryResource.load(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsh',
      opcode: 0x27,
      funct3: 0x1,
      format: sType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp16, rs2),
        MemoryResource.store(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.s.h',
      opcode: 0x53,
      funct7: 0x22,
      format: rType,
      resources: [RfResource(_fp16, rs1), RfResource(_fp32, rd), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.h.s',
      opcode: 0x53,
      funct7: 0x22,
      format: rType,
      resources: [RfResource(_fp32, rs1), RfResource(_fp16, rd), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);
