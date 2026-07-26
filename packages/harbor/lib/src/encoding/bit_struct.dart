import 'package:rohd/rohd.dart';

import '../util/pretty_string.dart';

/// A contiguous range of bits within a word.
class HarborBitRange {
  /// Start bit position (inclusive, LSB = 0).
  final int start;

  /// End bit position (inclusive).
  final int end;

  const HarborBitRange(this.start, this.end)
    : assert(start <= end, 'start must be <= end');

  /// Single-bit range.
  const HarborBitRange.single(this.start) : end = start;

  /// Width in bits.
  int get width => end - start + 1;

  /// Bitmask for this range (unshifted).
  int get mask => (1 << width) - 1;

  /// Extracts this field from [value].
  int decode(int value) => (value >> start) & mask;

  /// Places [fieldValue] into this range position.
  int encode(int fieldValue) => (fieldValue & mask) << start;

  @override
  String toString() => 'HarborBitRange($start:$end)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HarborBitRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// A structured bit layout: maps named fields to [HarborBitRange]s within
/// a fixed-width word.
///
/// Provides both integer encode/decode for software-level use AND
/// hardware [Logic] field access for RTL generation.
///
/// ```dart
/// // Define the R-type RISC-V instruction format
/// const rType = HarborBitStruct({
///   'opcode': HarborBitRange(0, 6),
///   'rd':     HarborBitRange(7, 11),
///   'funct3': HarborBitRange(12, 14),
///   'rs1':    HarborBitRange(15, 19),
///   'rs2':    HarborBitRange(20, 24),
///   'funct7': HarborBitRange(25, 31),
/// });
///
/// // Software: encode/decode integers
/// final encoded = rType.encode({'opcode': 0x33, 'rd': 1, ...});
/// final fields = rType.decode(0x00208033);
///
/// // Hardware: get Logic slices from a 32-bit signal
/// final instrSignal = Logic(width: 32);
/// final view = rType.view(instrSignal);
/// final rd = view['rd'];     // Logic slice bits 7:11
/// final rs1 = view['rs1'];   // Logic slice bits 15:19
/// ```
class HarborBitStruct with HarborPrettyString {
  /// Field name → bit range mapping.
  final Map<String, HarborBitRange> fields;

  /// Optional name for this struct, used to distinguish formats
  /// that share the same field layout (e.g. U-type vs J-type).
  final String? name;

  const HarborBitStruct(this.fields, {this.name});

  /// Total width of the struct in bits (max end + 1).
  int get width {
    var maxEnd = 0;
    for (final range in fields.values) {
      if (range.end + 1 > maxEnd) maxEnd = range.end + 1;
    }
    return maxEnd;
  }

  /// Combined mask of all fields.
  int get mask {
    var m = 0;
    for (final range in fields.values) {
      m |= range.mask << range.start;
    }
    return m;
  }

  /// Decodes an integer value into a map of field values.
  Map<String, int> decode(int value) => {
    for (final entry in fields.entries) entry.key: entry.value.decode(value),
  };

  /// Encodes a map of field values into an integer.
  int encode(Map<String, int> fieldValues) {
    var result = 0;
    for (final entry in fieldValues.entries) {
      final range = fields[entry.key];
      if (range != null) {
        result |= range.encode(entry.value);
      }
    }
    return result;
  }

  /// Gets a single field from [value].
  int getField(int value, String name) {
    final range = fields[name];
    if (range == null) {
      throw ArgumentError('Field "$name" not found in HarborBitStruct');
    }
    return range.decode(value);
  }

  /// Sets a single field in [value], returning the new value.
  int setField(int value, String name, int fieldValue) {
    final range = fields[name];
    if (range == null) {
      throw ArgumentError('Field "$name" not found in HarborBitStruct');
    }
    value &= ~(range.mask << range.start);
    value |= range.encode(fieldValue);
    return value;
  }

  /// Creates a hardware view of this struct over a [Logic] signal.
  ///
  /// Returns a [HarborBitStructView] that provides named [Logic] slices
  /// for each field.
  HarborBitStructView view(Logic signal) {
    if (signal.width < width) {
      throw ArgumentError(
        'Signal width ${signal.width} is less than struct width $width',
      );
    }
    return HarborBitStructView._(this, signal);
  }

  /// All field names in this struct.
  Iterable<String> get fieldNames => fields.keys;

  /// The range for the given field [name].
  HarborBitRange? operator [](String name) => fields[name];

  @override
  String toString() => 'HarborBitStruct($fields)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborBitStruct(\n');
    for (final entry in fields.entries) {
      final r = entry.value;
      buf.writeln('$c${entry.key}: [${r.end}:${r.start}] (${r.width} bits),');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// A hardware view of a [HarborBitStruct] over a [Logic] signal.
///
/// Provides named field access as [Logic] slices. Each field
/// returns a slice of the underlying signal: no copies.
///
/// ```dart
/// final view = rType.view(instruction);
/// final opcode = view['opcode']; // instruction[6:0]
/// final rd = view['rd'];         // instruction[11:7]
/// ```
class HarborBitStructView {
  /// The struct layout.
  final HarborBitStruct struct;

  /// The underlying hardware signal.
  final Logic signal;

  final Map<String, Logic> _cache = {};

  HarborBitStructView._(this.struct, this.signal);

  /// Gets the [Logic] slice for field [name].
  ///
  /// Slices are cached: multiple accesses return the same [Logic].
  Logic operator [](String name) {
    return _cache.putIfAbsent(name, () {
      final range = struct.fields[name];
      if (range == null) {
        throw ArgumentError(
          'Field "$name" not found. '
          'Available: ${struct.fieldNames.join(", ")}',
        );
      }
      return signal.getRange(range.start, range.end + 1);
    });
  }

  /// Whether the struct has a field with the given [name].
  bool has(String name) => struct.fields.containsKey(name);

  /// All field names.
  Iterable<String> get fieldNames => struct.fieldNames;

  /// Returns a map of all field [Logic] slices.
  Map<String, Logic> get all => {
    for (final name in fieldNames) name: this[name],
  };
}
