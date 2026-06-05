import '../../encoding/riscv_formats.dart';
import '../../encoding/riscv_compressed.dart';
import '../../encoding/rvc_immediate.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _fp32 = RiscVFloatRegFile(32);

// -- Zicntr: Base counters and timers --

/// Zicntr - Base counters and timers (cycle, time, instret CSRs).
const rvZicntr = RiscVExtension(name: 'Zicntr', key: null, misaBit: null);

// -- Zihpm: Hardware performance counters --

/// Zihpm - Hardware performance counters (hpmcounter3-31).
const rvZihpm = RiscVExtension(name: 'Zihpm', key: null, misaBit: null);

// -- Zihintpause: Pause hint --

/// Zihintpause - PAUSE hint instruction.
final rvZihintpause = RiscVExtension(
  name: 'Zihintpause',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'pause',
      opcode: RiscvOpcode.fence,
      funct3: 0x0,
      format: iType,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);

// -- Zihintntl: Non-temporal locality hints --

/// Zihintntl - Non-temporal locality hints (NTL.P1, NTL.PALL, NTL.S1, NTL.ALL).
final rvZihintntl = RiscVExtension(
  name: 'Zihintntl',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'ntl.p1',
      opcode: RiscvOpcode.op,
      funct3: 0x0,
      funct7: 0x00,
      format: rType,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'ntl.pall',
      opcode: RiscvOpcode.op,
      funct3: 0x0,
      funct7: 0x00,
      format: rType,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'ntl.s1',
      opcode: RiscvOpcode.op,
      funct3: 0x0,
      funct7: 0x00,
      format: rType,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'ntl.all',
      opcode: RiscvOpcode.op,
      funct3: 0x0,
      funct7: 0x00,
      format: rType,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);

// -- Zimop: May-be-operations --

/// Zimop - May-be-operations (reserved encoding space).
const rvZimop = RiscVExtension(name: 'Zimop', key: null, misaBit: null);

// -- Zcmop: Compressed may-be-operations --

/// Zcmop - Compressed may-be-operations.
const rvZcmop = RiscVExtension(name: 'Zcmop', key: null, misaBit: null);

// -- Zawrs: Wait-on-reservation-set --

/// Zawrs - Wait-on-reservation-set instructions.
final rvZawrs = RiscVExtension(
  name: 'Zawrs',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'wrs.nto',
      opcode: RiscvOpcode.system,
      funct7: 0x00,
      format: rType,
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'wrs.sto',
      opcode: RiscvOpcode.system,
      funct7: 0x00,
      format: rType,
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

// -- Zkt: Data-independent execution latency --

/// Zkt - Data-independent execution latency (constant-time crypto).
const rvZkt = RiscVExtension(name: 'Zkt', key: null, misaBit: null);

// -- Zvfhmin, Zvbb, Zvkt: Vector sub-extensions --

/// Zvfhmin - Vector minimal half-precision floating-point.
const rvZvfhmin = RiscVExtension(name: 'Zvfhmin', key: null, misaBit: null);

/// Zvfh - Vector half-precision floating-point (SEW=16 FP arithmetic). A marker
/// extension: the OP-FP-V ops (vfadd.vv etc.) are SEW-generic and decode the same
/// for any SEW, so the half-precision capability is signalled by including this
/// in the ISA config rather than by distinct operations.
const rvZvfh = RiscVExtension(name: 'Zvfh', key: null, misaBit: null);

/// Zvbb - Vector basic bit-manipulation instructions.
const rvZvbb = RiscVExtension(name: 'Zvbb', key: null, misaBit: null);

/// Zvkt - Vector data-independent execution latency.
const rvZvkt = RiscVExtension(name: 'Zvkt', key: null, misaBit: null);

// -- Zicbom/Zicbop/Zicboz: Cache block operations --

/// Zicbom - Cache-block management instructions.
final rvZicbom = RiscVExtension(
  name: 'Zicbom',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'cbo.clean',
      opcode: RiscvOpcode.fence,
      funct3: 0x2,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'cbo.flush',
      opcode: RiscvOpcode.fence,
      funct3: 0x2,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'cbo.inval',
      opcode: RiscvOpcode.fence,
      funct3: 0x2,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

/// Zicbop - Cache-block prefetch instructions.
final rvZicbop = RiscVExtension(
  name: 'Zicbop',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'prefetch.r',
      opcode: RiscvOpcode.opImm,
      funct3: 0x6,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'prefetch.w',
      opcode: RiscvOpcode.opImm,
      funct3: 0x6,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'prefetch.i',
      opcode: RiscvOpcode.opImm,
      funct3: 0x6,
      format: iType,
      resources: [RfResource(_int, rs1)],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);

/// Zicboz - Cache-block zero instructions.
final rvZicboz = RiscVExtension(
  name: 'Zicboz',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'cbo.zero',
      opcode: RiscvOpcode.fence,
      funct3: 0x2,
      format: iType,
      resources: [RfResource(_int, rs1), MemoryResource.store()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

// -- Zcb: Additional compressed instructions --

/// Zcb - Additional 16-bit compressed instructions.
final rvZcb = RiscVExtension(
  name: 'Zcb',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'c.lbu',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: 0x7 << 10, // inst[12:10] = 000
      immKind: RvcImm.clb,
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
          RiscVMemSize.byte1,
          unsigned: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lhu',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=001, inst[6]=0
      matchValue: 1 << 10,
      immKind: RvcImm.clh,
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
          RiscVMemSize.half,
          unsigned: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lh',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=001, inst[6]=1
      matchValue: (1 << 10) | (1 << 6),
      immKind: RvcImm.clh,
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
          RiscVMemSize.half,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sb',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: csType,
      matchMask: 0x7 << 10, // inst[12:10] = 010
      matchValue: 2 << 10,
      immKind: RvcImm.clb,
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
          RiscVMemSize.byte1,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sh',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: csType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=011, inst[6]=0
      matchValue: 3 << 10,
      immKind: RvcImm.clh,
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
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.b',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x18 << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zextb,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sext.b',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x19 << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sextb,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.h',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x1A << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zexth,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sext.h',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x1B << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sexth,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.w',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x1C << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zextw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.not',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: 0x1F << 2,
      matchValue: 0x1D << 2,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.notOp,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.mul',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      // funct2 = bits[6:5] = 0b10 distinguishes c.mul from the cMisc unary ops
      // (which all have bits[6:5] = 0b11). Without this matchMask c.mul matches
      // every cMisc op and shadows the unary extends in the decoder.
      matchMask: 0x3 << 5,
      matchValue: 0x2 << 5,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.mul,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
  ],
);

// -- Zfa: Additional floating-point instructions --

/// Zfa - Additional floating-point instructions.
final rvZfa = RiscVExtension(
  name: 'Zfa',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'fli.s',
      opcode: 0x53,
      funct7: 0x78,
      format: rType,
      resources: [RfResource(_fp32, rd), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fminm.s',
      opcode: 0x53,
      funct7: 0x14,
      funct3: 0x2,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
        FpuResource(),
      ],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fmaxm.s',
      opcode: 0x53,
      funct7: 0x14,
      funct3: 0x3,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
        FpuResource(),
      ],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fround.s',
      opcode: 0x53,
      funct7: 0x20,
      format: rType,
      resources: [RfResource(_fp32, rs1), RfResource(_fp32, rd), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'froundnx.s',
      opcode: 0x53,
      funct7: 0x20,
      format: rType,
      resources: [RfResource(_fp32, rs1), RfResource(_fp32, rd), FpuResource()],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fleq.s',
      opcode: 0x53,
      funct7: 0x50,
      funct3: 0x4,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_int, rd),
        FpuResource(),
      ],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
    RiscVOperation(
      mnemonic: 'fltq.s',
      opcode: 0x53,
      funct7: 0x50,
      funct3: 0x5,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_int, rd),
        FpuResource(),
      ],
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
    ),
  ],
);

// -- Svinval: Fine-grained TLB invalidation --

/// Svinval - Fine-grained address-translation cache invalidation.
final rvSvinval = RiscVExtension(
  name: 'Svinval',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'sinval.vma',
      opcode: RiscvOpcode.system,
      funct7: 0x0B,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVTlbInvalidateOp(RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sfence.w.inval',
      opcode: RiscvOpcode.system,
      funct7: 0x0C,
      format: rType,
      privilegeLevel: 1,
      microcode: [
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sfence.inval.ir',
      opcode: RiscvOpcode.system,
      funct7: 0x0C,
      format: rType,
      privilegeLevel: 1,
      microcode: [
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hinval.vvma',
      opcode: RiscvOpcode.system,
      funct7: 0x13,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVHypervisorFenceOp(isGstage: false),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'hinval.gvma',
      opcode: RiscvOpcode.system,
      funct7: 0x33,
      format: rType,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVHypervisorFenceOp(isGstage: true),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

// -- Config-only extensions --

/// Svnapot - NAPOT translation contiguity.
const rvSvnapot = RiscVExtension(name: 'Svnapot', key: null, misaBit: null);

/// Svpbmt - Page-based memory types.
const rvSvpbmt = RiscVExtension(name: 'Svpbmt', key: null, misaBit: null);

/// Sstc - Supervisor-mode timer interrupts (stimecmp CSR).
const rvSstc = RiscVExtension(name: 'Sstc', key: null, misaBit: null);

/// Sscofpmf - Count overflow and mode-based filtering.
const rvSscofpmf = RiscVExtension(name: 'Sscofpmf', key: null, misaBit: null);

/// Svbare - Bare satp mode support.
const rvSvbare = RiscVExtension(name: 'Svbare', key: null, misaBit: null);

/// Svade - A/D bit page-fault exceptions.
const rvSvade = RiscVExtension(name: 'Svade', key: null, misaBit: null);

/// Svadu - hardware updating of page-table A/D bits (the alternative to Svade,
/// which faults instead). The MMU sets Accessed/Dirty during a successful walk.
const rvSvadu = RiscVExtension(name: 'Svadu', key: null, misaBit: null);

/// Smstateen - machine-level state-enable CSRs (mstateen0-3[h]) gating access to
/// extension state from lower privilege levels.
const rvSmstateen = RiscVExtension(name: 'Smstateen', key: null, misaBit: null);

/// Ssstateen - the supervisor-visible view of the state-enable CSRs
/// (sstateen0-3); requires [rvSmstateen].
const rvSsstateen = RiscVExtension(name: 'Ssstateen', key: null, misaBit: null);

/// Ziccif - Instruction fetch atomicity in coherent cacheable regions.
const rvZiccif = RiscVExtension(name: 'Ziccif', key: null, misaBit: null);

/// Ziccrse - RsrvEventual in coherent cacheable regions.
const rvZiccrse = RiscVExtension(name: 'Ziccrse', key: null, misaBit: null);

/// Ziccamoa - AMOArithmetic in coherent cacheable regions.
const rvZiccamoa = RiscVExtension(name: 'Ziccamoa', key: null, misaBit: null);

/// Zicclsm - Misaligned loads/stores in coherent cacheable regions.
const rvZicclsm = RiscVExtension(name: 'Zicclsm', key: null, misaBit: null);

/// Za64rs - Reservation sets contiguous, aligned, max 64 bytes.
const rvZa64rs = RiscVExtension(name: 'Za64rs', key: null, misaBit: null);

/// Zic64b - Cache blocks 64 bytes, naturally aligned.
const rvZic64b = RiscVExtension(name: 'Zic64b', key: null, misaBit: null);

/// Supm - User-mode pointer masking.
const rvSupm = RiscVExtension(name: 'Supm', key: null, misaBit: null);

/// Sha - Augmented hypervisor extension.
const rvSha = RiscVExtension(name: 'Sha', key: null, misaBit: null);
