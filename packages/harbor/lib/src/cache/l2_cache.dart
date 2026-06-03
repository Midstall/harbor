import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cache_config.dart';

/// Synthesizable L2 unified cache with coherency directory.
///
/// Serves as a shared last-level cache between L1I and L1D caches
/// (or multiple harts). Implements a coherency directory for
/// tracking cache line ownership across L1 caches.
///
/// Supports configurable coherency protocols (MSI, MESI, MOESI)
/// and inclusive/exclusive/NINE policies relative to L1.
class HarborL2Cache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Number of L1 caches connected (requestors).
  final int numRequestors;

  /// Coherency protocol.
  final HarborCoherencyProtocol coherencyProtocol;

  /// Inclusion policy relative to L1.
  final HarborInclusionPolicy inclusionPolicy;

  HarborL2Cache({
    required this.config,
    this.numRequestors = 2,
    this.coherencyProtocol = HarborCoherencyProtocol.mesi,
    this.inclusionPolicy = HarborInclusionPolicy.inclusive,
    super.name = 'l2',
  }) : super('HarborL2Cache') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Per-requestor interfaces
    for (var i = 0; i < numRequestors; i++) {
      // Request from L1
      createPort('req${i}_addr', PortDirection.input, width: 32);
      createPort('req${i}_valid', PortDirection.input);
      createPort('req${i}_write', PortDirection.input);
      addInput(
        'req${i}_data',
        Logic(width: config.lineSize * 8),
        width: config.lineSize * 8,
      );
      addOutput('resp${i}_data', width: config.lineSize * 8);
      addOutput('resp${i}_valid');

      // Snoop to L1 (for coherency)
      addOutput('snoop${i}_addr', width: 32);
      addOutput('snoop${i}_valid');
      addOutput('snoop${i}_invalidate');
      createPort('snoop${i}_hit', PortDirection.input);
      addInput(
        'snoop${i}_data',
        Logic(width: config.lineSize * 8),
        width: config.lineSize * 8,
      );
    }

    // Memory-side interface
    addOutput('mem_addr', width: 32);
    addOutput('mem_read', width: 1);
    addOutput('mem_write', width: 1);
    addOutput('mem_wdata', width: config.lineSize * 8);
    addInput(
      'mem_rdata',
      Logic(width: config.lineSize * 8),
      width: config.lineSize * 8,
    );
    createPort('mem_valid', PortDirection.input);
    addOutput('mem_request');

    // Performance counters
    addOutput('perf_hits', width: 32);
    addOutput('perf_misses', width: 32);
    addOutput('perf_evictions', width: 32);

    final clk = input('clk');
    final reset = input('reset');

    // Directory entry: valid, dirty, owner mask, tag
    // The directory tracks which L1 has each line
    final state = Logic(name: 'l2_state', width: 3);

    final perfHits = Logic(name: 'perf_hits', width: 32);
    final perfMisses = Logic(name: 'perf_misses', width: 32);
    final perfEvictions = Logic(name: 'perf_evictions', width: 32);

    output('perf_hits') <= perfHits;
    output('perf_misses') <= perfMisses;
    output('perf_evictions') <= perfEvictions;

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(0, width: 3),
          perfHits < Const(0, width: 32),
          perfMisses < Const(0, width: 32),
          perfEvictions < Const(0, width: 32),
          output('mem_request') < Const(0),
          for (var i = 0; i < numRequestors; i++) ...[
            output('resp${i}_valid') < Const(0),
            output('snoop${i}_valid') < Const(0),
            output('snoop${i}_invalidate') < Const(0),
          ],
        ],
        orElse: [
          // L2 FSM: arbitrate among requestors, perform tag lookup,
          // issue snoops for coherency, handle refills and writebacks.
          // The specific implementation depends on the coherency protocol.
          //
          // MSI: 3 states (Modified, Shared, Invalid)
          // MESI: 4 states (adds Exclusive)
          // MOESI: 5 states (adds Owned)
          //
          // Framework provides the structure. River fills in the details.
        ],
      ),
    ]);

    // Placeholder outputs
    output('mem_addr') <= Const(0, width: 32);
    output('mem_read') <= Const(0);
    output('mem_write') <= Const(0);
    output('mem_wdata') <= Const(0, width: config.lineSize * 8);
    for (var i = 0; i < numRequestors; i++) {
      output('resp${i}_data') <= Const(0, width: config.lineSize * 8);
      output('snoop${i}_addr') <= Const(0, width: 32);
    }
  }
}
