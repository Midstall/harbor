import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ice40/ice40.dart';
import '../soc/target.dart';

/// A configurable multi-read / multi-write register file.
///
/// The default shape is 2-read / 1-write, which maps directly onto a single
/// storage primitive (an iCE40 EBR on FPGA, a flop array in simulation) and is
/// what the FP and vector register files use. Dual-issue cores raise
/// [numReadPorts] (one rs1+rs2 pair per dispatched instruction) and
/// [numWritePorts] (one per committed instruction).
///
/// A real single-write-port storage primitive (block RAM, compiled macro)
/// cannot accept two writes in the same cycle. To get multi-write behaviour
/// the file is split into [numBanks] banks selected by the low bits of the
/// register index. Writes to distinct banks proceed in parallel. Two writes
/// that collide on the same bank are arbitrated: the older (lower-indexed)
/// write port is serviced and the younger is back-pressured via its
/// `wr*_ready` output, the consumer (e.g. the OoO commit stage) must hold that
/// write and retry next cycle. A write-after-write to the *same* register in
/// the same cycle is special-cased: the youngest writer's value wins and both
/// ports report ready. (A configurable per-bank write buffer to absorb
/// conflicts without stalling is planned via [writeBufferDepth]; depth 0, the
/// default, is the pure stall-on-conflict arbiter.)
///
/// Because the banking/arbitration logic is the same RTL across backends, a
/// simulation faithfully models the FPGA/ASIC conflict stalls.
///
/// Reads of entry 0 always return zero (RISC-V x0); writes to entry 0 are
/// dropped (the caller need not suppress them, though it typically does).
///
/// Port names preserve backwards compatibility: with a single write port the
/// ports are `wr_en`/`wr_addr`/`wr_data` (plus a `wr_ready` that is always
/// asserted); with multiple write ports they are `wr{w}_en`/`wr{w}_addr`/
/// `wr{w}_data`/`wr{w}_ready`. Read ports are always `rd{r}_addr`/`rd{r}_data`.
class HarborRegisterFile extends BridgeModule {
  final int numEntries;
  final int dataWidth;
  final int addrWidth;
  final int numReadPorts;
  final int numWritePorts;
  final int numBanks;
  final int writeBufferDepth;

  /// Number of address bits that select the bank (low bits of the register
  /// index). Zero when there is a single bank.
  int get _bankBits => numBanks <= 1 ? 0 : (numBanks - 1).bitLength;

  Logic readData(int r) => output('rd${r}_data');

  /// Back-compat getters for the default 2-read shape.
  Logic get rd0Data => output('rd0_data');
  Logic get rd1Data => output('rd1_data');

  /// Ready (write-accepted) output for write port [w]. With a single write
  /// port this is the always-asserted `wr_ready`.
  Logic writeReady(int w) => output(_wrName(w, 'ready'));

  String _wrName(int w, String suffix) =>
      numWritePorts == 1 ? 'wr_$suffix' : 'wr${w}_$suffix';

  /// Flop storage, present only in the simulation/non-BRAM model. A flat array
  /// of [numEntries]; banking constrains only the write arbiter, not the
  /// physical layout (flops are naturally multi-read/multi-write).
  List<Logic>? _storage;

  /// Testbench hook to read an entry's value (simulation model only).
  LogicValue? getData(LogicValue addr) => _storage?[addr.toInt()].value;

  HarborRegisterFile({
    this.numEntries = 32,
    this.dataWidth = 32,
    this.numReadPorts = 2,
    this.numWritePorts = 1,
    this.numBanks = 1,
    this.writeBufferDepth = 0,
    HarborDeviceTarget? target,
    String? name,
  }) : addrWidth = numEntries > 1 ? (numEntries - 1).bitLength : 1,
       super(
         'HarborRegisterFile_E${numEntries}_W${dataWidth}_'
         'R${numReadPorts}_W${numWritePorts}_B$numBanks',
         name: name ?? 'regfile',
       ) {
    if (numReadPorts < 1) {
      throw ArgumentError('numReadPorts must be >= 1 (got $numReadPorts).');
    }
    if (numWritePorts < 1) {
      throw ArgumentError('numWritePorts must be >= 1 (got $numWritePorts).');
    }
    if (numBanks < 1 || (numBanks & (numBanks - 1)) != 0) {
      throw ArgumentError('numBanks must be a power of two (got $numBanks).');
    }
    if (numEntries % numBanks != 0) {
      throw ArgumentError(
        'numEntries ($numEntries) must be divisible by numBanks ($numBanks).',
      );
    }
    if (writeBufferDepth < 0) {
      throw ArgumentError(
        'writeBufferDepth must be >= 0 (got $writeBufferDepth).',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    for (var r = 0; r < numReadPorts; r++) {
      createPort('rd${r}_addr', PortDirection.input, width: addrWidth);
      createPort('rd${r}_data', PortDirection.output, width: dataWidth);
    }
    for (var w = 0; w < numWritePorts; w++) {
      createPort(_wrName(w, 'en'), PortDirection.input);
      createPort(_wrName(w, 'addr'), PortDirection.input, width: addrWidth);
      createPort(_wrName(w, 'data'), PortDirection.input, width: dataWidth);
      createPort(_wrName(w, 'ready'), PortDirection.output);
    }

    final clk = input('clk');
    final reset = input('reset');
    final rdAddrs = [
      for (var r = 0; r < numReadPorts; r++) input('rd${r}_addr'),
    ];
    final rdDatas = [for (var r = 0; r < numReadPorts; r++) readData(r)];
    final wrEns = [
      for (var w = 0; w < numWritePorts; w++) input(_wrName(w, 'en')),
    ];
    final wrAddrs = [
      for (var w = 0; w < numWritePorts; w++) input(_wrName(w, 'addr')),
    ];
    final wrDatas = [
      for (var w = 0; w < numWritePorts; w++) input(_wrName(w, 'data')),
    ];
    final wrReadys = [for (var w = 0; w < numWritePorts; w++) writeReady(w)];

    final isEbr =
        target is HarborFpgaTarget && target.vendor == HarborFpgaVendor.ice40;

    if (isEbr) {
      if (numWritePorts != 1 || numBanks != 1) {
        // Banked multi-write EBR is project_hdl_dualissue Phase 2.
        throw UnimplementedError(
          'iCE40 EBR backend currently supports a single write port and a '
          'single bank (got numWritePorts=$numWritePorts, numBanks=$numBanks).',
        );
      }
      _buildIce40Ebr(clk, rdAddrs, rdDatas, wrEns[0], wrAddrs[0], wrDatas[0]);
      wrReadys[0] <= Const(1);
    } else if (writeBufferDepth > 0 && numWritePorts > 1) {
      // A single write port never collides, so the buffer is only built for
      // multi-write configs. Implemented for the 2-write-port case (IssueWidth
      // caps commit width at 2).
      if (numWritePorts != 2) {
        throw UnimplementedError(
          'write buffer is implemented for numWritePorts==2 '
          '(got $numWritePorts).',
        );
      }
      _buildBankedFlopBuffered(
        clk,
        reset,
        rdAddrs,
        rdDatas,
        wrEns,
        wrAddrs,
        wrDatas,
        wrReadys,
      );
    } else {
      _buildBankedFlop(
        clk,
        reset,
        rdAddrs,
        rdDatas,
        wrEns,
        wrAddrs,
        wrDatas,
        wrReadys,
      );
    }
  }

  /// Bank index (low [_bankBits] of the register address).
  Logic _bankOf(Logic addr) =>
      _bankBits == 0 ? Const(0, width: 1) : addr.slice(_bankBits - 1, 0);

  /// iCE40 EBR-backed storage. One SB_RAM40_4K copy per read port (the EBR is
  /// single-read-port), `ceil(dataWidth/16)` wide. Read clock is inverted so
  /// the registered read completes mid-cycle. Single write port, single bank.
  void _buildIce40Ebr(
    Logic clk,
    List<Logic> rdAddrs,
    List<Logic> rdDatas,
    Logic wrEn,
    Logic wrAddr,
    Logic wrData,
  ) {
    const ebrWidth = 16;
    const ebrAddrBits = 11;
    final widthEbrs = (dataWidth + ebrWidth - 1) ~/ ebrWidth;

    final wrAddrExt = wrAddr.zeroExtend(ebrAddrBits);

    for (var r = 0; r < rdAddrs.length; r++) {
      final rdAddrExt = rdAddrs[r].zeroExtend(ebrAddrBits);
      final slices = <Logic>[];

      for (var w = 0; w < widthEbrs; w++) {
        final lo = w * ebrWidth;
        final hi = (lo + ebrWidth) > dataWidth ? dataWidth : lo + ebrWidth;
        final sliceWidth = hi - lo;

        // Negative-edge-read EBR: read completes mid-cycle so it appears
        // combinational to the posedge pipeline, while staying in the clk
        // domain (RCLK = clk, the falling edge is internal), phase-related,
        // so the read of a posedge-launched address is timed correctly.
        final ebr = Ice40SbRam40_4kNR(name: 'ebr_r${r}_w$w');
        addSubModule(ebr);

        // Write port (posedge).
        ebr.input('WCLK').srcConnection! <= clk;
        ebr.input('WCLKE').srcConnection! <= Const(1);
        ebr.input('WE').srcConnection! <= wrEn;
        ebr.input('WADDR').srcConnection! <= wrAddrExt;
        ebr.input('WDATA').srcConnection! <=
            wrData.getRange(lo, hi).zeroExtend(ebrWidth);
        // MASK is a no-write mask. 0 writes every bit.
        ebr.input('MASK').srcConnection! <= Const(0, width: ebrWidth);

        // Read port (negedge of clk, internal to the NR primitive, whose read
        // clock port is RCLKN).
        ebr.input('RCLKN').srcConnection! <= clk;
        ebr.input('RCLKE').srcConnection! <= Const(1);
        ebr.input('RE').srcConnection! <= Const(1);
        ebr.input('RADDR').srcConnection! <= rdAddrExt;

        slices.add(ebr.output('RDATA').getRange(0, sliceWidth));
      }

      final raw = slices.length == 1
          ? slices.first.zeroExtend(dataWidth)
          : slices.rswizzle().getRange(0, dataWidth);

      // x0 reads as zero.
      rdDatas[r] <=
          mux(
            rdAddrs[r].eq(Const(0, width: addrWidth)),
            Const(0, width: dataWidth),
            raw,
          );
    }
  }

  /// Flop array with combinational read plus the backend-independent write
  /// arbiter (banking + stall-on-conflict). Used for simulation and ASIC
  /// std-cell targets.
  void _buildBankedFlop(
    Logic clk,
    Logic reset,
    List<Logic> rdAddrs,
    List<Logic> rdDatas,
    List<Logic> wrEns,
    List<Logic> wrAddrs,
    List<Logic> wrDatas,
    List<Logic> wrReadys,
  ) {
    final storage = List<Logic>.generate(
      numEntries,
      (i) => Logic(name: 'reg_$i', width: dataWidth),
    );
    _storage = storage;

    final zeroAddr = Const(0, width: addrWidth);
    final zeroData = Const(0, width: dataWidth);

    // Per write port, whether it targets bank b this cycle.
    List<Logic> enToBank(int b) => [
      for (var w = 0; w < numWritePorts; w++)
        numBanks == 1
            ? wrEns[w]
            : (wrEns[w] & _bankOf(wrAddrs[w]).eq(Const(b, width: _bankBits)))
                  .named('en_w${w}_b$b'),
    ];

    // Per-bank arbitration result.
    final bankWinAddr = <Logic>[]; // serviced address (oldest writer's addr)
    final bankWinData = <Logic>[]; // value to write (youngest with that addr)
    final bankWinEn = <Logic>[]; // any write to this bank
    final perBankEn = <List<Logic>>[];

    for (var b = 0; b < numBanks; b++) {
      final en = enToBank(b);
      perBankEn.add(en);

      // Serviced address: oldest (lowest-indexed) enabled writer wins. Apply
      // ports high→low so the lowest index is applied last and takes priority.
      var winAddr = zeroAddr as Logic;
      for (var w = numWritePorts - 1; w >= 0; w--) {
        winAddr = mux(en[w], wrAddrs[w], winAddr);
      }
      winAddr = winAddr.named('bankWinAddr_$b');
      bankWinAddr.add(winAddr);

      // Value: youngest (highest-indexed) writer whose address matches the
      // serviced address wins (write-after-write to the same register).
      var winData = zeroData as Logic;
      for (var w = 0; w < numWritePorts; w++) {
        final sel = (en[w] & wrAddrs[w].eq(winAddr)).named('winsel_w${w}_b$b');
        winData = mux(sel, wrDatas[w], winData);
      }
      bankWinData.add(winData.named('bankWinData_$b'));

      var any = en[0];
      for (var w = 1; w < numWritePorts; w++) {
        any = any | en[w];
      }
      bankWinEn.add(any.named('bankWinEn_$b'));
    }

    // Ready/back-pressure: a write port is accepted when it is not requesting,
    // or its address equals the serviced address of its bank (so the oldest
    // distinct-address writer and any same-address writers are accepted. A
    // younger writer to a different address in the same bank is stalled).
    for (var w = 0; w < numWritePorts; w++) {
      Logic servicedForPort;
      if (numBanks == 1) {
        servicedForPort = bankWinAddr[0];
      } else {
        servicedForPort = bankWinAddr[0];
        final bankSel = _bankOf(wrAddrs[w]);
        for (var b = 1; b < numBanks; b++) {
          servicedForPort = mux(
            bankSel.eq(Const(b, width: _bankBits)),
            bankWinAddr[b],
            servicedForPort,
          );
        }
      }
      wrReadys[w] <=
          (~wrEns[w] | wrAddrs[w].eq(servicedForPort)).named('wrReady_$w');
    }

    // Storage update: each entry follows its bank's winning write. Entry 0
    // (x0) is never stored.
    Sequential(clk, [
      If(
        reset,
        then: [for (final reg in storage) reg < zeroData],
        orElse: [
          for (var entry = 1; entry < numEntries; entry++)
            If(
              bankWinEn[entry % numBanks] &
                  bankWinAddr[entry % numBanks].eq(
                    Const(entry, width: addrWidth),
                  ),
              then: [storage[entry] < bankWinData[entry % numBanks]],
            ),
        ],
      ),
    ]);

    // Combinational reads (x0 reads zero). Banking does not constrain reads in
    // the flop model.
    Combinational([
      for (var r = 0; r < rdAddrs.length; r++)
        Case(
          rdAddrs[r],
          [
            for (var entry = 1; entry < numEntries; entry++)
              CaseItem(Const(entry, width: addrWidth), [
                rdDatas[r] < storage[entry],
              ]),
          ],
          defaultItem: [rdDatas[r] < zeroData],
        ),
    ]);
  }

  /// Flop array with per-bank write buffers (depth [writeBufferDepth]). A
  /// same-bank collision, or any write to a bank whose buffer is still
  /// draining, is enqueued instead of stalled. Each bank pops one buffered
  /// write per cycle into storage, and reads bypass pending buffered values so
  /// a committed-but-undrained write stays visible the next cycle (matching the
  /// zero-latency direct-write path). A port stalls (`ready=0`) only when its
  /// bank's buffer is full. The buffer is a packed FIFO (index 0 = oldest).
  /// Implemented for the two-write-port case.
  void _buildBankedFlopBuffered(
    Logic clk,
    Logic reset,
    List<Logic> rdAddrs,
    List<Logic> rdDatas,
    List<Logic> wrEns,
    List<Logic> wrAddrs,
    List<Logic> wrDatas,
    List<Logic> wrReadys,
  ) {
    final d = writeBufferDepth;
    final w = (d + 1).bitLength; // holds a count in [0, d]
    final zeroAddr = Const(0, width: addrWidth);
    final zeroData = Const(0, width: dataWidth);

    final storage = List<Logic>.generate(
      numEntries,
      (i) => Logic(name: 'reg_$i', width: dataWidth),
    );
    _storage = storage;

    Logic enOf(int port, int b) => numBanks == 1
        ? wrEns[port]
        : (wrEns[port] & _bankOf(wrAddrs[port]).eq(Const(b, width: _bankBits)))
              .named('en_w${port}_b$b');

    // Per-bank registered FIFO state + per-bank storage write command.
    final bankWrEn = <Logic>[];
    final bankWrAddr = <Logic>[];
    final bankWrData = <Logic>[];
    // Buffer state, kept for read bypass.
    final bufV = <List<Logic>>[];
    final bufA = <List<Logic>>[];
    final bufD = <List<Logic>>[];

    final port0Ready = <Logic>[];
    final port1Ready = <Logic>[];

    for (var b = 0; b < numBanks; b++) {
      final v = [for (var i = 0; i < d; i++) Logic(name: 'bufV_b${b}_$i')];
      final a = [
        for (var i = 0; i < d; i++)
          Logic(name: 'bufA_b${b}_$i', width: addrWidth),
      ];
      final da = [
        for (var i = 0; i < d; i++)
          Logic(name: 'bufD_b${b}_$i', width: dataWidth),
      ];
      bufV.add(v);
      bufA.add(a);
      bufD.add(da);

      final en0 = enOf(0, b);
      final en1 = enOf(1, b);
      final pop = v[0]; // packed: head valid iff non-empty

      // Survivors after popping the head (shift down by one).
      final surV = [
        for (var i = 0; i < d; i++)
          mux(pop, i + 1 < d ? v[i + 1] : Const(0), v[i]),
      ];
      final surA = [
        for (var i = 0; i < d; i++)
          mux(pop, i + 1 < d ? a[i + 1] : zeroAddr, a[i]),
      ];
      final surD = [
        for (var i = 0; i < d; i++)
          mux(pop, i + 1 < d ? da[i + 1] : zeroData, da[i]),
      ];
      Logic sc = Const(0, width: w);
      for (var i = 0; i < d; i++) {
        sc = (sc + surV[i].zeroExtend(w)).named('sc_b${b}_$i');
      }
      sc = sc.named('survCount_b$b');
      final scLtD = sc.lt(Const(d, width: w)); // slot sc fits
      final scLtDm1 = sc.lt(Const(d - 1, width: w)); // slot sc+1 fits

      // Bank storage write: pop the head, else the oldest incoming directly.
      final hasIncoming = en0 | en1;
      bankWrEn.add((pop | hasIncoming).named('bankWrEn_$b'));
      bankWrAddr.add(mux(pop, a[0], mux(en0, wrAddrs[0], wrAddrs[1])));
      bankWrData.add(mux(pop, da[0], mux(en0, wrDatas[0], wrDatas[1])));

      // Entries to buffer this cycle. port0 (older) is buffered only if it
      // can't write direct (i.e. we popped); port1 is buffered if popping or
      // if port0 also took the bank.
      final appended0 = (en0 & pop).named('appended0_b$b');
      final appended1 = (en1 & (pop | en0)).named('appended1_b$b');
      final e0Present = appended0 | appended1;
      final e0Addr = mux(appended0, wrAddrs[0], wrAddrs[1]);
      final e0Data = mux(appended0, wrDatas[0], wrDatas[1]);
      final e0Acc = e0Present & scLtD;
      final e1Present = appended0 & appended1; // both → second entry is port1
      final e1Acc = e1Present & scLtDm1;

      final nextV = <Logic>[];
      final nextA = <Logic>[];
      final nextD = <Logic>[];
      for (var j = 0; j < d; j++) {
        final placeE0 = (e0Acc & sc.eq(Const(j, width: w))).named(
          'pe0_b${b}_$j',
        );
        final placeE1 = j >= 1
            ? (e1Acc & sc.eq(Const(j - 1, width: w))).named('pe1_b${b}_$j')
            : Const(0);
        nextV.add((surV[j] | placeE0 | placeE1).named('nextV_b${b}_$j'));
        nextA.add(
          mux(
            surV[j],
            surA[j],
            mux(placeE0, e0Addr, mux(placeE1, wrAddrs[1], zeroAddr)),
          ),
        );
        nextD.add(
          mux(
            surV[j],
            surD[j],
            mux(placeE0, e0Data, mux(placeE1, wrDatas[1], zeroData)),
          ),
        );
      }

      Sequential(clk, [
        If(
          reset,
          then: [for (var i = 0; i < d; i++) v[i] < Const(0)],
          orElse: [
            for (var i = 0; i < d; i++) ...[
              v[i] < nextV[i],
              a[i] < nextA[i],
              da[i] < nextD[i],
            ],
          ],
        ),
      ]);

      // Readiness for the ports that target this bank (trivially 1 for ports
      // that don't, so the cross-bank AND below picks the real bank).
      port0Ready.add(
        (~en0 | mux(pop, appended0 & scLtD, Const(1))).named('p0r_b$b'),
      );
      final direct1 = ~pop & ~en0 & en1;
      port1Ready.add(
        (~en1 | direct1 | (appended1 & mux(appended0, scLtDm1, scLtD))).named(
          'p1r_b$b',
        ),
      );
    }

    // A write port is ready iff accepted in its target bank (and trivially
    // ready in the others).
    var p0 = port0Ready[0];
    var p1 = port1Ready[0];
    for (var b = 1; b < numBanks; b++) {
      p0 = p0 & port0Ready[b];
      p1 = p1 & port1Ready[b];
    }
    wrReadys[0] <= p0;
    wrReadys[1] <= p1;

    // Storage update: each entry follows its bank's write command. Entry 0
    // (x0) is never stored.
    Sequential(clk, [
      If(
        reset,
        then: [for (final reg in storage) reg < zeroData],
        orElse: [
          for (var entry = 1; entry < numEntries; entry++)
            If(
              bankWrEn[entry % numBanks] &
                  bankWrAddr[entry % numBanks].eq(
                    Const(entry, width: addrWidth),
                  ),
              then: [storage[entry] < bankWrData[entry % numBanks]],
            ),
        ],
      ),
    ]);

    // Combinational reads with buffer bypass. The youngest buffered entry
    // matching the address (highest valid index, packed) wins over storage;
    // x0 reads zero.
    final storageRead = [
      for (var r = 0; r < rdAddrs.length; r++)
        Logic(name: 'storageRead_$r', width: dataWidth),
    ];
    Combinational([
      for (var r = 0; r < rdAddrs.length; r++)
        Case(
          rdAddrs[r],
          [
            for (var entry = 1; entry < numEntries; entry++)
              CaseItem(Const(entry, width: addrWidth), [
                storageRead[r] < storage[entry],
              ]),
          ],
          defaultItem: [storageRead[r] < zeroData],
        ),
    ]);
    for (var r = 0; r < rdAddrs.length; r++) {
      Logic byHit = Const(0);
      Logic byVal = zeroData;
      for (var b = 0; b < numBanks; b++) {
        for (var i = 0; i < d; i++) {
          final sel = bufV[b][i] & bufA[b][i].eq(rdAddrs[r]);
          byHit = byHit | sel;
          byVal = mux(sel, bufD[b][i], byVal); // higher i (younger) wins
        }
      }
      rdDatas[r] <=
          mux(
            rdAddrs[r].eq(Const(0, width: addrWidth)),
            zeroData,
            mux(byHit, byVal, storageRead[r]),
          );
    }
  }
}
