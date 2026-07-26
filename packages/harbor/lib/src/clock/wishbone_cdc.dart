import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Single-outstanding Wishbone clock-domain-crossing bridge.
///
/// Presents a Wishbone B4 SLAVE on the [s_clk] (slow) domain and drives a
/// Wishbone B4 MASTER on the [m_clk] (fast) domain, forwarding one transaction
/// at a time across the two clocks.
///
/// The handshake crosses the domains as GRAY-CODED request/done counters. The
/// payload ({we, adr, dat, sel}) and the returned read data are quasi-static:
/// each is latched once and held stable for the whole transaction, so the other
/// domain samples it as a multi-cycle path. Only the two small gray counters run
/// through flip-flop synchronizers.
///
/// Why gray counters and not a plain level handshake: the two domains here are
/// the SAME frequency from one PLL (mesochronous, e.g. the core CLKOS at 24 MHz
/// and the DDR controller's CLKOP/2 at 24 MHz, fixed but arbitrary phase). A
/// four-phase LEVEL handshake with plain synchronizers is not safe on a
/// mesochronous crossing: at a pathological fixed phase the synchronizer can sit
/// metastable and resolve the same (wrong) way every cycle, so a level
/// transition is missed forever and the bus wedges (Harbor issue #144, which
/// showed up as Weir's bss-clear and its conduit DTB walk both hanging on creek
/// silicon while ideal-timing sim could never reproduce it, since 0 ppm offset
/// means the bad phase never drifts). A gray counter changes exactly one bit per
/// step and only ever increments, so a two-flop sample is always a valid
/// adjacent value (old or new, never bogus) and the new value persists until the
/// consumer acts on it. That removes the miss/wedge by construction for ANY
/// phase, and costs only a handful of flops (unlike a full async FIFO, which
/// does not fit alongside the icache on a 25F).
///
/// Use it to run a fast peripheral (e.g. the DDR3 controller) behind a slower
/// core/fabric: the slave side joins the fabric on the core clock, the master
/// side drives the peripheral on its own clock. Latency is a few cycles per
/// domain (synchronizer depth plus turnaround), irrelevant next to DRAM latency.
class HarborWishboneCdcBridge extends BridgeModule {
  /// Address bus width.
  final int addressWidth;

  /// Data bus width.
  final int dataWidth;

  /// Byte-select width.
  final int selWidth;

  /// Synchronizer depth for the gray counters (>= 2).
  final int syncStages;

  /// Slow-side liveness backstop, in slave (`s_clk`) cycles. 0 disables it.
  ///
  /// The crossing normally needs no watchdog: the peripheral's completion is
  /// timed by construction, so a single-outstanding wait cannot lose a
  /// completion. That guarantee only holds while the *master* domain keeps
  /// running. If its clock or reset momentarily freezes (e.g. a marginal DDR
  /// clock tree losing lock), the gray handshake desyncs: the slave advances
  /// its request gray but the frozen master never crosses it back as a done, so
  /// the slave waits forever and the whole fabric wedges (observed on creek as a
  /// hung DRAM load, `wait_done_slow` stuck with the master bits idle). When set,
  /// force-complete an outstanding request after this many idle cycles so the
  /// fabric can never hang forever. The read-retry above re-reads, so a transient
  /// freeze self-heals and only genuinely dead master clocking returns poison.
  /// Keep it far above the real completion latency so it never trips in normal
  /// operation.
  final int completionTimeout;

  HarborWishboneCdcBridge({
    required this.addressWidth,
    required this.dataWidth,
    int? selWidth,
    this.syncStages = 2,
    this.completionTimeout = 0,
    super.name = 'wishbone_cdc',
  }) : selWidth = selWidth ?? (dataWidth ~/ 8),
       assert(syncStages >= 2, 'CDC synchronizer needs >= 2 stages'),
       assert(completionTimeout >= 0, 'completionTimeout must be >= 0'),
       super('HarborWishboneCdcBridge') {
    final sw = this.selWidth;
    final aw = addressWidth;
    final dw = dataWidth;

    createPort('s_clk', PortDirection.input);
    createPort('s_reset', PortDirection.input);
    createPort('s_cyc', PortDirection.input);
    createPort('s_stb', PortDirection.input);
    createPort('s_we', PortDirection.input);
    createPort('s_adr', PortDirection.input, width: aw);
    createPort('s_dat_w', PortDirection.input, width: dw);
    createPort('s_sel', PortDirection.input, width: sw);
    addOutput('s_ack');
    addOutput('s_dat_r', width: dw);

    createPort('m_clk', PortDirection.input);
    createPort('m_reset', PortDirection.input);
    createPort('m_ack', PortDirection.input);
    createPort('m_dat_r', PortDirection.input, width: dw);
    addOutput('m_cyc');
    addOutput('m_stb');
    addOutput('m_we');
    addOutput('m_adr', width: aw);
    addOutput('m_dat_w', width: dw);
    addOutput('m_sel', width: sw);

    final sClk = input('s_clk');
    final sReset = input('s_reset');
    final mClk = input('m_clk');
    final mReset = input('m_reset');

    // 2-bit counters: single-outstanding keeps request and done within one of
    // each other, so 2 bits (a full cyclic gray sequence 00-01-11-10) is ample.
    const cw = 2;

    // Slow (slave) domain state.
    final reqCnt = Logic(name: 'req_cnt', width: cw);
    final busy = Logic(name: 'busy');
    final ackReg = Logic(name: 's_ack_reg');
    final sDatRReg = Logic(name: 's_dat_r_reg', width: dw);
    final pWe = Logic(name: 'p_we');
    final pAdr = Logic(name: 'p_adr', width: aw);
    final pDatW = Logic(name: 'p_dat_w', width: dw);
    final pSel = Logic(name: 'p_sel', width: sw);

    // Fast (master) domain state.
    final doneCnt = Logic(name: 'done_cnt', width: cw);
    final serving = Logic(name: 'serving');
    final mCycReg = Logic(name: 'm_cyc_reg');
    final rDat = Logic(name: 'r_dat', width: dw);

    // Gray codes of the two counters (binary ^ binary>>1).
    final reqGray = (reqCnt ^ (reqCnt >>> 1)).named('req_gray');
    final doneGray = (doneCnt ^ (doneCnt >>> 1)).named('done_gray');

    // Synchronizer chains: done -> slow, req -> fast.
    final doneSync = [
      for (var i = 0; i < syncStages; i++)
        Logic(name: 'done_sync_$i', width: cw),
    ];
    final reqSync = [
      for (var i = 0; i < syncStages; i++)
        Logic(name: 'req_sync_$i', width: cw),
    ];
    final doneGrayInSlow = doneSync.last;
    final reqGrayInFast = reqSync.last;

    // Issue a new request when idle and the fabric has a cycle up. ACK when the
    // fast side's done count (gray) has caught up to the request count.
    final allDone = doneGrayInSlow.eq(reqGray);
    final issue = (~busy & input('s_cyc') & input('s_stb') & ~ackReg).named(
      'issue',
    );

    // Liveness backstop (completionTimeout): count slave cycles an outstanding
    // request has been waiting, force-complete once it exceeds the budget so a
    // frozen master domain cannot wedge the fabric forever. Disabled (width 1,
    // wdFire tied 0) when completionTimeout is 0.
    final wdOn = completionTimeout > 0;
    final wdW = wdOn ? completionTimeout.bitLength : 1;
    final waitCnt = Logic(name: 's_wait_cnt', width: wdW);
    final wdFire =
        (wdOn
                ? busy & waitCnt.gte(Const(completionTimeout, width: wdW))
                : Const(0))
            .named('wd_fire');

    Sequential(sClk, [
      If(
        sReset,
        then: [
          for (final s in doneSync) s < Const(0, width: cw),
          reqCnt < Const(0, width: cw),
          busy < Const(0),
          ackReg < Const(0),
          sDatRReg < Const(0, width: dw),
          pWe < Const(0),
          pAdr < Const(0, width: aw),
          pDatW < Const(0, width: dw),
          pSel < Const(0, width: sw),
          waitCnt < Const(0, width: wdW),
        ],
        orElse: [
          doneSync[0] < doneGray,
          for (var i = 1; i < syncStages; i++) doneSync[i] < doneSync[i - 1],
          ackReg < Const(0),
          If(
            busy & allDone,
            then: [
              // The outstanding request completed: capture the (quasi-static) read
              // data and pulse ACK to the fabric.
              sDatRReg < rDat,
              ackReg < Const(1),
              busy < Const(0),
              waitCnt < Const(0, width: wdW),
            ],
            orElse: [
              If(
                wdFire,
                then: [
                  // Budget exhausted: the master never crossed a completion (its clock
                  // or reset froze under marginal timing, desyncing the gray handshake).
                  // Force-complete with whatever read data is latched (poison if the
                  // master is genuinely dead) so the fabric makes progress. The
                  // read-retry re-reads, healing a transient freeze.
                  sDatRReg < rDat,
                  ackReg < Const(1),
                  busy < Const(0),
                  waitCnt < Const(0, width: wdW),
                ],
                orElse: [
                  If(
                    issue,
                    then: [
                      // Latch the payload (held stable for the whole transaction) and
                      // advance the request counter.
                      pWe < input('s_we'),
                      pAdr < input('s_adr'),
                      pDatW < input('s_dat_w'),
                      pSel < input('s_sel'),
                      reqCnt < reqCnt + 1,
                      busy < Const(1),
                      waitCnt < Const(0, width: wdW),
                    ],
                    orElse: [
                      // Waiting on the master to complete: run the liveness counter.
                      If(busy, then: [waitCnt < waitCnt + 1]),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    output('s_ack') <= ackReg;
    output('s_dat_r') <= sDatRReg;

    // A new request is pending while the synchronized request gray differs from
    // the local done gray. Run the master cycle, and on m_ack latch the read
    // data and advance the done counter.
    final newReq = (~reqGrayInFast.eq(doneGray)).named('new_req');

    Sequential(mClk, [
      If(
        mReset,
        then: [
          for (final s in reqSync) s < Const(0, width: cw),
          doneCnt < Const(0, width: cw),
          serving < Const(0),
          mCycReg < Const(0),
          rDat < Const(0, width: dw),
        ],
        orElse: [
          reqSync[0] < reqGray,
          for (var i = 1; i < syncStages; i++) reqSync[i] < reqSync[i - 1],
          If(
            ~serving & newReq,
            then: [
              // Start serving a new request: issue the master cycle.
              serving < Const(1),
              mCycReg < Const(1),
            ],
            orElse: [
              If(
                serving & mCycReg & input('m_ack'),
                then: [
                  // Completed: capture read data, advance done, release. The peripheral
                  // completion (m_ack) is timed by construction (the DDR PHY drives its
                  // read-valid from the sclk read-latency count, not a droppable DQS
                  // edge/level capture), so while this master domain keeps clocking a
                  // single-outstanding wait cannot lose a completion. The only way to
                  // lose one is for this domain itself to freeze (clock/reset glitch),
                  // which the slave-side completionTimeout backstop recovers from.
                  rDat < input('m_dat_r'),
                  mCycReg < Const(0),
                  doneCnt < doneCnt + 1,
                  serving < Const(0),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Master payload is the quasi-static slow-domain latch, cyc/stb gate it.
    output('m_cyc') <= mCycReg;
    output('m_stb') <= mCycReg;
    output('m_we') <= pWe;
    output('m_adr') <= pAdr;
    output('m_dat_w') <= pDatW;
    output('m_sel') <= pSel;

    // #144 CDC state tap (pure observation, sampled asynchronously by an LA).
    // Layout chosen to localize the wedge stage:
    //   [0] busy            slow: an outstanding txn is in flight
    //   [1] s_ack           slow: completion ack pulse to the fabric
    //   [2] serving         fast: picked up a request, issuing to DDR
    //   [3] m_cyc           fast: master cycle asserted to the DDR datapath
    //   [4] reserved        (was retry-watchdog, removed, tied 0)
    //   [5] reserved        (was re-issue gap, removed, tied 0)
    //   [6] req_seen_fast   fast: synced request gray != local done gray
    //   [7] wait_done_slow  slow: local req gray != synced done gray
    // Reading it: serving=1 with [3] stuck => the master cycle is out but DDR
    // never acks (sequencer/PHY is the stuck stage). busy=1 with [7] stuck and
    // serving=0/[6]=0 => the request gray never crossed (a gray-handshake
    // desync). All idle while the core hangs => wedge is not here. Bits [4]/[5]
    // are retained (tied 0) so the LA bit map and the 8-bit port are unchanged.
    // swizzle: first element is the MSB (bit 7), last is the LSB (bit 0).
    addOutput('dbg', width: 8) <=
        [
          ~doneGrayInSlow.eq(reqGray), // [7] wait_done_slow
          ~reqGrayInFast.eq(doneGray), // [6] req_seen_fast
          Const(0), // [5] reserved (was gap)
          Const(0), // [4] reserved (was ack_watch)
          mCycReg, // [3]
          serving, // [2]
          ackReg, // [1] s_ack
          busy, // [0]
        ].swizzle();
  }
}
