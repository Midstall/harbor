import 'package:rohd/rohd.dart';
import 'ddr.dart';

/// DDR3 command encoding on {ras_n, cas_n, we_n} with cs_n low.
class Ddr3Cmd {
  static const int mrs = 0; // 000
  static const int refresh = 1; // 001
  static const int precharge = 2; // 010
  static const int activate = 3; // 011
  static const int write = 4; // 100
  static const int read = 5; // 101
  static const int nop = 7; // 111
}

/// PHY-agnostic DDR3 sequencer: JEDEC init (DLL-off), closed-page
/// single-outstanding transactions, BL8 with DM masking, and an auto-refresh
/// timer. Commands leave as {cke, csN, cmd[2:0]=ras/cas/we, ba, addr, odt}
/// at one command per clock (1T); the PHY translates them to pins and owns
/// the data path timing.
///
/// DLL-off mode keeps CK at the system clock (no CDC anywhere) at the cost
/// of bandwidth: CL and CWL are fixed at 6. This is the bring-up
/// configuration; gearing and a faster CK come later.
class DdrSequencer extends Module {
  /// Cycles per microsecond at the controller clock.
  final int clkMhz;

  /// Memory geometry.
  final HarborDdrConfig config;

  /// Bring-up diagnostic: leave MR3's MPR bit set after init, so every
  /// READ returns the part's predefined 0101 training pattern instead of
  /// array data (a captured word reads back 0xFFFF0000). Proves the
  /// command, init, and read-capture paths on real silicon without
  /// depending on writes.
  final bool mprDebug;

  // Command channel to the PHY.
  Logic get cke => output('cke');
  Logic get csN => output('cs_n');
  Logic get cmd => output('cmd'); // {ras_n, cas_n, we_n}
  Logic get ba => output('ba');
  Logic get addr => output('addr');
  Logic get odt => output('odt');
  Logic get resetN => output('reset_n');

  // Data channel to the PHY.
  /// Pulses when a write burst's data phase should start (CWL-aligned by the
  /// PHY); the beat data/masks are valid alongside.
  Logic get wrStart => output('wr_start');
  Logic get wrData => output('wr_data'); // one bus word
  Logic get wrMask => output('wr_mask'); // byte enables for the word

  /// Which beat-pair of the BL8 burst holds the bus word (the word index
  /// within the 16-byte line, reqAddr[3:2]).
  Logic get beatSel => output('beat_sel');

  /// Pulses when a read burst was issued (PHY counts CL and captures).
  Logic get rdStart => output('rd_start');

  // Bus-side handshake.
  Logic get busDone => output('bus_done');

  DdrSequencer(
    Logic clk,
    Logic reset,
    Logic req,
    Logic we,
    Logic reqAddr, // word-aligned byte address within the DDR space
    Logic reqData,
    Logic reqSel, {
    required this.config,
    required this.clkMhz,
    this.mprDebug = false,
    super.name = 'ddr_seq',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    req = addInput('req', req);
    we = addInput('we', we);
    reqAddr = addInput('req_addr', reqAddr, width: 32);
    reqData = addInput('req_data', reqData, width: 32);
    reqSel = addInput('req_sel', reqSel, width: 4);

    final rowBits = config.rowWidth;
    final colBits = config.colWidth;
    final baBits = (config.banks - 1).bitLength; // 8 banks -> 3

    addOutput('cke');
    addOutput('cs_n');
    addOutput('cmd', width: 3);
    addOutput('ba', width: baBits);
    addOutput('addr', width: rowBits);
    addOutput('odt');
    addOutput('reset_n');
    addOutput('wr_start');
    addOutput('wr_data', width: 32);
    addOutput('wr_mask', width: 4);
    addOutput('beat_sel', width: 2);
    addOutput('rd_start');
    addOutput('bus_done');

    // Timing parameters in clock cycles (ceil), DLL-off.
    int us(double n) => (n * clkMhz).ceil();
    int ns(double n) => ((n * clkMhz) / 1000).ceil();
    final tPowerUp = us(200);
    final tResetHold = us(500);
    final tXpr = ns(280); // tRFC(min) + 10ns, generous for 1-2Gb parts
    const tMrd = 4;
    const tMod = 12;
    const tZqInit = 512;
    final tRcd = ns(15) + 1;
    final tRp = ns(15) + 1;
    final tRfc = ns(260); // covers up to 4Gb parts
    final tRefi = us(7.8 / 1.0) ~/ 1; // 7.8us
    const tWr = 8; // write recovery incl. CWL slack, generous
    const burstCk = 4; // BL8 on a x16 part
    const cl = 6; // DLL-off
    const cwl = 6;

    // Address slicing: word address -> {row, bank, col}. The low bus address
    // bits map to columns so bursts stay within a row (col[2:0] selects the
    // word inside the BL8 burst).
    final wordAddr = reqAddr.getRange(2, 32);
    final col = wordAddr
        .getRange(0, colBits - 1)
        .zeroExtend(colBits); // x16: col addresses half-words; <<1 by PHY
    final bank = wordAddr.getRange(colBits - 1, colBits - 1 + baBits);
    final row = wordAddr
        .getRange(colBits - 1 + baBits, colBits - 1 + baBits + rowBits)
        .zeroExtend(rowBits);

    // State machine.
    final state = Logic(name: 'state', width: 4);
    const sPower = 0;
    const sResetHold = 1;
    const sCkeWait = 2;
    const sMrs = 3; // walks MR2, MR3, MR1, MR0
    const sZq = 4;
    const sIdle = 5;
    const sRcd = 7; // 6 reserved (was a separate activate state)
    const sIssue = 8; // READ or WRITE command cycle
    const sData = 9; // burst in flight
    const sPrecharge = 10;
    const sRefresh = 11;

    final wait = Logic(name: 'waitCount', width: 24);
    final mrsStep = Logic(name: 'mrsStep', width: 2);
    final refCount = Logic(name: 'refCount', width: 10);
    final refDue = Logic(name: 'refDue');
    final isWrite = Logic(name: 'isWrite');

    // Mode registers for DLL-off: MR0 CL=6 (DLL precharge PD off), MR1 DLL
    // disable + ODS/RTT defaults, MR2 CWL=6, MR3 zeros.
    final mr0 = Const(0x0520, width: rowBits); // CL=6, BL8, WR=6
    final mr1 = Const(0x0001, width: rowBits); // DLL disable
    final mr2 = Const(0x0008, width: rowBits); // CWL=6
    final mr3 = Const(mprDebug ? 0x0004 : 0x0000, width: rowBits);

    Logic cmdConst(int c) => Const(c, width: 3);

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: Const(sPower, width: 4),
        wait: Const(0, width: 24),
        cke: Const(0),
        resetN: Const(0),
        csN: Const(1),
        cmd: cmdConst(Ddr3Cmd.nop),
      },
      [
        // Refresh interval timer runs whenever initialized.
        If(
          state.gte(Const(sIdle, width: 4)),
          then: [
            refCount < refCount + 1,
            If(
              refCount.eq(Const(0, width: 10) + tRefi),
              then: [refDue < 1, refCount < 0],
            ),
          ],
        ),

        // Default command each cycle: deselect.
        csN < 1,
        cmd < cmdConst(Ddr3Cmd.nop),
        wrStart < 0,
        rdStart < 0,
        busDone < 0,

        Case(state, [
          CaseItem(Const(sPower, width: 4), [
            resetN < 0,
            cke < 0,
            wait < wait + 1,
            If(
              wait.eq(Const(tPowerUp, width: 24)),
              then: [state < sResetHold, wait < 0, resetN < 1],
            ),
          ]),
          CaseItem(Const(sResetHold, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tResetHold, width: 24)),
              then: [state < sCkeWait, wait < 0, cke < 1],
            ),
          ]),
          CaseItem(Const(sCkeWait, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tXpr, width: 24)),
              then: [state < sMrs, wait < 0, mrsStep < 0],
            ),
          ]),
          CaseItem(Const(sMrs, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(tMrd + tMod, width: 24)),
              then: [
                wait < 0,
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.mrs),
                // MRS order: MR2, MR3, MR1, MR0
                ba <
                    mux(
                      mrsStep.eq(Const(0, width: 2)),
                      Const(2, width: baBits),
                      mux(
                        mrsStep.eq(Const(1, width: 2)),
                        Const(3, width: baBits),
                        mux(
                          mrsStep.eq(Const(2, width: 2)),
                          Const(1, width: baBits),
                          Const(0, width: baBits),
                        ),
                      ),
                    ),
                addr <
                    mux(
                      mrsStep.eq(Const(0, width: 2)),
                      mr2,
                      mux(
                        mrsStep.eq(Const(1, width: 2)),
                        mr3,
                        mux(mrsStep.eq(Const(2, width: 2)), mr1, mr0),
                      ),
                    ),
                mrsStep < mrsStep + 1,
                If(
                  mrsStep.eq(Const(3, width: 2)),
                  then: [state < sZq, wait < 0],
                ),
              ],
            ),
          ]),
          CaseItem(Const(sZq, width: 4), [
            // ZQCL waits out tMOD after the final MRS (the sMrs state hands
            // off the same cycle MR0 issues), then needs tZQinit before any
            // other command.
            If(
              wait.eq(Const(tMod, width: 24)),
              then: [
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.precharge), // ZQCL is WE low + A10 high
                addr < (Const(1, width: rowBits) << 10),
              ],
            ),
            wait < wait + 1,
            If(
              wait.eq(Const(tMod + tZqInit, width: 24)),
              then: [state < sIdle, wait < 0],
            ),
          ]),
          CaseItem(Const(sIdle, width: 4), [
            If(
              refDue,
              then: [
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.refresh),
                refDue < 0,
                state < sRefresh,
                wait < 0,
              ],
              orElse: [
                If(
                  req,
                  then: [
                    isWrite < we,
                    wrData < reqData,
                    wrMask < reqSel,
                    beatSel < reqAddr.getRange(2, 4),
                    csN < 0,
                    cmd < cmdConst(Ddr3Cmd.activate),
                    ba < bank,
                    addr < row,
                    state < sRcd,
                    wait < 0,
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(Const(sRcd, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(0, width: 24) + tRcd),
              then: [state < sIssue, wait < 0],
            ),
          ]),
          CaseItem(Const(sIssue, width: 4), [
            csN < 0,
            cmd < mux(isWrite, cmdConst(Ddr3Cmd.write), cmdConst(Ddr3Cmd.read)),
            ba < bank,
            // Column with A10 low (no auto-precharge); burst-aligned. The x16
            // column address counts half-words: word -> col<<1, and the burst
            // start is aligned to BL8 (low 3 column bits zero).
            addr <
                ([
                  col.getRange(2, colBits - 1),
                  Const(0, width: 3),
                ].swizzle().zeroExtend(rowBits)),
            If(isWrite, then: [wrStart < 1], orElse: [rdStart < 1]),
            state < sData,
            wait < 0,
          ]),
          CaseItem(Const(sData, width: 4), [
            wait < wait + 1,
            // Wait out CWL/CL + the burst + recovery before precharging. The
            // extra 4 cycles cover the PHY's read capture tail (IDDR
            // presentation + beat pairing) and the write postamble.
            If(
              wait.eq(Const(cl + burstCk + tWr + 4, width: 24)),
              then: [
                csN < 0,
                cmd < cmdConst(Ddr3Cmd.precharge),
                ba < bank,
                addr < Const(0, width: rowBits),
                state < sPrecharge,
                wait < 0,
              ],
            ),
          ]),
          CaseItem(Const(sPrecharge, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(0, width: 24) + tRp),
              then: [busDone < 1, state < sIdle, wait < 0],
            ),
          ]),
          CaseItem(Const(sRefresh, width: 4), [
            wait < wait + 1,
            If(
              wait.eq(Const(0, width: 24) + tRfc),
              then: [state < sIdle, wait < 0],
            ),
          ]),
        ]),
      ],
    );

    // Static drive for signals not touched by the FSM defaults.
    Sequential(clk, reset: reset, [odt < 0]);

    // Unused for now: cwl is implicit in the PHY's write-launch counter.
    // ignore: unused_local_variable
    const _ = cwl;
  }
}
