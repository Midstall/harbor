import 'mxlen.dart';
import 'operation.dart';

/// A RISC-V ISA extension containing a set of instructions.
///
/// Extensions are const and declarative. They define the
/// instructions they provide and their misa bit.
///
/// ```dart
/// const rv32m = RiscVExtension(
///   name: 'RV32M',
///   key: 'M',
///   misaBit: 12,
///   operations: [mul, mulh, mulhsu, mulhu, div, divu, rem, remu],
/// );
/// ```
class RiscVExtension {
  /// Full extension name (e.g., `'RV32I'`, `'RV64M'`).
  final String name;

  /// Single-letter key for misa (e.g., `'I'`, `'M'`, `'A'`).
  /// Can be longer for named extensions (e.g., `'Zicsr'`).
  final String? key;

  /// Bit position in the misa register (0=A, 1=B, ..., 25=Z).
  /// `null` for sub-extensions like Zicsr that don't have their own bit.
  final int? misaBit;

  /// misa mask value. Computed from [misaBit] if set.
  int get mask => misaBit != null ? (1 << misaBit!) : 0;

  /// All operations defined by this extension.
  final List<RiscVOperation> operations;

  const RiscVExtension({
    required this.name,
    this.key,
    this.misaBit,
    this.operations = const [],
  });

  /// Finds an operation by opcode and optional funct fields.
  ///
  /// When [instruction] (the raw word) is provided, raw-bit discriminators
  /// ([RiscVOperation.matchesRaw]) are also applied, so overlapping encodings
  /// (e.g. c.mv vs c.add) resolve to the correct operation.
  RiscVOperation? findOperation(
    int opcode, {
    int? funct3,
    int? funct7,
    int? instruction,
  }) {
    for (final op in operations) {
      if (op.matches(opcode, funct3, funct7) &&
          (instruction == null || op.matchesRaw(instruction))) {
        return op;
      }
    }
    return null;
  }

  /// Operations valid for the given [mxlen].
  List<RiscVOperation> operationsFor(RiscVMxlen mxlen) =>
      operations.where((op) => op.isValidFor(mxlen)).toList();

  @override
  String toString() => 'RiscVExtension($name)';
}
