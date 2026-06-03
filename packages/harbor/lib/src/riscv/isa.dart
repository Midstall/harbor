import 'extension.dart';
import 'mxlen.dart';
import 'operation.dart';
import 'paging.dart';

/// Complete RISC-V ISA configuration.
///
/// Combines an XLEN, a set of extensions, privilege mode support,
/// and paging configuration into a single description of what
/// the CPU implements.
///
/// ```dart
/// final isa = RiscVIsaConfig(
///   mxlen: RiscVMxlen.rv64,
///   extensions: [rv64i, rv64m, rv64a, rvD, rvC, rvV, rvH, rvZicsr],
///   hasSupervisor: true,
///   hasUser: true,
///   pagingModes: [RiscVPagingMode.bare, RiscVPagingMode.sv39, RiscVPagingMode.sv48],
///   executionOverrides: {'div': RiscVExecutionMode.microcoded},
/// );
/// ```
class RiscVIsaConfig {
  /// Base integer register width.
  final RiscVMxlen mxlen;

  /// ISA extensions included.
  final List<RiscVExtension> extensions;

  /// Whether supervisor mode is supported.
  final bool hasSupervisor;

  /// Whether user mode is supported.
  final bool hasUser;

  /// Supported paging modes.
  ///
  /// If empty, derived from [mxlen] (all modes supported by the XLEN).
  final List<RiscVPagingMode> pagingModes;

  /// Per-instruction execution mode overrides.
  ///
  /// Keys are instruction mnemonics. Overrides the default
  /// [RiscVExecutionMode] set in each [RiscVOperation].
  final Map<String, RiscVExecutionMode> executionOverrides;

  const RiscVIsaConfig({
    required this.mxlen,
    required this.extensions,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.pagingModes = const [],
    this.executionOverrides = const {},
  });

  /// All paging modes, using defaults if none specified.
  List<RiscVPagingMode> get effectivePagingModes =>
      pagingModes.isNotEmpty ? pagingModes : RiscVPagingMode.supportedBy(mxlen);

  /// All operations from all extensions, filtered by XLEN.
  List<RiscVOperation> get allOperations =>
      extensions.expand((ext) => ext.operationsFor(mxlen)).toList();

  /// Operations that should be hard-coded (fast path).
  List<RiscVOperation> get hardcodedOps => allOperations
      .where(
        (op) =>
            _effectiveMode(op) == RiscVExecutionMode.hardcoded ||
            _effectiveMode(op) == RiscVExecutionMode.parallel,
      )
      .toList();

  /// Operations that should be microcoded.
  List<RiscVOperation> get microcodedOps => allOperations
      .where(
        (op) =>
            _effectiveMode(op) == RiscVExecutionMode.microcoded ||
            _effectiveMode(op) == RiscVExecutionMode.parallel,
      )
      .toList();

  /// Gets the effective execution mode for an operation,
  /// considering overrides.
  RiscVExecutionMode _effectiveMode(RiscVOperation op) =>
      executionOverrides[op.mnemonic] ?? op.executionMode;

  /// The effective execution mode for a specific operation.
  RiscVExecutionMode executionModeFor(RiscVOperation op) => _effectiveMode(op);

  /// Finds an operation matching the given instruction word.
  ///
  /// Extracts opcode, funct3, funct7 from the instruction and
  /// searches all extensions.
  RiscVOperation? findOperation(int instruction) {
    final opcode = instruction & 0x7F;
    final funct3 = (instruction >> 12) & 0x7;
    final funct7 = (instruction >> 25) & 0x7F;

    for (final ext in extensions) {
      final op = ext.findOperation(
        opcode,
        funct3: funct3,
        funct7: funct7,
        instruction: instruction,
      );
      if (op != null && op.isValidFor(mxlen)) return op;
    }
    return null;
  }

  /// The ISA string (e.g., `"RV64IMACV"`).
  ///
  /// Follows RISC-V naming convention: base + single-letter
  /// extensions in canonical order.
  String get implementsString {
    final hasI = extensions.any((e) => e.key == 'I');
    final hasE = extensions.any((e) => e.key == 'E');
    if (!hasI && !hasE) return 'RV${mxlen.size}';

    final baseLetter = hasE ? 'E' : 'I';
    final buf = StringBuffer('RV${mxlen.size}$baseLetter');

    // Canonical extension order: MAFDQLCBJTPVN + H + S + U
    const order = 'MAFDQLCBJTPVN';
    for (final c in order.split('')) {
      if (extensions.any((e) => e.key == c)) buf.write(c);
    }

    // Hypervisor
    if (extensions.any((e) => e.key == 'H')) buf.write('H');

    // Privilege modes
    if (hasSupervisor) buf.write('S');
    if (hasUser) buf.write('U');

    return buf.toString();
  }

  /// Combined misa register value for all extensions.
  int get misaValue {
    var value = mxlen.misa;
    for (final ext in extensions) {
      value |= ext.mask;
    }
    if (hasSupervisor) value |= (1 << 18); // S bit
    if (hasUser) value |= (1 << 20); // U bit
    return value;
  }

  @override
  String toString() => 'RiscVIsaConfig(${implementsString})';
}
