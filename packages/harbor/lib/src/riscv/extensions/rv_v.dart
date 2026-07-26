import '../../encoding/riscv_vector.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

/// V extension: Vector operations.
///
/// Core vector arithmetic and memory operations. The vector unit
/// is parameterized by VLEN (vector register width) at elaboration
/// time. Operations here define encoding and resource usage,
/// the actual vector execution logic is CPU-specific.
const rvV = RiscVExtension(
  name: 'V',
  key: 'V',
  misaBit: 21,
  operations: [
    // Vector configuration
    RiscVOperation(
      mnemonic: 'vsetvli',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opcfg,
      format: vsetType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsetvl',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opcfg,
      funct7: 0x40,
      format: vsetType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VV)
    RiscVOperation(
      mnemonic: 'vadd.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsub.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vand.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vor.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vxor.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivv,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VX: vector-scalar)
    RiscVOperation(
      mnemonic: 'vadd.vx',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivx,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vsub.vx',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivx,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Integer arithmetic (VI: vector-immediate)
    RiscVOperation(
      mnemonic: 'vadd.vi',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opivi,
      format: vArithType,
      resources: [VectorResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Vector loads
    RiscVOperation(
      mnemonic: 'vle8.v',
      opcode: vectorLoadOpcode,
      funct3: 0x0,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle16.v',
      opcode: vectorLoadOpcode,
      funct3: 0x5,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle32.v',
      opcode: vectorLoadOpcode,
      funct3: 0x6,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vle64.v',
      opcode: vectorLoadOpcode,
      funct3: 0x7,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.load()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // Vector stores
    RiscVOperation(
      mnemonic: 'vse8.v',
      opcode: vectorStoreOpcode,
      funct3: 0x0,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse16.v',
      opcode: vectorStoreOpcode,
      funct3: 0x5,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse32.v',
      opcode: vectorStoreOpcode,
      funct3: 0x6,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vse64.v',
      opcode: vectorStoreOpcode,
      funct3: 0x7,
      format: vLoadStoreType,
      resources: [VectorResource(), MemoryResource.store()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),

    // FP vector (VV)
    RiscVOperation(
      mnemonic: 'vfadd.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opfvv,
      format: vArithType,
      resources: [VectorResource(), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'vfmul.vv',
      opcode: vectorOpcode,
      funct3: VectorFunct3.opfvv,
      format: vArithType,
      resources: [VectorResource(), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);
