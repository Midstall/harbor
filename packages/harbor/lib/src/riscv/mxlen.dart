/// RISC-V base integer register width.
///
/// Parameterizes the entire ISA: instruction encoding, register
/// widths, address sizes, and available paging modes all depend
/// on the selected XLEN.
enum RiscVMxlen {
  /// 32-bit RISC-V.
  rv32(32, misaXl: 1),

  /// 64-bit RISC-V.
  rv64(64, misaXl: 2),

  /// 128-bit RISC-V.
  rv128(128, misaXl: 3);

  /// Register width in bits.
  final int size;

  /// MXL field value for misa register.
  final int misaXl;

  const RiscVMxlen(this.size, {required this.misaXl});

  /// Register width in bytes.
  int get bytes => size ~/ 8;

  /// misa register value for the base ISA (MXL field positioned).
  int get misa => misaXl << (size - 2);

  /// satp MODE field shift.
  int get satpModeShift => size == 32 ? 31 : 60;

  /// satp MODE field mask.
  int get satpModeMask => size == 32 ? 0x1 : 0xF;

  /// satp PPN field mask.
  int get satpPpnMask => size == 32
      ? 0x003FFFFF
      : size == 64
      ? 0x00000FFFFFFFFFFF
      : 0; // RV128 TBD

  @override
  String toString() => 'RV$size';
}
