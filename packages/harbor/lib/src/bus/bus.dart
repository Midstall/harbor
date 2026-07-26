/// Common bus infrastructure types shared across all bus protocols.

/// An address range on a bus.
///
/// Used by decoders to route transactions to the correct slave.
class BusAddressRange {
  /// Start address (inclusive).
  final int start;

  /// Size in bytes.
  final int size;

  const BusAddressRange(this.start, this.size);

  /// End address (exclusive).
  int get end => start + size;

  /// Whether [addr] falls within this range.
  bool contains(int addr) => addr >= start && addr < end;

  /// Returns a new range shifted by [offset] with optional new [size].
  BusAddressRange shift({int offset = 0, int? size}) =>
      BusAddressRange(start + offset, size ?? this.size);

  @override
  String toString() =>
      'BusAddressRange(0x${start.toRadixString(16)}, size: 0x${size.toRadixString(16)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BusAddressRange && start == other.start && size == other.size;

  @override
  int get hashCode => Object.hash(start, size);
}

/// Arbitration strategy for multi-master buses.
enum BusArbitration {
  /// Fixed priority: lower index wins.
  fixed,

  /// Round-robin: each master gets a turn.
  roundRobin,

  /// Priority-based with explicit priority values.
  priority,
}

/// Maps an address range to a slave index for use in bus decoders.
class HarborAddressMapping {
  /// The address range this mapping covers.
  final BusAddressRange range;

  /// Index of the slave this range maps to.
  final int slaveIndex;

  const HarborAddressMapping({required this.range, required this.slaveIndex});

  /// Whether [addr] hits this mapping.
  bool hit(int addr) => range.contains(addr);

  @override
  String toString() => 'HarborAddressMapping(slave: $slaveIndex, $range)';
}

/// Validates a list of address mappings for overlaps.
///
/// Returns a list of error messages. Empty means valid.
List<String> validateAddressMappings(List<HarborAddressMapping> mappings) {
  final errors = <String>[];
  for (var i = 0; i < mappings.length; i++) {
    for (var j = i + 1; j < mappings.length; j++) {
      final a = mappings[i].range;
      final b = mappings[j].range;
      if (a.start < b.end && b.start < a.end) {
        errors.add(
          'Address overlap between slave ${mappings[i].slaveIndex} '
          '($a) and slave ${mappings[j].slaveIndex} ($b)',
        );
      }
    }
  }
  return errors;
}
