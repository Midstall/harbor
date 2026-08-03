import 'package:rohd/rohd.dart';

/// Width/burst + flow-control adapter between the SoC's narrow Wishbone-B4 bus
/// (ACK-only, [busDataWidth]-bit, e.g. 32) and the [Ddr3Controller]'s wide,
/// pipelined interface (one word = one BL8 burst, e.g. 128-bit, with a stall).
///
/// One outstanding transaction at a time (the SoC cache/CDC drives a single B4
/// transaction to completion), which matches the controller's proven
/// non-pipelined access pattern:
///  - WRITE: a narrow write becomes ONE wide write whose byte-enables (`sel`)
///    select just the addressed narrow word within the burst; DDR3 DM masks the
///    rest, so no read-modify-write is needed. Writes are posted: the adapter
///    ACKs the bus as soon as the controller accepts the command (`~stall`).
///  - READ: a narrow read issues ONE wide burst read, waits for the controller's
///    read ACK, then muxes out the addressed narrow word.
///
/// Bus `adr` is a narrow-word address (increments per [busDataWidth] word); the
/// burst address is `adr >> log2(ratio)` and the word-in-burst is the low bits.
class Ddr3BurstAdapter extends Module {
  final int busDataWidth;
  final int ddrDataWidth;
  final int busAddrWidth;
  final int ddrAddrWidth;
  final int auxWidth;

  /// Narrow words per burst (e.g. 128/32 = 4).
  int get ratio => ddrDataWidth ~/ busDataWidth;
  int get _ratioBits => _clog2(ratio);
  int get busSelWidth => busDataWidth ~/ 8;
  int get ddrSelWidth => ddrDataWidth ~/ 8;

  Ddr3BurstAdapter({
    required this.busAddrWidth,
    required this.ddrAddrWidth,
    this.busDataWidth = 32,
    this.ddrDataWidth = 128,
    this.auxWidth = 4,
    // --- narrow B4 slave side ---
    required Logic clk,
    required Logic reset,
    required Logic sCyc,
    required Logic sStb,
    required Logic sWe,
    required Logic sAddr,
    required Logic sData,
    required Logic sSel,
    // --- wide controller read-return / status side ---
    required Logic mStall,
    required Logic mAck, // controller o_wb_ack (reads only)
    required Logic mData, // controller o_wb_data (wide)
    super.name = 'ddr3_burst_adapter',
  }) {
    assert(ddrDataWidth % busDataWidth == 0, 'ratio must be integral');
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    sCyc = addInput('s_cyc', sCyc);
    sStb = addInput('s_stb', sStb);
    sWe = addInput('s_we', sWe);
    sAddr = addInput('s_addr', sAddr, width: busAddrWidth);
    sData = addInput('s_data', sData, width: busDataWidth);
    sSel = addInput('s_sel', sSel, width: busSelWidth);
    mStall = addInput('m_stall', mStall);
    mAck = addInput('m_ack', mAck);
    mData = addInput('m_data', mData, width: ddrDataWidth);

    // Narrow slave responses.
    final sAck = addOutput('s_ack');
    final sDataOut = addOutput('s_data_out', width: busDataWidth);
    // Wide controller drive.
    final mCyc = addOutput('m_cyc');
    final mStb = addOutput('m_stb');
    final mWe = addOutput('m_we');
    final mAddr = addOutput('m_addr', width: ddrAddrWidth);
    final mDataOut = addOutput('m_data_out', width: ddrDataWidth);
    final mSel = addOutput('m_sel', width: ddrSelWidth);
    final mAux = addOutput('m_aux', width: auxWidth);

    // State: 0 IDLE, 1 ISSUE (hold cmd until accepted), 2 READ_WAIT (await ack).
    final st = Logic(name: 'st', width: 2);
    final wordSel = Logic(name: 'word_sel', width: _ratioBits); // low addr bits
    final isWrite = Logic(name: 'is_write');
    final rdData = Logic(name: 'rd_data', width: busDataWidth);
    final ackReg = Logic(name: 'ack_reg');
    // Write-drain counter: the controller ABORTS an in-flight request when cyc
    // drops (o_wb_cyc gates s1/s2 pending). A posted write is not yet in the PHY
    // pipeline when it is accepted, so cyc must stay asserted a few more cycles
    // to let it drain, or the write is aborted before it reaches DRAM.
    final drainCnt = Logic(name: 'wr_drain', width: 5);

    // BYTE-addressed bus: addr[busByteBits-1:0] = byte-in-narrow-word (ignored),
    // addr[ddrByteBits-1:busByteBits] = which narrow word within the burst,
    // addr[.. :ddrByteBits] = the wide-burst (BL8) address.
    final busByteBits = _clog2(busSelWidth);
    final ddrByteBits = _clog2(ddrSelWidth);
    final curWord = sAddr.getRange(busByteBits, ddrByteBits);
    final burstAddr = (busAddrWidth >= ddrByteBits + ddrAddrWidth)
        ? sAddr.getRange(ddrByteBits, ddrByteBits + ddrAddrWidth)
        : sAddr.getRange(ddrByteBits, busAddrWidth).zeroExtend(ddrAddrWidth);

    // Position the narrow write data + byte-enables into the wide word.
    Logic placedData(Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): [
            if (w < ratio - 1) Const(0, width: (ratio - 1 - w) * busDataWidth),
            sData,
            if (w > 0) Const(0, width: w * busDataWidth),
          ].swizzle(),
      },
      defaultValue: Const(0, width: ddrDataWidth),
      conditionalType: ConditionalType.unique,
    );
    Logic placedSel(Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): [
            if (w < ratio - 1) Const(0, width: (ratio - 1 - w) * busSelWidth),
            sSel,
            if (w > 0) Const(0, width: w * busSelWidth),
          ].swizzle(),
      },
      defaultValue: Const(0, width: ddrSelWidth),
      conditionalType: ConditionalType.unique,
    );
    // Extract the addressed narrow word from a wide read burst.
    Logic pickWord(Logic wide, Logic word) => cases(
      word,
      {
        for (var w = 0; w < ratio; w++)
          Const(w, width: _ratioBits): wide.getRange(
            w * busDataWidth,
            (w + 1) * busDataWidth,
          ),
      },
      defaultValue: wide.getRange(0, busDataWidth),
      conditionalType: ConditionalType.unique,
    );

    // Combinational wide-master + narrow-ack drive off the registered state.
    Combinational([
      mCyc < Const(0),
      mStb < Const(0),
      mWe < Const(0),
      mAddr < Const(0, width: ddrAddrWidth),
      mDataOut < Const(0, width: ddrDataWidth),
      mSel < Const(0, width: ddrSelWidth),
      mAux < Const(1, width: auxWidth),
      If(
        st.eq(1),
        then: [
          mCyc < Const(1),
          mStb < Const(1),
          mWe < isWrite,
          mAddr < burstAddr,
          mDataOut < placedData(wordSel),
          mSel < mux(isWrite, placedSel(wordSel), Const(0, width: ddrSelWidth)),
        ],
      ),
      If(st.eq(2), then: [mCyc < Const(1)]), // keep cyc while awaiting read ack
      If(st.eq(3), then: [mCyc < Const(1)]), // keep cyc while the write drains
    ]);
    sAck <= ackReg;
    sDataOut <= rdData;

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(0, width: 2),
          wordSel < Const(0, width: _ratioBits),
          isWrite < Const(0),
          rdData < Const(0, width: busDataWidth),
          ackReg < Const(0),
          drainCnt < Const(0, width: 5),
        ],
        orElse: [
          ackReg < Const(0), // single-cycle ack pulse by default
          Case(
            st,
            [
              CaseItem(Const(0, width: 2), [
                // IDLE: latch a new bus request.
                If(
                  sCyc & sStb,
                  then: [
                    wordSel < curWord,
                    isWrite < sWe,
                    st < Const(1, width: 2),
                  ],
                ),
              ]),
              CaseItem(Const(1, width: 2), [
                // ISSUE: hold the wide command until the controller accepts it.
                If(
                  ~mStall,
                  then: [
                    If(
                      isWrite,
                      then: [
                        // posted write: ack the bus on accept, then hold cyc to drain.
                        ackReg < Const(1),
                        drainCnt < Const(31, width: 5),
                        st < Const(3, width: 2),
                      ],
                      orElse: [
                        st <
                            Const(2, width: 2), // read issued -> await data ack
                      ],
                    ),
                  ],
                ),
              ]),
              CaseItem(Const(2, width: 2), [
                // READ_WAIT: capture the addressed word on the controller ack.
                If(
                  mAck,
                  then: [
                    rdData < pickWord(mData, wordSel),
                    ackReg < Const(1),
                    st < Const(0, width: 2),
                  ],
                ),
              ]),
              CaseItem(Const(3, width: 2), [
                // WRITE_DRAIN: keep cyc asserted until the write has flushed to the
                // PHY pipeline (else the controller aborts it on ~cyc).
                If(
                  drainCnt.eq(0),
                  then: [st < Const(0, width: 2)],
                  orElse: [drainCnt < drainCnt - 1],
                ),
              ]),
            ],
            conditionalType: ConditionalType.unique,
            defaultItem: [],
          ),
        ],
      ),
    ]);
  }

  static int _clog2(int x) {
    var n = 0;
    var v = x - 1;
    while (v > 0) {
      v >>= 1;
      n++;
    }
    return n;
  }
}
