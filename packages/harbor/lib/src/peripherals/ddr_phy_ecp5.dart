import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';

/// ECP5 DDR3 PHY for the DLL-off bring-up configuration: DDR CK equals the
/// system clock, commands are 1T SDR-registered, and the data path uses
/// ODDRX1F/IDDRX1F gearing.
///
/// Write timing: DQS launches on the 0-degree clock (edge-aligned to CK, so
/// tDQSS is nominally zero), while DQ/DM launch on a phase-shifted clock
/// from an internal EHXPLLL secondary output so the data eyes straddle the
/// strobe edges. Read capture runs each DQ through a static [readTaps]
/// DELAYG into an IDDRX1F; at DLL-off speeds the eye is wide enough for a
/// fixed tap (training refines it later).
///
/// The burst engine is BL8 on a x16 part: 8 beats, 4 words. Writes mask
/// every beat except the addressed word's two via DM; reads capture all 8
/// beats and select the word.
///
/// Several constants here are calibrated against measurements taken on the
/// OrangeCrab (in-system pad captures and DRAM readback structure) rather
/// than derived from primitive documentation: the ODDR pipeline depth, the
/// read window slack, and the ODDR slot assignment. Each is commented at
/// its definition.
class DdrPhyEcp5 extends Module {
  /// Read data back to the controller (one bus word) and its valid pulse.
  Logic get rdData => output('rd_data');
  Logic get rdValid => output('rd_valid');

  // SDRAM pin-side outputs (wired by the controller to its ports).
  Logic get ckOut => output('pin_ck');
  Logic get ckNOut => output('pin_ck_n');
  Logic get ckeOut => output('pin_cke');
  Logic get csNOut => output('pin_cs_n');
  Logic get rasNOut => output('pin_ras_n');
  Logic get casNOut => output('pin_cas_n');
  Logic get weNOut => output('pin_we_n');
  Logic get baOut => output('pin_ba');
  Logic get addrOut => output('pin_addr');
  Logic get dmOut => output('pin_dm');
  Logic get odtOut => output('pin_odt');
  Logic get resetNOut => output('pin_reset_n');

  /// DQ/DQS drive values and output enables (the controller owns the
  /// tristate pads, since the inout ports live on its module boundary).
  Logic get dqOut => output('dq_out');
  Logic get dqOe => output('dq_oe');
  Logic get dqsOut => output('dqs_out');
  Logic get dqsNOut => output('dqs_n_out');
  Logic get dqsOe => output('dqs_oe');

  DdrPhyEcp5(
    Logic clk,
    Logic reset, {
    // Sequencer command channel.
    required Logic cke,
    required Logic csN,
    required Logic cmd,
    required Logic ba,
    required Logic addr,
    required Logic odt,
    required Logic resetN,
    // Sequencer data channel.
    required Logic wrStart,
    required Logic wrData,
    required Logic wrMask,
    required Logic beatSel,
    required Logic rdStart,
    // DQ read returns (from the controller's pads).
    required Logic dqIn,
    required int rowBits,
    required int baBits,
    int dataBits = 16,
    int clkMhz = 48,
    int readTaps = 40,
    super.name = 'ddr_phy',
  }) {
    const cl = 6;
    const cwl = 6;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    cke = addInput('cke', cke);
    csN = addInput('cs_n', csN);
    cmd = addInput('cmd', cmd, width: 3);
    ba = addInput('ba', ba, width: baBits);
    addr = addInput('addr', addr, width: rowBits);
    odt = addInput('odt', odt);
    resetN = addInput('reset_n', resetN);
    wrStart = addInput('wr_start', wrStart);
    wrData = addInput('wr_data', wrData, width: 32);
    wrMask = addInput('wr_mask', wrMask, width: 4);
    beatSel = addInput('beat_sel', beatSel, width: 2);
    rdStart = addInput('rd_start', rdStart);
    dqIn = addInput('dq_in', dqIn, width: dataBits);

    addOutput('rd_data', width: 32);
    addOutput('rd_valid');
    addOutput('pin_ck');
    addOutput('pin_ck_n');
    addOutput('pin_cke');
    addOutput('pin_cs_n');
    addOutput('pin_ras_n');
    addOutput('pin_cas_n');
    addOutput('pin_we_n');
    addOutput('pin_ba', width: baBits);
    addOutput('pin_addr', width: rowBits);
    addOutput('pin_dm', width: dataBits ~/ 8);
    addOutput('pin_odt');
    addOutput('pin_reset_n');
    addOutput('dq_out', width: dataBits);
    addOutput('dq_oe');
    addOutput('dqs_out', width: dataBits ~/ 8);
    addOutput('dqs_n_out', width: dataBits ~/ 8);
    addOutput('dqs_oe');

    // Write-launch phase from an internal 1:1 PLL.
    // CLKOP feeds back (phase-locked to clk), CLKOS carries the shift.
    // CLKOS_CPHASE is inert on silicon (a 180-degree rotation changed
    // nothing observable); the delivered phase measured -90, and the DQ/DM
    // ODDR slot assignment below carries the calibration instead of this
    // parameter.
    final pllFb = Logic(name: 'pll_fb');
    final vcoDiv = (600 / clkMhz).floor().clamp(2, 128); // VCO in 400-800MHz
    final pll = Ecp5Ehxplll(
      clkiDiv: 1,
      clkfbDiv: 1,
      clkopDiv: vcoDiv,
      clkosDiv: vcoDiv,
      clkosCphase: (3 * vcoDiv) ~/ 4,
      clk: clk,
      clkfb: pllFb,
      name: 'phy_pll',
    );
    pllFb <= pll.output('CLKOP');
    final clk90 = pll.output('CLKOS');

    // CK/CK#: free-running mirror of clk via DDR outputs.
    // Explicit pseudo-differential pair: nextpnr does not build the
    // complement side of "D"-suffixed SSTL output types, which would leave
    // CK# floating and the part's differential clock receiver dead.
    final ckDdr = Ecp5Oddrx1f(
      sclk: clk,
      rst: reset,
      d0: Const(1),
      d1: Const(0),
      name: 'ck_oddr',
    );
    ckOut <= ckDdr.q;
    final ckNDdr = Ecp5Oddrx1f(
      sclk: clk,
      rst: reset,
      d0: Const(0),
      d1: Const(1),
      name: 'ck_n_oddr',
    );
    ckNOut <= ckNDdr.q;

    // Command/address: 1T SDR registers.
    Sequential(
      clk,
      reset: reset,
      resetValues: {csNOut: Const(1), resetNOut: Const(0)},
      [
        ckeOut < cke,
        csNOut < csN,
        rasNOut < cmd[2],
        casNOut < cmd[1],
        weNOut < cmd[0],
        baOut < ba,
        addrOut < addr,
        odtOut < odt,
        resetNOut < resetN,
      ],
    );

    // Write engine.
    // wrStart pulses at the WRITE command. Data must be on the pins CWL
    // cycles later for 4 CKs (BL8). A shift register delays the launch; a
    // beat counter then walks the 4 beat-pairs. Only the addressed word's
    // two beats carry data (DM low); every other beat is masked.
    //
    // The launch taps sit [oddrLatency] cycles early: ODDRX1F pipelines
    // about two SCLK cycles between sampling its D inputs and presenting
    // them at the pad (measured against a command-anchored pad capture).
    // Without the compensation the strobes land at WL+2 and the part
    // rejects the burst per tDQSS. CK is periodic so its own ODDR latency
    // is invisible, and commands are plain registers, so only the write
    // burst needs this.
    const oddrLatency = 2;
    final wrPipe = Logic(name: 'wr_pipe', width: cwl);
    final wrBeats = Logic(name: 'wr_beats', width: 3);
    final wrActive = Logic(name: 'wr_active');
    final wrWord = Logic(name: 'wr_word', width: 32);
    final wrSel = Logic(name: 'wr_sel', width: 4);
    final wrBeat = Logic(name: 'wr_beat', width: 2);
    Sequential(clk, reset: reset, [
      wrPipe < [wrPipe.getRange(0, cwl - 1), wrStart].swizzle(),
      If(wrStart, then: [wrWord < wrData, wrSel < wrMask, wrBeat < beatSel]),
      If(wrPipe[cwl - 1 - oddrLatency], then: [wrActive < 1, wrBeats < 0]),
      If(
        wrActive,
        then: [
          wrBeats < wrBeats + 1,
          If(wrBeats.eq(Const(3, width: 3)), then: [wrActive < 0]),
        ],
      ),
    ]);

    // The current beat-pair index during the burst.
    final beatNow = wrBeats.getRange(0, 2);
    final beatHit = wrActive & beatNow.eq(wrBeat);

    // DQ: low half-word in the q0 slot (rising beat), high in q1 (falling),
    // both halves of a beat in the same clk90 cycle. The q0=rise assignment
    // is silicon-calibrated: with rise in q1 every UI arrived one strobe
    // edge late at the part (rise cells stored the previous beat's fall
    // data). DM gates which beats the part actually keeps.
    final dqRise = wrWord.getRange(0, dataBits);
    final dqFall = wrWord.getRange(dataBits, 32);
    final dqBits = <Logic>[
      for (var i = 0; i < dataBits; i++)
        Ecp5Oddrx1f(
          sclk: clk90,
          rst: reset,
          d0: dqRise[i],
          d1: dqFall[i],
          name: 'dq_oddr_$i',
        ).q,
    ];
    dqOut <= dqBits.rswizzle();

    // DM: mask everything except the addressed word's enabled byte lanes
    // (DM=1 means "ignore this byte"). Same-cycle slots let one beatHit
    // gate both halves: q0 (rising) masks lanes 0/1, q1 (falling) 2/3.
    final dmBits = <Logic>[
      for (var i = 0; i < dataBits ~/ 8; i++)
        Ecp5Oddrx1f(
          sclk: clk90,
          rst: reset,
          d0: ~(beatHit & wrSel[i]),
          d1: ~(beatHit & wrSel[2 + i]),
          name: 'dm_oddr_$i',
        ).q,
    ];
    dmOut <= dmBits.rswizzle();

    // DQS: toggles 1/0 on the 0-degree clock during the burst (plus a low
    // preamble), edge-aligned to CK.
    //
    // The output enables are fabric-driven (no ODDR in the tristate path),
    // so they are delayed to track the burst in pad time: an undelayed OE
    // would drop before the last beats clear the ODDR pipeline, chopping
    // the burst tail to high-Z. The delayed copies cover the pad-time
    // burst plus a preamble cycle ahead and postamble slack behind.
    final wrActiveD1 = Logic(name: 'wr_active_d1');
    final wrActiveD2 = Logic(name: 'wr_active_d2');
    final wrActiveD3 = Logic(name: 'wr_active_d3');
    final wrActiveD4 = Logic(name: 'wr_active_d4');
    Sequential(clk, reset: reset, [
      wrActiveD1 < wrActive,
      wrActiveD2 < wrActiveD1,
      wrActiveD3 < wrActiveD2,
      wrActiveD4 < wrActiveD3,
    ]);
    final dqsBits = <Logic>[
      for (var i = 0; i < dataBits ~/ 8; i++)
        Ecp5Oddrx1f(
          sclk: clk,
          rst: reset,
          d0: wrActive,
          d1: Const(0),
          name: 'dqs_oddr_$i',
        ).q,
    ];
    dqsOut <= dqsBits.rswizzle();
    // DQS#: explicit pseudo-differential complement, same reasoning as CK#
    // (the part's strobe receiver is differential; a floating complement
    // makes write capture undefined).
    final dqsNBits = <Logic>[
      for (var i = 0; i < dataBits ~/ 8; i++)
        Ecp5Oddrx1f(
          sclk: clk,
          rst: reset,
          d0: ~wrActive,
          d1: Const(1),
          name: 'dqs_n_oddr_$i',
        ).q,
    ];
    dqsNOut <= dqsNBits.rswizzle();
    dqsOe <= wrActiveD2 | wrActiveD3 | wrActiveD4;
    dqOe <= wrActiveD2 | wrActiveD3 | wrActiveD4;

    // Read engine.
    // rdStart pulses at the READ command. Each DQ passes through a static
    // DELAYG and an IDDRX1F; a window counter opens (CL + [rdSlack])
    // cycles after the command, captures the 4 beat-pairs, and selects the
    // addressed word. At DLL-off speeds a generous fixed window works;
    // per-board training refines [readTaps].
    //
    // The IDDRs share the DQ ODDRs' shifted clock: a bidirectional pad's
    // IOLOGIC has a single SCLK, so both directions must use it (nextpnr
    // rejects split clocks). The shift also centers the sampling edges in
    // the edge-aligned DLL-off read eyes, so one cycle captures both
    // halves of the same beat (Q0 = rise, Q1 = fall). The capture engine
    // stays in the 0-degree domain with three quarters of a cycle of
    // setup.
    //
    // rdSlack is measured (MPR pattern readout): DLL-off read latency is
    // CL-1 and DLL-off tDQSCK is large, so the burst lands two cycles
    // earlier than DLL-on arithmetic suggests.
    const rdSlack = 1;
    final rdPipe = Logic(name: 'rd_pipe', width: cl + rdSlack);
    final rdBeats = Logic(name: 'rd_beats', width: 3);
    final rdActive = Logic(name: 'rd_active');
    final rdBeat = Logic(name: 'rd_beat', width: 2);
    final q0Bits = <Logic>[];
    final q1Bits = <Logic>[];
    for (var i = 0; i < dataBits; i++) {
      final dly = Ecp5Delayg(a: dqIn[i], delValue: readTaps, name: 'dq_dly_$i');
      final iddr = Ecp5Iddrx1f(
        sclk: clk90,
        rst: reset,
        d: dly.z,
        name: 'dq_iddr_$i',
      );
      q0Bits.add(iddr.q0);
      q1Bits.add(iddr.q1);
    }
    final q0Cap = q0Bits.rswizzle().named('cap_q0'); // rise half of beat k
    final q1Cap = q1Bits.rswizzle().named('cap_q1'); // fall half of beat k

    Sequential(clk, reset: reset, [
      rdPipe < [rdPipe.getRange(0, cl + rdSlack - 1), rdStart].swizzle(),
      If(rdStart, then: [rdBeat < beatSel]),
      rdValid < 0,
      If(rdPipe[cl + rdSlack - 1], then: [rdActive < 1, rdBeats < 0]),
      If(
        rdActive,
        then: [
          rdBeats < rdBeats + 1,
          If(
            rdBeats.getRange(0, 2).eq(rdBeat),
            then: [
              rdData < [q1Cap, q0Cap].swizzle(),
              rdValid < 1,
            ],
          ),
          If(rdBeats.eq(Const(3, width: 3)), then: [rdActive < 0]),
        ],
      ),
    ]);
  }
}
