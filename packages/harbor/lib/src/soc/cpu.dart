import '../util/pretty_string.dart';

/// A CPU hart description shared across all SoC generators.
///
/// This is the single source of truth consumed by the device tree, ACPI and
/// topology graph generators. Generators read these fields and emit them in
/// their own format. There is no conversion between generator-specific CPU
/// types.
class HarborCpu with HarborPrettyString {
  /// Hart ID.
  final int hartId;

  /// ISA string, e.g. `"rv64imac"`.
  final String isa;

  /// MMU type, e.g. `"riscv,sv39"` (optional).
  final String? mmu;

  /// Clock frequency in Hz (optional).
  final int? clockFrequency;

  /// Timer (`mtime`) tick rate in Hz, emitted as the device tree
  /// `timebase-frequency` (optional). The Harbor CLINT increments `mtime`
  /// once per bus clock, so this equals the clock the CLINT runs at. RISC-V
  /// requires it for the timer, so a DTS without it leaves an OS with no
  /// working time source.
  final int? timebaseFrequency;

  const HarborCpu({
    required this.hartId,
    required this.isa,
    this.mmu,
    this.clockFrequency,
    this.timebaseFrequency,
  });

  @override
  String toString() => 'HarborCpu(hart$hartId, $isa)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborCpu(\n');
    buf.writeln('${c}hartId: $hartId,');
    buf.writeln('${c}isa: $isa,');
    if (mmu != null) buf.writeln('${c}mmu: $mmu,');
    if (clockFrequency != null)
      buf.writeln('${c}clockFrequency: $clockFrequency,');
    if (timebaseFrequency != null)
      buf.writeln('${c}timebaseFrequency: $timebaseFrequency,');
    buf.write('$p)');
    return buf.toString();
  }
}
