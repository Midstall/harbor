import 'bit_struct.dart';

/// RISC-V Compressed (C extension) instruction formats.
///
/// Compressed instructions are 16 bits wide. The opcode is in bits
/// bits 1:0 (not 6:0 like standard 32-bit instructions).
///
/// Compressed register fields (`rs1'`, `rs2'`, `rd'`) encode
/// registers x8-x15 in 3 bits. Use [compressedRegFull] to map
/// to the full 5-bit register index.

/// Compressed instruction opcode range: bits 1:0.
const compressedOpcodeRange = HarborBitRange(0, 1);

/// Maps a 3-bit compressed register index to the full register number.
///
/// Compressed registers map to x8-x15 (s0-s1, a0-a5).
int compressedRegFull(int creg) => creg + 8;

/// CR-type: compressed register.
///
/// `[funct4(15:12)][rd/rs1(11:7)][rs2(6:2)][op(1:0)]`
const crType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rs2': HarborBitRange(2, 6),
  'rd_rs1': HarborBitRange(7, 11),
  'funct4': HarborBitRange(12, 15),
});

/// CI-type: compressed immediate.
///
/// `[funct3(15:13)][imm(12)][rd/rs1(11:7)][imm(6:2)][op(1:0)]`
const ciType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'imm_lo': HarborBitRange(2, 6), // imm[4:0]
  'rd_rs1': HarborBitRange(7, 11),
  'imm_hi': HarborBitRange(12, 12), // imm[5]
  'funct3': HarborBitRange(13, 15),
});

/// Reconstructs the CI-type 6-bit immediate.
int ciTypeImm(Map<String, int> fields) =>
    (fields['imm_hi']! << 5) | fields['imm_lo']!;

/// CSS-type: compressed stack-relative store.
///
/// `[funct3(15:13)][imm(12:7)][rs2(6:2)][op(1:0)]`
const cssType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rs2': HarborBitRange(2, 6),
  'imm': HarborBitRange(7, 12),
  'funct3': HarborBitRange(13, 15),
});

/// CIW-type: compressed immediate wide.
///
/// `[funct3(15:13)][imm(12:5)][rd'(4:2)][op(1:0)]`
const ciwType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rd_prime': HarborBitRange(2, 4),
  'imm': HarborBitRange(5, 12),
  'funct3': HarborBitRange(13, 15),
});

/// CL-type: compressed load.
///
/// `[funct3(15:13)][imm(12:10)][rs1'(9:7)][imm(6:5)][rd'(4:2)][op(1:0)]`
const clType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rd_prime': HarborBitRange(2, 4),
  'imm_lo': HarborBitRange(5, 6),
  'rs1_prime': HarborBitRange(7, 9),
  'imm_hi': HarborBitRange(10, 12),
  'funct3': HarborBitRange(13, 15),
});

/// CS-type: compressed store.
///
/// `[funct3(15:13)][imm(12:10)][rs1'(9:7)][imm(6:5)][rs2'(4:2)][op(1:0)]`
const csType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rs2_prime': HarborBitRange(2, 4),
  'imm_lo': HarborBitRange(5, 6),
  'rs1_prime': HarborBitRange(7, 9),
  'imm_hi': HarborBitRange(10, 12),
  'funct3': HarborBitRange(13, 15),
});

/// CA-type: compressed arithmetic.
///
/// `[funct6(15:10)][rd'/rs1'(9:7)][funct2(6:5)][rs2'(4:2)][op(1:0)]`
const caType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'rs2_prime': HarborBitRange(2, 4),
  'funct2': HarborBitRange(5, 6),
  'rd_rs1_prime': HarborBitRange(7, 9),
  'funct6': HarborBitRange(10, 15),
});

/// CB-type: compressed branch.
///
/// `[funct3(15:13)][offset(12:10)][rs1'(9:7)][offset(6:2)][op(1:0)]`
const cbType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'offset_lo': HarborBitRange(2, 6),
  'rs1_prime': HarborBitRange(7, 9),
  'offset_hi': HarborBitRange(10, 12),
  'funct3': HarborBitRange(13, 15),
}, name: 'CBType');

/// CJ-type: compressed jump.
///
/// `[funct3(15:13)][jump_target(12:2)][op(1:0)]`
const cjType = HarborBitStruct({
  'op': HarborBitRange(0, 1),
  'jump_target': HarborBitRange(2, 12),
  'funct3': HarborBitRange(13, 15),
}, name: 'CJType');

/// Compressed instruction opcodes (bits 1:0).
///
/// Values 0, 1, 2 indicate compressed instructions.
/// Value 3 (0b11) indicates a 32-bit instruction.
abstract final class CompressedOp {
  /// Quadrant 0 (C0).
  static const c0 = 0x0;

  /// Quadrant 1 (C1).
  static const c1 = 0x1;

  /// Quadrant 2 (C2).
  static const c2 = 0x2;

  /// Not compressed - 32-bit instruction follows.
  static const notCompressed = 0x3;
}

/// Compressed funct3 values for quadrant 0.
abstract final class C0Funct3 {
  static const cAddi4spn = 0x0;
  static const cFld = 0x1;
  static const cLw = 0x2;
  static const cLd = 0x3; // RV64 only
  static const cFsd = 0x5;
  static const cSw = 0x6;
  static const cSd = 0x7; // RV64 only
}

/// Compressed funct3 values for quadrant 1.
abstract final class C1Funct3 {
  static const cNop = 0x0; // also C.ADDI
  static const cAddi = 0x0;
  static const cJal = 0x1; // RV32 only
  static const cAddiw = 0x1; // RV64 only
  static const cLi = 0x2;
  static const cAddi16sp = 0x3; // also C.LUI
  static const cLui = 0x3;
  static const cMisc = 0x4; // SRLI, SRAI, ANDI, SUB, XOR, OR, AND
  static const cJ = 0x5;
  static const cBeqz = 0x6;
  static const cBnez = 0x7;
}

/// Compressed funct3 values for quadrant 2.
abstract final class C2Funct3 {
  static const cSlli = 0x0;
  static const cFldsp = 0x1;
  static const cLwsp = 0x2;
  static const cLdsp = 0x3; // RV64 only
  static const cMv = 0x4; // also C.ADD, C.JR, C.JALR, C.EBREAK
  static const cFsdsp = 0x5;
  static const cSwsp = 0x6;
  static const cSdsp = 0x7; // RV64 only
}

/// Whether a 16-bit halfword is a compressed instruction.
///
/// Per spec, bits 1:0 != 0b11 indicates a 16-bit instruction.
bool isCompressedInstruction(int halfword) =>
    (halfword & 0x3) != CompressedOp.notCompressed;
