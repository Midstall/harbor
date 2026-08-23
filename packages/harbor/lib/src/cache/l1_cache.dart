import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../peripherals/register_file.dart';
import '../soc/target.dart';
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

  /// Owned (dirty, other shared copies may exist, MOESI only).
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

  /// Machine word width (RV32 = 32, RV64 = 64). One word is served per fetch.
  final int xlen;

  /// Second lookup port for dual-dispatch fetch: both lanes are served the same
  /// cycle when their (consecutive) addresses land in the same line, the
  /// bandwidth a single shared bus could not provide.
  final bool dualPort;

  /// Request port (from CPU fetch unit). The fetcher holds [reqAddr]/[reqValid]
  /// until [respValid]. A hit answers one cycle after the address is presented.
  Logic get reqAddr => input('req_addr');
  Logic get reqValid => input('req_valid');
  Logic get respData => output('resp_data');

  /// High for one cycle when the held request is served (hit). Doubles as the
  /// done handshake, the fetch unit re-reads until it sees this.
  Logic get respValid => output('resp_valid');
  Logic get miss => output('miss');

  /// Second lookup port (present only when [dualPort]).
  Logic get reqAddr1 => input('req_addr1');
  Logic get reqValid1 => input('req_valid1');
  Logic get respData1 => output('resp_data1');
  Logic get respValid1 => output('resp_valid1');

  /// Whole-cache flush (fence.i / satp change). Clears every valid bit in one
  /// cycle, since the cache is virtually addressed.
  Logic get flush => input('flush');

  /// Word-granular refill request to the MMU/memory. A miss fills its line one
  /// word per response, so the DDR PHY only ever sees the single paced read it
  /// captures correctly, never a back-to-back line burst.
  Logic get memEn => output('mem_en');
  Logic get memAddr => output('mem_addr');
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memRdata => input('mem_rdata');

  /// Instruction page fault from the fetch translation. Asserted with the refill
  /// response (done, not valid) when the MMU walk faulted. Without it a faulting
  /// refill leaves the fill FSM stalled forever, since it only completes on
  /// done AND valid.
  Logic get memFault => input('mem_fault');

  /// Fetch page fault to the pipeline. Held with resp done AND not valid for the
  /// faulting request, so the FetchUnit raises an instruction page fault instead
  /// of the cache hanging on a fill that can never complete.
  Logic get respFault => output('resp_fault');

  HarborL1ICache({
    required this.config,
    this.xlen = 64,
    this.dualPort = false,
    // Physical address bits the fetch stream can actually present. The tag store
    // and compares are sized to this instead of [xlen], so a tiny cache over a
    // <=32-bit memory map does not pay for a wide tag. Null = xlen.
    int? physAddrBits,
    // FPGA/ASIC target for the data block RAM. Null (simulation / std-cell) uses
    // the flop backend at the same forced read latency.
    HarborDeviceTarget? target,
    super.name = 'l1i',
  }) : super('HarborL1ICache') {
    if (config.ways != 1) {
      throw ArgumentError(
        'HarborL1ICache is direct-mapped (ways must be 1, got ${config.ways}).',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('req_addr', PortDirection.input, width: xlen);
    createPort('req_valid', PortDirection.input);
    createPort('flush', PortDirection.input);
    addOutput('resp_data', width: xlen);
    addOutput('resp_valid');
    addOutput('resp_fault');
    addOutput('miss');
    if (dualPort) {
      createPort('req_addr1', PortDirection.input, width: xlen);
      createPort('req_valid1', PortDirection.input);
      addOutput('resp_data1', width: xlen);
      addOutput('resp_valid1');
    }
    // Word-granular refill handshake to the MMU ifetch port.
    addOutput('mem_en');
    addOutput('mem_addr', width: xlen);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_rdata', PortDirection.input, width: xlen);
    createPort('mem_fault', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');

    final wordBytes = xlen ~/ 8;
    final lineWords = config.lineSize ~/ wordBytes;
    if (lineWords < 1) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must hold at least one $wordBytes-byte '
        'word.',
      );
    }
    final numLines = config.lines;
    final offBits = (lineWords - 1).bitLength; // word index within a line
    final idxBits = (numLines - 1).bitLength; // line index
    final byteBits = (wordBytes - 1).bitLength; // byte within a word
    final tagLo = byteBits + offBits + idxBits;
    final reqPa = physAddrBits ?? xlen;
    final paBits = reqPa > xlen ? xlen : reqPa;
    final tagBits = paBits - tagLo;

    Logic idxOf(Logic addr) => idxBits == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits + offBits);
    Logic tagOf(Logic addr) => addr.slice(paBits - 1, tagLo);
    // Combined {line, word} index into the flat data RAM.
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    // Per-line VALID + TAG in flops: valid must flush in one cycle, and the tag
    // compare is cheap. Read combinationally at the (registered) index.
    final lineValid = List.generate(numLines, (i) => Logic(name: 'valid_$i'));
    final lineTag = List.generate(
      numLines,
      (i) => Logic(name: 'tag_$i', width: tagBits),
    );

    // Balanced mux tree (log2(numLines) deep) when the line count is a power of
    // two; see the matching helper in HarborL1DCache. Replaces a numLines-deep
    // linear priority chain that was the core's FPGA timing-critical path.
    Logic muxLine(List<Logic> arr, Logic idx) {
      if (numLines > 1 && (numLines & (numLines - 1)) == 0) {
        var level = List<Logic>.from(arr);
        var bit = 0;
        while (level.length > 1) {
          final next = <Logic>[];
          for (var i = 0; i < level.length; i += 2) {
            next.add(mux(idx[bit], level[i + 1], level[i]));
          }
          level = next;
          bit++;
        }
        return level[0];
      }
      var r = arr[0];
      for (var i = 1; i < numLines; i++) {
        r = mux(idx.eq(i), arr[i], r);
      }
      return r;
    }

    // Per-line DATA in a block RAM (one read port, one write port for fills).
    // readLatency forced to 1 so the sim flop model behaves exactly like a
    // registered EBR read.
    final dataRam = HarborRegisterFile(
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: dualPort ? 2 : 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1i_data',
    );
    addSubModule(dataRam);
    dataRam.input('clk').srcConnection! <= clk;
    dataRam.input('reset').srcConnection! <= reset;
    dataRam.input('rd0_addr').srcConnection! <= dataEntryOf(reqAddr);
    if (dualPort) {
      dataRam.input('rd1_addr').srcConnection! <= dataEntryOf(reqAddr1);
    }

    // Miss/fill FSM state.
    final filling = Logic(name: 'filling');
    // A flush (fence.i) mid-fill abandons the in-flight refill, but the MMU
    // latched that read at arbitration and completes it regardless. `drain`
    // holds the cache off starting a new fill until that stale completion has
    // arrived and been discarded, so it can never land as word 0 of the next
    // line (the creek Weir->Ferrite handoff corruption).
    final drain = Logic(name: 'drain');
    // High for one cycle after a fill commits: the just-written entry was the
    // read-during-write target, so its registered read is only trustworthy the
    // cycle after. Gates the hit off for that settling cycle.
    final fillSettle = Logic(name: 'fillSettle');
    final fillIdx = Logic(name: 'fillIdx', width: idxBits == 0 ? 1 : idxBits);
    final fillTag = Logic(name: 'fillTag', width: tagBits);
    final fillBase = Logic(name: 'fillBase', width: xlen);
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );

    // Fetch-fault latch: set when a refill returns a page fault (mem_fault), held
    // until the requesting fetch retargets (the pipeline trapped and redirected).
    // While set for [faultAddr] it suppresses a fresh fill of that same line, so
    // the miss does not loop fill -> fault -> fill.
    final faultResp = Logic(name: 'faultResp');
    final faultAddr = Logic(name: 'faultAddr', width: xlen);

    // One-cycle-delayed copy of the request address: the block-RAM read launched
    // last cycle answers this cycle, so hit detection compares against it.
    final addrQ = Logic(name: 'addrQ', width: xlen);
    final addrQ1 = dualPort ? Logic(name: 'addrQ1', width: xlen) : null;

    final blockHit = (filling | fillSettle).named('blockHit');

    Logic committedHit(Logic a) =>
        muxLine(lineValid, idxOf(a)) & muxLine(lineTag, idxOf(a)).eq(tagOf(a));

    final ans = (reqValid & reqAddr.eq(addrQ)).named('ans');
    final hit = (ans & committedHit(addrQ) & ~blockHit).named('hit');
    final miss0 = (ans & ~committedHit(addrQ) & ~blockHit).named('miss0');
    final ans1 = dualPort
        ? (reqValid1 & reqAddr1.eq(addrQ1!)).named('ans1')
        : Const(0);
    final hit1 = dualPort
        ? (ans1 & committedHit(addrQ1!) & ~blockHit).named('hit1')
        : Const(0);
    final miss1 = dualPort
        ? (ans1 & ~committedHit(addrQ1!) & ~blockHit).named('miss1')
        : Const(0);
    // The faulting fetch is held by the FetchUnit at [faultAddr]; do not restart a
    // fill for it (it would just fault again), let respFault deliver the fault.
    final faultHeld = (faultResp & reqValid & reqAddr.eq(faultAddr)).named(
      'faultHeld',
    );
    // Port 0 has priority for starting a fill, fill from the missing port's held
    // (registered) address.
    final wantFill = ((miss0 | miss1) & ~faultHeld).named('wantFill');
    final fillAddr = mux(miss0, addrQ, dualPort ? addrQ1! : addrQ);

    final fillLineBase =
        fillAddr &
        ~Const((BigInt.one << (byteBits + offBits)) - BigInt.one, width: xlen);

    final memEnR = Logic(name: 'memEnR');
    final memAddrR = Logic(name: 'memAddrR', width: xlen);
    memEn <= memEnR;
    memAddr <= memAddrR;

    respData <= dataRam.readData(0);
    respValid <= hit;
    // A faulting fetch presents as done (in core.dart: done = respValid |
    // respFault) with valid low, so the FetchUnit raises the instruction page
    // fault instead of retrying. Gated to the held request so a stale latch never
    // faults an unrelated fetch.
    respFault <= faultHeld;
    miss <= miss0;
    if (dualPort) {
      respData1 <= dataRam.readData(1);
      respValid1 <= hit1;
    }

    // Data block-RAM write port: one fill word per MMU response.
    final fillWrEn = (filling & memDone & memValid).named('fillWrEn');
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].swizzle();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);

    Sequential(clk, [
      addrQ < reqAddr,
      if (dualPort) addrQ1! < reqAddr1,
      If(
        reset,
        then: [
          ...List.generate(numLines, (i) => lineValid[i] < 0),
          filling < 0,
          fillSettle < 0,
          memEnR < 0,
          drain < 0,
          faultResp < 0,
        ],
        orElse: [
          If(
            flush,
            then: [
              ...List.generate(numLines, (i) => lineValid[i] < 0),
              filling < 0,
              fillSettle < 0,
              memEnR < 0,
              faultResp < 0,
              // If a refill read is still outstanding to the MMU (filling, or
              // already draining a prior flush), keep draining until its stale
              // completion arrives, unless it completes this very cycle.
              drain < (filling | drain) & ~(memDone & memValid),
            ],
            orElse: [
              fillSettle < 0,
              // The pipeline trapped on the fault and redirected the fetch, so the
              // held request retargeted; drop the latch so a later miss can fill.
              If(faultResp & ~faultHeld, then: [faultResp < 0]),
              If(
                drain,
                then: [
                  // Waiting out the abandoned read. filling is 0 so its
                  // completion is never written; just release once it lands
                  // (data or fault, so a faulting stale read cannot hang drain).
                  If(memDone, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone & memValid,
                        then: [
                          If(
                            fillWord.eq(lastWord),
                            then: [
                              memEnR < 0,
                              filling < 0,
                              fillSettle < 1,
                              ...List.generate(
                                numLines,
                                (l) => If(
                                  fillIdx.eq(l),
                                  then: [
                                    lineValid[l] < 1,
                                    lineTag[l] < fillTag,
                                  ],
                                ),
                              ),
                            ],
                            orElse: [
                              fillWord < fillWord + 1,
                              memAddrR <
                                  (fillBase +
                                      ((fillWord + 1).zeroExtend(xlen) *
                                          Const(wordBytes, width: xlen))),
                            ],
                          ),
                        ],
                        // done AND not valid: the MMU fetch walk page-faulted
                        // (mem_fault). Stop the fill (never mark the line valid)
                        // and latch the fault so respFault delivers it to the
                        // pipeline. Without this the fill FSM stalls forever.
                        orElse: [
                          If(
                            memDone,
                            then: [memEnR < 0, filling < 0, faultResp < 1],
                          ),
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        wantFill,
                        then: [
                          filling < 1,
                          fillIdx < idxOf(fillAddr),
                          fillTag < tagOf(fillAddr),
                          fillBase < fillLineBase,
                          fillWord < 0,
                          memEnR < 1,
                          memAddrR < fillLineBase,
                          // Remember the exact request address this fill serves;
                          // if it faults, respFault is gated to a held request at
                          // this address so a stale latch never faults another
                          // fetch.
                          faultAddr < fillAddr,
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}

/// Synthesizable L1 data cache: direct-mapped, write-through, no-write-allocate.
///
/// The load path is the [HarborL1ICache] path, a miss fills its line one paced
/// word at a time so the DDR PHY only ever sees the single reads it captures
/// correctly, then held loads hit out of the block RAM. That pacing is the whole
/// reason the cache exists: it isolates the data-load stream from back-to-back
/// bursts the marginal PHY mis-captures.
///
/// Stores are write-through with no write-allocate: the store goes straight to
/// memory through the same verified write path, and if its line is resident the
/// line is invalidated (a following load re-fills it, paced). This keeps the
/// cached copy coherent without any sub-word merge or dirty-line eviction burst,
/// stores already work on this hardware. The cache is here to pace loads.
class HarborL1DCache extends BridgeModule {
  /// Cache configuration.
  final HarborCacheConfig config;

  /// Machine word width (RV32 = 32, RV64 = 64).
  final int xlen;

  /// Lowest cacheable address. Only accesses at or above this are cached, every
  /// access below it (MMIO devices, boot SRAM, flash) is passed straight through
  /// to memory uncached. Caching MMIO is a correctness bug: a cached UART status
  /// register would read a stale ready bit forever and hang the first putchar.
  /// Defaults to the RISC-V DRAM base (0x80000000), which is exactly the region
  /// whose reads need pacing.
  final int cacheableBase;

  /// Request port (from the load/store unit). [reqWrite] selects store.
  Logic get reqAddr => input('req_addr');
  Logic get reqValid => input('req_valid');
  Logic get reqWrite => input('req_write');
  Logic get reqData => input('req_data');
  Logic get reqSize => input('req_size');
  Logic get respData => output('resp_data');

  /// High for one cycle when the op completes: a load hit/fill-done, or a store
  /// once memory acknowledges the write.
  Logic get respValid => output('resp_valid');
  Logic get miss => output('miss');
  Logic get busy => output('busy');

  /// Whole-cache flush.
  Logic get flush => input('flush');

  /// Word-granular memory port (shared by load fills and write-through stores).
  Logic get memEn => output('mem_en');
  Logic get memWe => output('mem_we');
  Logic get memAddr => output('mem_addr');
  Logic get memWdata => output('mem_wdata');
  Logic get memSize => output('mem_size');
  Logic get memDone => input('mem_done');
  Logic get memValid => input('mem_valid');
  Logic get memRdata => input('mem_rdata');

  HarborL1DCache({
    required this.config,
    this.xlen = 64,
    this.cacheableBase = 0x80000000,
    int? physAddrBits,
    HarborDeviceTarget? target,
    super.name = 'l1d',
  }) : super('HarborL1DCache') {
    if (config.ways != 1) {
      throw ArgumentError(
        'HarborL1DCache is direct-mapped (ways must be 1, got ${config.ways}).',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('req_addr', PortDirection.input, width: xlen);
    createPort('req_valid', PortDirection.input);
    createPort('req_write', PortDirection.input);
    createPort('req_data', PortDirection.input, width: xlen);
    createPort('req_size', PortDirection.input, width: 3);
    createPort('flush', PortDirection.input);
    addOutput('resp_data', width: xlen);
    addOutput('resp_valid');
    addOutput('miss');
    addOutput('busy');
    // Word-granular memory port.
    addOutput('mem_en');
    addOutput('mem_we');
    addOutput('mem_addr', width: xlen);
    addOutput('mem_wdata', width: xlen);
    addOutput('mem_size', width: 3);
    createPort('mem_done', PortDirection.input);
    createPort('mem_valid', PortDirection.input);
    createPort('mem_rdata', PortDirection.input, width: xlen);

    final clk = input('clk');
    final reset = input('reset');

    final wordBytes = xlen ~/ 8;
    final lineWords = config.lineSize ~/ wordBytes;
    if (lineWords < 1) {
      throw ArgumentError(
        'lineSize (${config.lineSize}B) must hold at least one $wordBytes-byte '
        'word.',
      );
    }
    final numLines = config.lines;
    final offBits = (lineWords - 1).bitLength;
    final idxBits = (numLines - 1).bitLength;
    final byteBits = (wordBytes - 1).bitLength;
    final tagLo = byteBits + offBits + idxBits;
    final reqPa = physAddrBits ?? xlen;
    final paBits = reqPa > xlen ? xlen : reqPa;
    final tagBits = paBits - tagLo;

    Logic idxOf(Logic addr) => idxBits == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits + offBits);
    Logic tagOf(Logic addr) => addr.slice(paBits - 1, tagLo);
    Logic dataEntryOf(Logic addr) => (offBits + idxBits) == 0
        ? Const(0, width: 1)
        : addr.slice(byteBits + offBits + idxBits - 1, byteBits);

    final lineValid = List.generate(numLines, (i) => Logic(name: 'valid_$i'));
    final lineTag = List.generate(
      numLines,
      (i) => Logic(name: 'tag_$i', width: tagBits),
    );

    // Select arr[idx]. A balanced mux tree (log2(numLines) deep) when the line
    // count is a power of two, folding pairs on one index bit per level. The
    // old linear `mux(idx.eq(i), arr[i], r)` chain was numLines muxes deep and,
    // run twice (valid + tag) into the tag compare, was the core's FPGA timing-
    // critical path. Falls back to the linear form for a non-power-of-two count.
    Logic muxLine(List<Logic> arr, Logic idx) {
      if (numLines > 1 && (numLines & (numLines - 1)) == 0) {
        var level = List<Logic>.from(arr);
        var bit = 0;
        while (level.length > 1) {
          final next = <Logic>[];
          for (var i = 0; i < level.length; i += 2) {
            next.add(mux(idx[bit], level[i + 1], level[i]));
          }
          level = next;
          bit++;
        }
        return level[0];
      }
      var r = arr[0];
      for (var i = 1; i < numLines; i++) {
        r = mux(idx.eq(i), arr[i], r);
      }
      return r;
    }

    Logic committedHitOf(Logic a) =>
        muxLine(lineValid, idxOf(a)) & muxLine(lineTag, idxOf(a)).eq(tagOf(a));

    final dataRam = HarborRegisterFile(
      numEntries: numLines * lineWords,
      dataWidth: xlen,
      numReadPorts: 1,
      numWritePorts: 1,
      reservedZero: false,
      target: target,
      forceReadLatency: 1,
      name: 'l1d_data',
    );
    addSubModule(dataRam);
    dataRam.input('clk').srcConnection! <= clk;
    dataRam.input('reset').srcConnection! <= reset;
    dataRam.input('rd0_addr').srcConnection! <= dataEntryOf(reqAddr);

    // FSM state.
    final filling = Logic(name: 'filling');
    final fillSettle = Logic(name: 'fillSettle');
    // Drain an abandoned in-flight memory op after a flush (fence.i) mid-fill/
    // store/bypass: the MMU completes the read/write it already launched, so
    // block a new op until that stale completion lands and is discarded. Without
    // this, a post-flush fill captures the abandoned read as word 0 of the new
    // line (the creek Weir->Ferrite handoff corruption). Mirrors [HarborL1ICache].
    final drain = Logic(name: 'drain');
    final storing = Logic(name: 'storing');
    final storeDone = Logic(name: 'storeDone');
    // Uncached-read pass-through (MMIO / SRAM / flash): a single memory read
    // whose data is returned directly, never written into the cache.
    final bypassing = Logic(name: 'bypassing');
    final bypassDone = Logic(name: 'bypassDone');
    final bypassData = Logic(name: 'bypassData', width: xlen);
    final fillIdx = Logic(name: 'fillIdx', width: idxBits == 0 ? 1 : idxBits);
    final fillTag = Logic(name: 'fillTag', width: tagBits);
    final fillBase = Logic(name: 'fillBase', width: xlen);
    final fillWord = Logic(
      name: 'fillWord',
      width: (offBits == 0 ? 1 : offBits) + 1,
    );
    final storeIdx = Logic(name: 'storeIdx', width: idxBits == 0 ? 1 : idxBits);
    final storeInv = Logic(name: 'storeInv');

    final addrQ = Logic(name: 'addrQ', width: xlen);
    // Also block on the completion pulses (storeDone / bypassDone / fillSettle):
    // the pipeline holds its request one cycle past `done`, so without this the
    // FSM would re-issue the SAME op the cycle it finishes. A back-to-back
    // request like that deadlocks the DRAM CDC bridge (which needs cyc to drop
    // between transactions), the on-hardware hang the instant-memory unit test
    // could not surface.
    final blockHit =
        (filling | fillSettle | storing | bypassing | storeDone | bypassDone)
            .named('blockHit');

    // Only DRAM (>= cacheableBase) is cacheable, everything else bypasses.
    Logic cacheableOf(Logic a) => a.gte(Const(cacheableBase, width: xlen));

    // Loads. A store never uses the hit/fill path (no write-allocate).
    final loadEn = (reqValid & ~reqWrite).named('loadEn');
    final ansLoad = (loadEn & reqAddr.eq(addrQ)).named('ansLoad');
    final cacheableQ = cacheableOf(addrQ).named('cacheableQ');
    final loadHit = (ansLoad & cacheableQ & committedHitOf(addrQ) & ~blockHit)
        .named('loadHit');
    final loadMiss = (ansLoad & cacheableQ & ~committedHitOf(addrQ) & ~blockHit)
        .named('loadMiss');
    // Uncacheable load: pass straight through to memory, do not allocate.
    final loadBypass = (ansLoad & ~cacheableQ & ~blockHit).named('loadBypass');
    final storeReq = (reqValid & reqWrite).named('storeReq');

    final fillLineBase =
        addrQ &
        ~Const((BigInt.one << (byteBits + offBits)) - BigInt.one, width: xlen);

    final memEnR = Logic(name: 'memEnR');
    final memWeR = Logic(name: 'memWeR');
    final memAddrR = Logic(name: 'memAddrR', width: xlen);
    final memWdataR = Logic(name: 'memWdataR', width: xlen);
    final memSizeR = Logic(name: 'memSizeR', width: 3);
    memEn <= memEnR;
    memWe <= memWeR;
    memAddr <= memAddrR;
    memWdata <= memWdataR;
    memSize <= memSizeR;

    // The data path expects the addressed sub-word in lane 0: the MMU dport
    // right-shifts an aligned bus read by (byteOffset*8) so `lw`/`lbu` land in
    // lane 0 (the ifetch path stays raw, the fetch unit extracts itself). The
    // cache holds the RAW aligned line word, so a hit must apply the same shift.
    // A bypass read used the EXACT address, so the MMU already shifted it, do not
    // shift again.
    final rdShift = byteBits == 0
        ? Const(0, width: 1)
        : [addrQ.slice(byteBits - 1, 0), Const(0, width: 3)].swizzle();
    respData <= mux(bypassDone, bypassData, dataRam.readData(0) >> rdShift);
    respValid <= (loadHit | storeDone | bypassDone);
    miss <= loadMiss;
    busy <= (filling | storing | bypassing | drain);

    final fillWrEn = (filling & memDone & memValid).named('fillWrEn');
    final Logic fillEntry;
    if (offBits == 0) {
      fillEntry = fillIdx;
    } else if (idxBits == 0) {
      fillEntry = fillWord.slice(offBits - 1, 0);
    } else {
      fillEntry = [fillIdx, fillWord.slice(offBits - 1, 0)].swizzle();
    }
    dataRam.input('wr_en').srcConnection! <= fillWrEn;
    dataRam.input('wr_addr').srcConnection! <= fillEntry;
    dataRam.input('wr_data').srcConnection! <= memRdata;

    final lastWord = Const(lineWords - 1, width: fillWord.width);

    Sequential(clk, [
      addrQ < reqAddr,
      If(
        reset,
        then: [
          ...List.generate(numLines, (i) => lineValid[i] < 0),
          filling < 0,
          fillSettle < 0,
          storing < 0,
          storeDone < 0,
          bypassing < 0,
          bypassDone < 0,
          memEnR < 0,
          memWeR < 0,
          drain < 0,
        ],
        orElse: [
          If(
            flush,
            then: [
              ...List.generate(numLines, (i) => lineValid[i] < 0),
              filling < 0,
              fillSettle < 0,
              storing < 0,
              storeDone < 0,
              bypassing < 0,
              bypassDone < 0,
              memEnR < 0,
              memWeR < 0,
              // Any in-flight memory op (fill/store/bypass) was launched at the
              // MMU and will still complete; drain that stale completion before a
              // new op, unless it completes this very cycle.
              drain < (filling | storing | bypassing | drain) & ~memDone,
            ],
            orElse: [
              fillSettle < 0,
              storeDone < 0,
              bypassDone < 0,
              If(
                drain,
                then: [
                  // Waiting out the abandoned op; discard its completion (filling
                  // is 0 so nothing is written) and release.
                  If(memDone, then: [drain < 0]),
                ],
                orElse: [
                  If(
                    filling,
                    then: [
                      If(
                        memDone & memValid,
                        then: [
                          If(
                            fillWord.eq(lastWord),
                            then: [
                              memEnR < 0,
                              filling < 0,
                              fillSettle < 1,
                              ...List.generate(
                                numLines,
                                (l) => If(
                                  fillIdx.eq(l),
                                  then: [
                                    lineValid[l] < 1,
                                    lineTag[l] < fillTag,
                                  ],
                                ),
                              ),
                            ],
                            orElse: [
                              fillWord < fillWord + 1,
                              memAddrR <
                                  (fillBase +
                                      ((fillWord + 1).zeroExtend(xlen) *
                                          Const(wordBytes, width: xlen))),
                            ],
                          ),
                        ],
                      ),
                    ],
                    orElse: [
                      If(
                        storing,
                        then: [
                          // Write-through in flight: wait for the memory ack, then drop
                          // the resident line if the store landed on it.
                          If(
                            memDone,
                            then: [
                              memEnR < 0,
                              memWeR < 0,
                              storing < 0,
                              storeDone < 1,
                              ...List.generate(
                                numLines,
                                (l) => If(
                                  storeInv & storeIdx.eq(l),
                                  then: [lineValid[l] < 0],
                                ),
                              ),
                            ],
                          ),
                        ],
                        orElse: [
                          If(
                            bypassing,
                            then: [
                              // Uncached read in flight: return the word, cache untouched.
                              If(
                                memDone & memValid,
                                then: [
                                  memEnR < 0,
                                  bypassing < 0,
                                  bypassDone < 1,
                                  bypassData < memRdata,
                                ],
                              ),
                            ],
                            orElse: [
                              // Idle. Store (write-through) has priority, then a cacheable
                              // load miss (fill), then an uncacheable load (bypass). The
                              // core presents at most one of these per cycle. Gate the
                              // store start on ~blockHit too, so the completion-cycle
                              // block above also stops a store from re-issuing.
                              If(
                                storeReq & ~blockHit,
                                then: [
                                  storing < 1,
                                  memEnR < 1,
                                  memWeR < 1,
                                  memAddrR < reqAddr,
                                  memWdataR < reqData,
                                  memSizeR < reqSize,
                                  storeIdx < idxOf(reqAddr),
                                  storeInv <
                                      (committedHitOf(reqAddr) &
                                          cacheableOf(reqAddr)),
                                ],
                                orElse: [
                                  If(
                                    loadMiss,
                                    then: [
                                      filling < 1,
                                      memEnR < 1,
                                      memWeR < 0,
                                      // Read a FULL word per fill beat. wordBytes
                                      // is 8 on RV64, so the size must be 3 (8
                                      // bytes), not a hardcoded 2 (4 bytes) which
                                      // left the upper half of every 64-bit line
                                      // word undefined.
                                      memSizeR <
                                          Const(
                                            wordBytes.bitLength - 1,
                                            width: 3,
                                          ),
                                      fillIdx < idxOf(addrQ),
                                      fillTag < tagOf(addrQ),
                                      fillBase < fillLineBase,
                                      fillWord < 0,
                                      memAddrR < fillLineBase,
                                    ],
                                    orElse: [
                                      If(
                                        loadBypass,
                                        then: [
                                          bypassing < 1,
                                          memEnR < 1,
                                          memWeR < 0,
                                          memSizeR < Const(2, width: 3),
                                          memAddrR < addrQ,
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
