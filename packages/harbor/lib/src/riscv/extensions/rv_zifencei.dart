import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';

/// Zifencei: Instruction-fetch fence.
const rvZifencei = RiscVExtension(
  name: 'Zifencei',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'fence.i',
      opcode: RiscvOpcode.fence,
      funct3: 0x1,
      format: iType,
      microcode: [
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);
