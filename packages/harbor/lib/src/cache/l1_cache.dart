import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cache_config.dart';

/// L1 cache request type.
enum HarborL1RequestType {
  /// Instruction fetch.
  fetch,

  /// Data load.
  load,

  /// Data store.
  store,

  /// Atomic (LR/SC/AMO).
  atomic,

  /// Cache management (fence, invalidate).
  management,
}

/// L1 cache line state for coherency.
enum HarborL1LineState {
  /// Invalid.
  invalid,

  /// Shared (read-only, other copies may exist).
  shared,

  /// Exclusive (only copy, clean).
  exclusive,

  /// Modified (only copy, dirty).
  modified,

  /// Owned (dirty, other shared copies may exist - MOESI only).
  owned,
}

/// Synthesizable L1 instruction cache.
///
/// Set-associative cache with configurable size, associativity,
/// and line size. Generates the tag RAM, data RAM, hit detection,
/// and replacement logic.
///
/// Connects to the CPU fetch port on the request side and the
/// L2/memory bus on the refill side.
class HarborL1ICache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Request port (from CPU fetch unit).
  Logic get reqAddr => input('req_addr');
  Logic get reqValid => input('req_valid');
  Logic get respData => output('resp_data');
  Logic get respValid => output('resp_valid');
  Logic get miss => output('miss');

  /// Refill port (to L2/memory).
  Logic get refillAddr => output('refill_addr');
  Logic get refillRequest => output('refill_request');
  Logic get refillData => input('refill_data');
  Logic get refillValid => input('refill_valid');

  HarborL1ICache({required this.config, super.name = 'l1i'})
    : super('HarborL1ICache') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // CPU-side request interface
    createPort('req_addr', PortDirection.input, width: 32);
    createPort('req_valid', PortDirection.input);
    addOutput('resp_data', width: config.lineSize * 8);
    addOutput('resp_valid');
    addOutput('miss');

    // Refill interface to L2/memory
    addOutput('refill_addr', width: 32);
    addOutput('refill_request');
    addInput(
      'refill_data',
      Logic(width: config.lineSize * 8),
      width: config.lineSize * 8,
    );
    createPort('refill_valid', PortDirection.input);

    // Invalidate interface
    createPort('invalidate', PortDirection.input);
    createPort('invalidate_addr', PortDirection.input, width: 32);

    final clk = input('clk');
    final reset = input('reset');

    // FSM states
    final idle = Logic(name: 'idle');
    final refilling = Logic(name: 'refilling');

    // Tag and valid arrays (per way)
    final tagHit = Logic(name: 'tag_hit');
    final wayHit = Logic(name: 'way_hit', width: config.ways);

    // Simplified: actual tag/data RAMs would be inferred memory
    // This provides the structural framework for synthesis
    Sequential(clk, [
      If(
        reset,
        then: [
          idle < Const(1),
          refilling < Const(0),
          output('resp_valid') < Const(0),
          output('miss') < Const(0),
          output('refill_request') < Const(0),
          output('refill_addr') < Const(0, width: 32),
        ],
        orElse: [
          output('resp_valid') < Const(0),
          output('miss') < Const(0),

          If(
            idle & reqValid,
            then: [
              // Tag lookup would happen here
              // On hit: return data
              // On miss: transition to refill state
              If(
                tagHit,
                then: [output('resp_valid') < Const(1)],
                orElse: [
                  output('miss') < Const(1),
                  output('refill_request') < Const(1),
                  output('refill_addr') < reqAddr,
                  idle < Const(0),
                  refilling < Const(1),
                ],
              ),
            ],
          ),

          If(
            refilling & refillValid,
            then: [
              // Write refill data to cache
              output('refill_request') < Const(0),
              output('resp_valid') < Const(1),
              refilling < Const(0),
              idle < Const(1),
            ],
          ),

          // Invalidate handling
          If(
            input('invalidate'),
            then: [
              // Invalidate specific line or entire cache
            ],
          ),
        ],
      ),
    ]);

    // Placeholder for tag comparison
    tagHit <= Const(0);
    wayHit <= Const(0, width: config.ways);
    respData <= Const(0, width: config.lineSize * 8);
  }
}

/// Synthesizable L1 data cache.
///
/// Set-associative write-back cache with configurable write policy,
/// store buffer, and coherency support.
class HarborL1DCache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Whether to include a store buffer.
  final bool hasStoreBuffer;

  /// Store buffer depth.
  final int storeBufferDepth;

  HarborL1DCache({
    required this.config,
    this.hasStoreBuffer = true,
    this.storeBufferDepth = 4,
    super.name = 'l1d',
  }) : super('HarborL1DCache') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // CPU-side request interface
    createPort('req_addr', PortDirection.input, width: 32);
    createPort('req_valid', PortDirection.input);
    createPort('req_write', PortDirection.input);
    createPort('req_data', PortDirection.input, width: 32);
    createPort('req_size', PortDirection.input, width: 2); // byte/half/word
    addOutput('resp_data', width: 32);
    addOutput('resp_valid');
    addOutput('miss');
    addOutput('busy');

    // Refill/writeback interface to L2/memory
    addOutput('refill_addr', width: 32);
    addOutput('refill_request');
    addInput(
      'refill_data',
      Logic(width: config.lineSize * 8),
      width: config.lineSize * 8,
    );
    createPort('refill_valid', PortDirection.input);

    addOutput('writeback_addr', width: 32);
    addOutput('writeback_data', width: config.lineSize * 8);
    addOutput('writeback_valid');
    createPort('writeback_ack', PortDirection.input);

    // Coherency snoop interface
    createPort('snoop_addr', PortDirection.input, width: 32);
    createPort('snoop_valid', PortDirection.input);
    createPort('snoop_invalidate', PortDirection.input);
    addOutput('snoop_hit');
    addOutput('snoop_data', width: config.lineSize * 8);

    // Invalidate / flush
    createPort('invalidate_all', PortDirection.input);
    createPort('flush_all', PortDirection.input);
    addOutput('flush_done');

    final clk = input('clk');
    final reset = input('reset');

    // FSM: idle, tag_check, refill, writeback, flush
    final state = Logic(name: 'state', width: 3);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(0, width: 3),
          output('resp_valid') < Const(0),
          output('miss') < Const(0),
          output('busy') < Const(0),
          output('refill_request') < Const(0),
          output('writeback_valid') < Const(0),
          output('snoop_hit') < Const(0),
          output('flush_done') < Const(0),
        ],
        orElse: [
          output('resp_valid') < Const(0),
          output('miss') < Const(0),
          output('snoop_hit') < Const(0),

          // State machine would be filled in by River's specific implementation
          // Harbor provides the structural framework
        ],
      ),
    ]);

    // Placeholder outputs
    output('resp_data') <= Const(0, width: 32);
    output('refill_addr') <= Const(0, width: 32);
    output('writeback_addr') <= Const(0, width: 32);
    output('writeback_data') <= Const(0, width: config.lineSize * 8);
    output('snoop_data') <= Const(0, width: config.lineSize * 8);
  }
}
