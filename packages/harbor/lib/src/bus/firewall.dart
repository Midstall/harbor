/// Protocol-agnostic bus firewall: the single security-critical unit of an
/// enclave aperture.
///
/// [HarborBusFirewall] decides whether an incoming bus access is allowed,
/// against a FIXED compile-time address whitelist. It is purely COMBINATIONAL
/// (no clock, no state), so its security property is formally provable as an
/// unbounded single-step check (see ip/formal/busfw.sby in the sibling albion
/// repo).
///
/// The predicate is:
///
///   allow = valid & OR over ranges of (
///             addr >= range.start
///             AND
///             addr + len*beatStride - 1 <= range.start + range.size - 1
///           )
///
/// i.e. the WHOLE access including its LAST beat must fall inside ONE
/// whitelisted range. A burst that straddles out of a range yields allow=0,
/// and a zero-length access (len==0) is treated as touching no bytes and is
/// therefore allowed iff its base is inside a range (the upper bound collapses
/// to `addr - 1`, which can never exceed the range when `addr >= start`).

library;

import 'package:rohd/rohd.dart';

import 'bus.dart';

/// Combinational, fixed-whitelist bus access firewall.
///
/// This is a plain ROHD [Module] (NOT a BridgeModule) so it can be emitted to
/// SystemVerilog and discharged by a formal prover with no state to unroll.
class HarborBusFirewall extends Module {
  /// Width of the [addr] input in bits.
  final int addrWidth;

  /// Bytes per beat. Multiplied by [len] to size the access.
  final int beatStride;

  /// The fixed, compile-time list of allowed address ranges.
  final List<BusAddressRange> whitelist;

  /// 1 iff [valid] is asserted AND the full access (all [len] beats) is
  /// contained in a single whitelisted [BusAddressRange].
  Logic get allow => output('allow');

  HarborBusFirewall({
    required Logic addr,
    required Logic len,
    required Logic valid,
    required this.whitelist,
    this.beatStride = 4,
    super.name = 'harbor_bus_firewall',
  }) : addrWidth = addr.width {
    if (whitelist.isEmpty) {
      throw ArgumentError('HarborBusFirewall whitelist must not be empty');
    }
    if (beatStride <= 0) {
      throw ArgumentError('beatStride must be positive, got $beatStride');
    }

    // Validate every whitelist range up front: a security-critical block must
    // fail loud rather than emit a netlist whose range can never match. A
    // zero/negative size matches nothing, and a range running past the
    // addressable space (start + size > 2^addrWidth) cannot be hit either.
    final addrLimit = BigInt.one << addrWidth;
    for (final range in whitelist) {
      if (range.size <= 0) {
        throw ArgumentError(
          'HarborBusFirewall whitelist range $range has non-positive size; '
          'each range must have size > 0',
        );
      }
      final top = BigInt.from(range.start) + BigInt.from(range.size);
      if (top > addrLimit) {
        throw ArgumentError(
          'HarborBusFirewall whitelist range $range exceeds the addressable '
          'space: start + size must be <= 2^addrWidth (1 << $addrWidth)',
        );
      }
    }

    final lenWidth = len.width;
    addr = addInput('addr', addr, width: addrWidth);
    len = addInput('len', len, width: lenWidth);
    valid = addInput('valid', valid);

    addOutput('allow');

    // Work in a width wide enough to hold `addr + len*beatStride` without
    // wrap-around. len*beatStride needs lenWidth + ceil(log2(beatStride))
    // extra bits over addr. Pad generously so the add can never overflow.
    final strideBits = beatStride.bitLength; // ceil(log2) headroom (+1 ok).
    final workWidth = addrWidth + lenWidth + strideBits + 1;

    final addrW = addr.zeroExtend(workWidth);
    final strideC = Const(beatStride, width: workWidth);
    // byteCount = len * beatStride.
    final byteCount = len.zeroExtend(workWidth) * strideC;
    // last = addr + byteCount - 1 (the highest byte the access touches).
    final last = addrW + byteCount - Const(1, width: workWidth);

    // OR across every whitelisted range. Each range is a compile-time const so
    // its bounds are pure constants in the netlist.
    Logic anyHit = Const(0);
    for (final range in whitelist) {
      final baseC = Const(range.start, width: workWidth);
      // top byte (inclusive) = start + size - 1.
      final topC = Const(range.start + range.size - 1, width: workWidth);
      final lowerOk = addrW.gte(baseC);
      final upperOk = last.lte(topC);
      anyHit |= lowerOk & upperOk;
    }

    allow <= (valid & anyHit);
  }
}
