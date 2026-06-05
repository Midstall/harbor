import 'bit_struct.dart';

/// Standard RISC-V instruction formats per the ISA manual.
///
/// Each format is a [HarborBitStruct] mapping field names to bit positions
/// within a 32-bit instruction word.

/// R-type: register-register operations.
///
/// `[funct7(31:25)][rs2(24:20)][rs1(19:15)][funct3(14:12)][rd(11:7)][opcode(6:0)]`
const rType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14),
  'rs1': HarborBitRange(15, 19),
  'rs2': HarborBitRange(20, 24),
  'funct7': HarborBitRange(25, 31),
}, name: 'RType');

/// R4-type: fused multiply-add (fmadd/fmsub/fnmsub/fnmadd). Three FP source
/// registers plus a 2-bit fmt selecting precision.
///
/// `[rs3(31:27)][fmt(26:25)][rs2(24:20)][rs1(19:15)][rm(14:12)][rd(11:7)][opcode(6:0)]`
const r4Type = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14), // rm (rounding mode)
  'rs1': HarborBitRange(15, 19),
  'rs2': HarborBitRange(20, 24),
  'funct2': HarborBitRange(25, 26), // fmt: 00=s, 01=d
  'rs3': HarborBitRange(27, 31),
}, name: 'R4Type');

/// I-type: immediate operations, loads, JALR.
///
/// `[imm(31:20)][rs1(19:15)][funct3(14:12)][rd(11:7)][opcode(6:0)]`
const iType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14),
  'rs1': HarborBitRange(15, 19),
  'imm': HarborBitRange(20, 31),
}, name: 'IType');

/// S-type: stores.
///
/// `[imm(31:25)][rs2(24:20)][rs1(19:15)][funct3(14:12)][imm(11:7)][opcode(6:0)]`
///
/// Note: the immediate is split across two fields. Use [sTypeImm]
/// to reconstruct the full immediate from decoded fields.
const sType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'immLo': HarborBitRange(7, 11),
  'funct3': HarborBitRange(12, 14),
  'rs1': HarborBitRange(15, 19),
  'rs2': HarborBitRange(20, 24),
  'immHi': HarborBitRange(25, 31),
}, name: 'SType');

/// Reconstructs the S-type immediate from its split fields.
int sTypeImm(Map<String, int> fields) =>
    (fields['immHi']! << 5) | fields['immLo']!;

/// B-type: branches.
///
/// `[imm(12|10:5)][rs2(24:20)][rs1(19:15)][funct3(14:12)][imm(4:1|11)][opcode(6:0)]`
///
/// Note: the immediate is scattered. Use [bTypeImm] to reconstruct.
const bType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'immLo': HarborBitRange(7, 11), // [11|4:1]
  'funct3': HarborBitRange(12, 14),
  'rs1': HarborBitRange(15, 19),
  'rs2': HarborBitRange(20, 24),
  'immHi': HarborBitRange(25, 31), // [12|10:5]
}, name: 'BType');

/// Reconstructs the B-type immediate from its split fields.
///
/// Bit mapping: `{12, 10:5, 4:1, 11}` → signed 13-bit offset.
int bTypeImm(Map<String, int> fields) {
  final lo = fields['immLo']!; // [11, 4:1]
  final hi = fields['immHi']!; // [12, 10:5]
  return ((hi >> 6) << 12) | // bit 12
      ((lo & 1) << 11) | // bit 11
      (((hi & 0x3F)) << 5) | // bits 10:5
      ((lo >> 1) << 1); // bits 4:1 (bit 0 always 0)
}

/// U-type: upper immediate (LUI, AUIPC).
///
/// `[imm(31:12)][rd(11:7)][opcode(6:0)]`
const uType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'imm': HarborBitRange(12, 31),
}, name: 'UType');

/// J-type: jumps (JAL).
///
/// `[imm(20|10:1|11|19:12)][rd(11:7)][opcode(6:0)]`
///
/// Note: the immediate is scattered. Use [jTypeImm] to reconstruct.
const jType = HarborBitStruct({
  'opcode': HarborBitRange(0, 6),
  'rd': HarborBitRange(7, 11),
  'imm': HarborBitRange(12, 31), // [20, 10:1, 11, 19:12]
}, name: 'JType');

/// Reconstructs the J-type immediate from the raw 20-bit field.
///
/// Bit mapping: `{20, 10:1, 11, 19:12}` → signed 21-bit offset.
int jTypeImm(int rawImm) {
  return ((rawImm >> 19) << 20) | // bit 20
      ((rawImm & 0xFF) << 12) | // bits 19:12
      (((rawImm >> 8) & 1) << 11) | // bit 11
      (((rawImm >> 9) & 0x3FF) << 1); // bits 10:1 (bit 0 always 0)
}

/// Standard RISC-V opcode values.
abstract final class RiscvOpcode {
  static const lui = 0x37;
  static const auipc = 0x17;
  static const jal = 0x6F;
  static const jalr = 0x67;
  static const branch = 0x63;
  static const load = 0x03;
  static const store = 0x23;
  static const opImm = 0x13;
  static const op = 0x33;
  static const opImm32 = 0x1B;
  static const op32 = 0x3B;
  static const fence = 0x0F;
  static const system = 0x73;
  static const amo = 0x2F;
}

/// Standard RISC-V funct3 values for branches.
abstract final class BranchFunct3 {
  static const beq = 0x0;
  static const bne = 0x1;
  static const blt = 0x4;
  static const bge = 0x5;
  static const bltu = 0x6;
  static const bgeu = 0x7;
}

/// Standard RISC-V funct3 values for loads.
abstract final class LoadFunct3 {
  static const lb = 0x0;
  static const lh = 0x1;
  static const lw = 0x2;
  static const ld = 0x3;
  static const lbu = 0x4;
  static const lhu = 0x5;
  static const lwu = 0x6;
}

/// Standard RISC-V funct3 values for stores.
abstract final class StoreFunct3 {
  static const sb = 0x0;
  static const sh = 0x1;
  static const sw = 0x2;
  static const sd = 0x3;
}

/// Standard RISC-V funct3 values for ALU immediate ops.
abstract final class AluImmFunct3 {
  static const addi = 0x0;
  static const slti = 0x2;
  static const sltiu = 0x3;
  static const xori = 0x4;
  static const ori = 0x6;
  static const andi = 0x7;
  static const slli = 0x1;
  static const srli = 0x5; // also SRAI with funct7
}

/// Standard RISC-V funct3 values for ALU register ops.
abstract final class AluRegFunct3 {
  static const add = 0x0; // also SUB with funct7
  static const sll = 0x1;
  static const slt = 0x2;
  static const sltu = 0x3;
  static const xor = 0x4;
  static const srl = 0x5; // also SRA with funct7
  static const or = 0x6;
  static const and = 0x7;
}

/// Standard RISC-V funct3 values for CSR operations.
abstract final class CsrFunct3 {
  static const csrrw = 0x1;
  static const csrrs = 0x2;
  static const csrrc = 0x3;
  static const csrrwi = 0x5;
  static const csrrsi = 0x6;
  static const csrrci = 0x7;
}
