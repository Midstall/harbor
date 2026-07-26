import 'bit_struct.dart';

/// RISC-V Vector (V) extension instruction formats and constants.
///
/// Per the RISC-V V extension specification v1.0.

/// Vector opcode: all vector instructions use this major opcode.
const vectorOpcode = 0x57; // OP-V

/// Vector load opcode.
const vectorLoadOpcode = 0x07; // LOAD-FP

/// Vector store opcode.
const vectorStoreOpcode = 0x27; // STORE-FP

/// Vector arithmetic instruction format (OPIVV, OPIVX, OPIVI, OPMVV, OPMVX, OPFVV, OPFVF).
///
/// `[funct6(31:26)][vm(25)][vs2(24:20)][vs1/rs1/imm(19:15)][funct3(14:12)][vd/rd(11:7)][opcode(6:0)]`
const vArithType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'vd': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14),
  'vs1': HarborBitRange(15, 19), // also rs1 or imm5 depending on funct3
  'vs2': HarborBitRange(20, 24),
  'vm': HarborBitRange(25, 25), // 0 = masked, 1 = unmasked
  'funct6': HarborBitRange(26, 31),
});

/// Vector load/store instruction format.
///
/// `[nf(31:29)][mew(28)][mop(27:26)][vm(25)][vs2/rs2(24:20)][rs1(19:15)][width(14:12)][vd/vs3(11:7)][opcode(6:0)]`
const vLoadStoreType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'vd_vs3': HarborBitRange(7, 11),
  'width': HarborBitRange(12, 14),
  'rs1': HarborBitRange(15, 19),
  'vs2_rs2': HarborBitRange(20, 24),
  'vm': HarborBitRange(25, 25),
  'mop': HarborBitRange(26, 27),
  'mew': HarborBitRange(28, 28),
  'nf': HarborBitRange(29, 31),
});

/// Vector configuration instruction (vsetvli, vsetivli, vsetvl).
///
/// vsetvli: `[0(31)][zimm(30:20)][rs1(19:15)][111(14:12)][rd(11:7)][1010111(6:0)]`
/// vsetivli: `[11(31:30)][zimm(29:20)][uimm(19:15)][111(14:12)][rd(11:7)][1010111(6:0)]`
/// vsetvl: `[1000000(31:25)][rs2(24:20)][rs1(19:15)][111(14:12)][rd(11:7)][1010111(6:0)]`
const vsetType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14),
  'rs1_uimm': HarborBitRange(15, 19),
  'zimm_rs2': HarborBitRange(20, 30),
  'sel': HarborBitRange(31, 31), // 0=vsetvli, 1=vsetvl/vsetivli
});

/// Vector funct3 encodings (determines operand type).
abstract final class VectorFunct3 {
  /// OPIVV: vector-vector integer.
  static const opivv = 0x0;

  /// OPFVV: vector-vector floating-point.
  static const opfvv = 0x1;

  /// OPMVV: vector-vector mask/reduction.
  static const opmvv = 0x2;

  /// OPIVI: vector-immediate integer.
  static const opivi = 0x3;

  /// OPIVX: vector-scalar integer.
  static const opivx = 0x4;

  /// OPFVF: vector-scalar floating-point.
  static const opfvf = 0x5;

  /// OPMVX: vector-scalar mask.
  static const opmvx = 0x6;

  /// OPCFG: vector configuration (vsetvli, etc.).
  static const opcfg = 0x7;
}

/// Vector funct6 encodings for common operations.
abstract final class VectorFunct6 {
  static const vadd = 0x00;
  static const vsub = 0x02;
  static const vand = 0x09;
  static const vor = 0x0A;
  static const vxor = 0x0B;
  static const vmseq = 0x18;
  static const vmsne = 0x19;
  static const vmsltu = 0x1A;
  static const vmslt = 0x1B;
  static const vmsleu = 0x1C;
  static const vmsle = 0x1D;
  static const vsll = 0x25;
  static const vsrl = 0x28;
  static const vsra = 0x29;
  static const vmul = 0x25; // OPMVV
  static const vdiv = 0x21; // OPMVV
  static const vmerge = 0x17;
  static const vmv = 0x17; // same as vmerge when vm=1
}

/// Vector memory width (EEW) encodings for load/store.
abstract final class VectorWidth {
  /// 8-bit element.
  static const e8 = 0x0;

  /// 16-bit element.
  static const e16 = 0x5;

  /// 32-bit element.
  static const e32 = 0x6;

  /// 64-bit element.
  static const e64 = 0x7;
}

/// Vector load/store addressing modes (mop field).
abstract final class VectorMop {
  /// Unit-stride.
  static const unitStride = 0x0;

  /// Indexed (unordered).
  static const indexedUnordered = 0x1;

  /// Strided.
  static const strided = 0x2;

  /// Indexed (ordered).
  static const indexedOrdered = 0x3;
}

/// vtype field layout for vsetvli/vsetivli.
///
/// `[vma(7)][vta(6)][vsew(5:3)][vlmul(2:0)]`
const vtypeStruct = HarborBitStruct({
  'vlmul': HarborBitRange(0, 2),
  'vsew': HarborBitRange(3, 5),
  'vta': HarborBitRange(6, 6), // tail agnostic
  'vma': HarborBitRange(7, 7), // mask agnostic
});

/// VSEW (vector selected element width) values.
abstract final class Vsew {
  static const e8 = 0x0;
  static const e16 = 0x1;
  static const e32 = 0x2;
  static const e64 = 0x3;
}

/// VLMUL (vector register group multiplier) values.
abstract final class Vlmul {
  static const m1 = 0x0; // LMUL=1
  static const m2 = 0x1; // LMUL=2
  static const m4 = 0x2; // LMUL=4
  static const m8 = 0x3; // LMUL=8
  static const mf8 = 0x5; // LMUL=1/8
  static const mf4 = 0x6; // LMUL=1/4
  static const mf2 = 0x7; // LMUL=1/2
}

/// Vector CSR addresses.
abstract final class VectorCsr {
  static const vstart = 0x008;
  static const vxsat = 0x009;
  static const vxrm = 0x00A;
  static const vcsr = 0x00F;
  static const vl = 0xC20;
  static const vtype = 0xC21;
  static const vlenb = 0xC22;
}
