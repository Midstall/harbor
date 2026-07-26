import '../util/pretty_string.dart';
import 'cache_config.dart';

/// Configuration for a complete cache hierarchy.
///
/// Supports L1/L2/L3 with configurable coherency for multi-core
/// systems.
///
/// ```dart
/// // Single-core with split L1 + shared L2
/// final hierarchy = HarborCacheHierarchy(
///   l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 4),
///   l2: HarborCacheConfig(size: 256 * 1024, ways: 8),
/// );
///
/// // Multi-core with per-core L1/L2 + shared L3 + MESI coherency
/// final hierarchy = HarborCacheHierarchy(
///   l1: HarborL1CacheConfig.split(iSize: 32768, dSize: 32768, ways: 8),
///   l2: HarborCacheConfig(size: 256 * 1024, ways: 8),
///   l3: HarborCacheConfig(size: 4 * 1024 * 1024, ways: 16),
///   coherency: HarborCoherencyConfig(
///     protocol: HarborCoherencyProtocol.mesi,
///     l2Sharing: HarborCacheSharing.perCore,
///     l3Sharing: HarborCacheSharing.shared,
///   ),
/// );
/// ```
class HarborCacheHierarchy with HarborPrettyString {
  /// L1 cache configuration.
  final HarborL1CacheConfig l1;

  /// L2 cache configuration (null if no L2).
  final HarborCacheConfig? l2;

  /// L3 cache configuration (null if no L3).
  final HarborCacheConfig? l3;

  /// L2 inclusion policy relative to L1.
  final HarborInclusionPolicy l2Inclusion;

  /// L3 inclusion policy relative to L2.
  final HarborInclusionPolicy l3Inclusion;

  /// Coherency configuration for multi-core.
  final HarborCoherencyConfig coherency;

  const HarborCacheHierarchy({
    required this.l1,
    this.l2,
    this.l3,
    this.l2Inclusion = HarborInclusionPolicy.nine,
    this.l3Inclusion = HarborInclusionPolicy.inclusive,
    this.coherency = const HarborCoherencyConfig(),
  });

  /// Number of cache levels.
  int get levels => 1 + (l2 != null ? 1 : 0) + (l3 != null ? 1 : 0);

  /// Whether coherency is enabled.
  bool get isCoherent => coherency.protocol != HarborCoherencyProtocol.none;

  @override
  String toString() =>
      'HarborCacheHierarchy($levels levels'
      '${isCoherent ? ", ${coherency.protocol.name}" : ""})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborCacheHierarchy(\n');
    buf.writeln('${c}L1:');
    buf.writeln(l1.toPrettyString(options.nested()));
    if (l2 != null) {
      buf.writeln('${c}L2 (${l2Inclusion.name}):');
      buf.writeln(l2!.toPrettyString(options.nested()));
    }
    if (l3 != null) {
      buf.writeln('${c}L3 (${l3Inclusion.name}):');
      buf.writeln(l3!.toPrettyString(options.nested()));
    }
    if (isCoherent) {
      buf.writeln('${c}coherency:');
      buf.writeln(coherency.toPrettyString(options.nested()));
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// How a cache level is shared across cores.
enum HarborCacheSharing {
  /// Each core has its own private instance.
  perCore,

  /// Shared across all cores.
  shared,

  /// Shared across a cluster of cores.
  perCluster,
}

/// Coherency configuration for multi-core cache systems.
class HarborCoherencyConfig with HarborPrettyString {
  /// The coherency protocol.
  final HarborCoherencyProtocol protocol;

  /// How L1 caches are shared (always per-core in practice).
  final HarborCacheSharing l1Sharing;

  /// How L2 caches are shared.
  final HarborCacheSharing l2Sharing;

  /// How L3 caches are shared.
  final HarborCacheSharing l3Sharing;

  /// Number of snoop filter entries (0 = no snoop filter).
  final int snoopFilterEntries;

  /// Whether to use a directory-based protocol (vs. snooping).
  final bool directoryBased;

  const HarborCoherencyConfig({
    this.protocol = HarborCoherencyProtocol.none,
    this.l1Sharing = HarborCacheSharing.perCore,
    this.l2Sharing = HarborCacheSharing.perCore,
    this.l3Sharing = HarborCacheSharing.shared,
    this.snoopFilterEntries = 0,
    this.directoryBased = false,
  });

  @override
  String toString() => 'HarborCoherencyConfig(${protocol.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborCoherencyConfig(\n');
    buf.writeln('${c}protocol: ${protocol.name},');
    buf.writeln('${c}L1: ${l1Sharing.name},');
    buf.writeln('${c}L2: ${l2Sharing.name},');
    buf.writeln('${c}L3: ${l3Sharing.name},');
    if (directoryBased) buf.writeln('${c}directory-based,');
    if (snoopFilterEntries > 0) {
      buf.writeln('${c}snoopFilter: $snoopFilterEntries entries,');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

/// MOESI cache line state.
///
/// Used in coherency protocol implementations.
enum HarborCacheLineState {
  /// Invalid: line not present.
  invalid,

  /// Shared: clean, may exist in other caches.
  shared,

  /// Exclusive: clean, only copy.
  exclusive,

  /// Modified: dirty, only copy.
  modified,

  /// Owned: dirty, may exist as shared in others (MOESI only).
  owned,
}

/// Coherency bus transaction types.
enum HarborCoherencyTransaction {
  /// Read for shared access.
  busRead,

  /// Read for exclusive access (intent to modify).
  busReadExclusive,

  /// Write-back dirty data.
  busWriteBack,

  /// Upgrade shared to exclusive.
  busUpgrade,

  /// Invalidate other copies.
  busInvalidate,

  /// Flush line from all caches.
  busFlush,
}
