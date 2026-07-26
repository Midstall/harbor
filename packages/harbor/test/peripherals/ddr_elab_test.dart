import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Elaboration smoke tests for the DDR3 controller: the full
/// bus -> sequencer -> PHY -> pads chain must build and emit SystemVerilog
/// for the board configs. Functional verification runs in the pin-level
/// iverilog bench against a behavioral DDR3 model (not in this suite).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('DDR3 controller elaborates for the OrangeCrab config (DLL-off, 48MHz)', () async {
    // The default OrangeCrab clockHz is 48 MHz, BELOW the DLL-lock threshold, so
    // the PHY builds the hardware-PROVEN x1 datapath (the pre-Milestone-4 PHY).
    // A bidirectional x2 DQ pad REQUIRES the DQS-bonded IOLOGIC (DLL-locked),
    // which nextpnr cannot pack DLL-off ("IDDRXN and ODDRXN on the same pin is
    // unsupported"). x1 IDDRX1F + ODDRX1F SHARE one bidir-pad SCLK, which packs.
    // So DLL-off the DQ read/write + DM + DQS all use x1 IDDRX1F/ODDRX1F clocked
    // on a dedicated PHY EHXPLLL clk90 (the -90deg write/read launch phase), with
    // the DQ/DQS pad tristate a plain registered OE into the Ecp5Bb `.t`. NONE of
    // the x2 DQSBUFM-strobed primitives (IDDRX2DQA/ODDRX2DQA/ODDRX2DQSB/TSHX2DQA/
    // TSHX2DQSA/IDDRX2F/ODDRX2F) may appear on the read/write DQ path.
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('DdrSequencer'));
    expect(sv, contains('DdrPhyEcp5'));
    // The dedicated PHY PLL (clk90 launch phase) MUST be present DLL-off.
    expect(
      sv,
      contains('EHXPLLL'),
      reason: 'the DLL-off x1 path needs a dedicated PHY PLL for clk90',
    );
    // x1 datapath: CK ODDRX1F + the DQ/DM/DQS data ODDRX1F + the DQ read IDDRX1F
    // MUST be emitted.
    expect(sv, contains('ODDRX1F'));
    expect(sv, contains('IDDRX1F'));
    // The x2 DQS-bonded IOLOGIC and the (now removed) strobe-free x2 leaves MUST
    // NOT touch the DQ/DM/DQS path DLL-off. nextpnr cannot pack a bidirectional
    // x2 DQ pad without a locked DLL, so NONE of these may be instantiated.
    expect(sv, isNot(contains('IDDRX2DQA')));
    expect(sv, isNot(contains('ODDRX2DQA')));
    expect(sv, isNot(contains('ODDRX2DQSB')));
    expect(sv, isNot(contains('TSHX2DQA')));
    expect(sv, isNot(contains('TSHX2DQSA')));
    expect(sv, isNot(contains('IDDRX2F')));
    expect(sv, isNot(contains('ODDRX2F')));
    // No leaf may CONNECT a DQSBUFM read/write strobe or pointer output port. The
    // x1 path never uses them. (A DQSBUFM may stay instantiated for the DQS pad
    // receive, emitting those as empty `.DQSW()` etc, which is fine.)
    for (final port in ['DQSR90', 'DQSW270', 'DQSW', 'RDPNTR0', 'WRPNTR0']) {
      expect(
        RegExp('\\.$port\\([^)]').hasMatch(sv),
        isFalse,
        reason: 'a DLL-off leaf still connects DQSBUFM .$port',
      );
    }
    // The CRITICAL pack guard: nextpnr segfaults on an IDDRXN + ODDRXN sharing one
    // pad. The x1 IDDRX1F/ODDRX1F share one SCLK and pack. There must be no x2
    // (IDDRX2*/ODDRX2*) gearing on a DQ pad at all, asserted by the absence above.
    // The PHY OWNS the DQ/DQS pads via Ecp5Bb (BB). The controller exposes no
    // directional dq_oe/dqs_oe split.
    expect(sv, contains('BB'));
    expect(sv, isNot(contains('dq_oe')));
    expect(sv, isNot(contains('dqs_oe')));
    // BB pad nets MUST be connected. An empty `.B()` would sever the DQ bus from
    // its I/O buffer. Guard it, and confirm the DQ pad reaches a BB.
    expect(
      RegExp(r'BB\s+\w+\([^;]*\.B\(\)\)').hasMatch(sv),
      isFalse,
      reason: 'an Ecp5Bb emitted an unconnected .B() pad net',
    );
    expect(sv, contains('.B((pad_dq'));
    // DQS is an EXPLICIT pseudo-differential pair DLL-off (the all-taps-E0 fix):
    // the controller exposes an sdram_dqs_n complement port, and the PHY drives it
    // with a SEPARATE complement ODDR (dqs_n_oddr) into its own Bb on the _n net.
    expect(
      sv,
      contains('sdram_dqs_n'),
      reason: 'DLL-off DQS needs an explicit _n complement port',
    );
    expect(
      sv,
      contains('dqs_n_oddr'),
      reason: 'DLL-off DQS needs the explicit complement ODDR',
    );
    expect(
      sv,
      contains('.B((pad_dqs_n'),
      reason: 'the explicit DQS _n ODDR must drive the _n pad Bb',
    );
    // The DQ pad is x1 in+out on ONE shared clk90 (a bidir pad's IOLOGIC admits
    // only that): exactly one read IDDR per pad, no second per-pad read IDDR.
    expect(
      RegExp(r'IDDRX1F\s+dq_iddrb_').hasMatch(sv),
      isFalse,
      reason: 'no second per-pad read IDDR (unpackable on a bidir pad)',
    );
    expect(
      RegExp(r'IDDRX1F\s+dq_iddr_').hasMatch(sv),
      isTrue,
      reason: 'the single x1 read IDDR per DQ pad',
    );
    // WRITE-SIDE DQS FIX: the DQS strobe is launched on a SECOND 50%-duty PLL
    // output (CLKOS2 = clk90b), NOT on `clk`/sclk, so the DQS edge spacing is
    // structurally tCK/2 like the DQ (on CLKOS) and can center both write beats.
    // The DQS pad is output-only (no read IDDR), so CLKOS2 packs without conflict.
    expect(
      sv,
      contains('CLKOS2_ENABLE'),
      reason: 'the write DQS needs the 50%-duty CLKOS2 strobe clock',
    );
    expect(
      sv,
      contains('CLKOS2_CPHASE'),
      reason: 'CLKOS2_CPHASE tunes the DQS-vs-DQ centering',
    );
    expect(
      sv,
      contains('ddr_clk90b'),
      reason: 'the DQS strobe clock (CLKOS2) must be exposed',
    );
    // The DQS strobe ODDR is clocked by clk90b. The DQ data ODDR stays on clk90.
    expect(
      RegExp(r'ODDRX1F\s+dqs_oddr_\w+\(\.SCLK\(ddr_clk90b\)').hasMatch(sv),
      isTrue,
      reason: 'the DQS strobe ODDR must run on clk90b (CLKOS2)',
    );
    expect(
      RegExp(r'ODDRX1F\s+dq_oddr_\w+\(\.SCLK\(ddr_clk90\)').hasMatch(sv),
      isTrue,
      reason: 'the DQ data ODDR stays on clk90 (CLKOS)',
    );
  });

  test(
    'DDR3 controller DLL-ON (144MHz) keeps the DQSBUFM-strobed x2 datapath',
    () async {
      // At 144 MHz CK the DRAM + ECP5 DDRDLLA lock, so the PHY MUST keep the
      // strobed datapath byte-identical to the pre-fix Milestone-4 build: read
      // capture through IDDRX2DQA on DQSR90, DQ/DM through ODDRX2DQA on DQSW270,
      // and the DQS strobe launched by ODDRX2DQSB on DQSW. The strobe-free static
      // IDDRX2F/ODDRX2F leaves MUST NOT appear on this build.
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        asyncClock: true,
        clockHz: 144000000,
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      expect(sv, contains('DdrPhyEcp5'));
      expect(sv, contains('IDDRX2DQA'));
      expect(sv, contains('ODDRX2DQA'));
      expect(sv, contains('ODDRX2DQSB'));
      expect(sv, contains('TSHX2DQA'));
      expect(sv, contains('TSHX2DQSA'));
      // The static DLL-off leaves are NOT instantiated on the DLL-on build.
      expect(sv, isNot(contains('IDDRX2F')));
      expect(sv, isNot(contains('ODDRX2F')));
      // DLL-ON DQS is the SINGLE true-differential pad (nextpnr derives _n): there
      // is NO explicit sdram_dqs_n port and NO complement ODDR.
      expect(
        sv,
        isNot(contains('sdram_dqs_n')),
        reason: 'DLL-on uses the single SSTL135D_I diff DQS pad, no _n port',
      );
      expect(
        sv,
        isNot(contains('dqs_n_oddr')),
        reason: 'DLL-on derives _n via nextpnr, no explicit complement ODDR',
      );
      // DLL-ON builds no PHY PLL and no x1 read IDDR (the x2 DQSBUFM path captures
      // via IDDRX2DQA), byte-identical to the pre-dual x2 path.
      expect(
        sv,
        isNot(contains('CLKOS2_ENABLE')),
        reason: 'DLL-on x2 path must not build CLKOS2',
      );
      expect(
        RegExp(r'IDDRX1F\s+dq_iddr').hasMatch(sv),
        isFalse,
        reason: 'DLL-on has no x1 read IDDR',
      );
    },
  );

  test(
    'writeLevel ECP5 DDR3 build emits the WL FSM + DQS write pointer',
    () async {
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        trainableRead: true,
        writeLevel: true,
        asyncClock: true,
        clockHz: 48000000,
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      // The sequencer's WL FSM control channel reaches the PHY.
      expect(sv, contains('wl_en'));
      expect(sv, contains('wl_trained'));
      expect(sv, contains('wl_strobe'));
      // The ECP5 write-DQS-delay mechanism: the per-lane DQSBUFM write-pointer
      // stepper that loads min and steps WRMOVE to the trained tap (vs the tied
      // -off pointer on the read-only build).
      expect(sv, contains('WRLOADN'));
      expect(sv, contains('WRMOVE'));
      expect(sv, contains('wr_apply_active'));
    },
  );

  test(
    'non-writeLevel ECP5 build leaves the auto-WL FSM out (baseline read path)',
    () async {
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        trainableRead: true,
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      // The auto write-leveling REPLAY path (the per-lane stepper that loads min
      // then replays the WL-trained tap on wl_done's edge) must NOT be built when
      // writeLevel is off, so the proven MPR-read baseline is unaffected: the
      // discriminator is the WL-trained replay state (wr_wldone_prev), which exists
      // only on the writeLevel build. (The sequencer carries tied-off wl_* ports
      // regardless, so a bare 'wl_en' string is not a reliable discriminator.)
      expect(sv, isNot(contains('wr_wldone_prev')));
      // The firmware WRDLY write-pointer stepper IS present on the trainable build
      // (reg7 sweeps the write delay directly), but it only steps on a firmware
      // apply edge, which the read-only sweep never sends. So the write pointer
      // stays at litedram's tie-off (WRLOADN=1, no move) unless firmware writes reg7.
      expect(sv, contains('wr_dly'));
      expect(sv, contains('wr_fw_active'));
    },
  );

  test(
    'trainableRead ECP5 build exposes the firmware WRDLY write-pointer path',
    () async {
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        trainableRead: true,
        asyncClock: true,
        clockHz: 48000000,
        busAddressWidth: 32,
        busDataWidth: 64,
        target: const HarborFpgaTarget.ecp5(
          device: '25f',
          package: 'CSFBGA285',
        ),
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      // The reg7 WRDLY channel reaches the PHY and drives the per-lane write-pointer
      // stepper (reload to min + step N WRMOVE pulses).
      expect(sv, contains('wr_dly'));
      expect(sv, contains('wr_dly_apply'));
      expect(sv, contains('WRLOADN'));
      expect(sv, contains('WRMOVE'));
      expect(sv, contains('wr_fw_active'));
    },
  );

  test('DDR3L controller elaborates for the Arty S7 config', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
    );
    await ddr.build();
    expect(ddr.generateSynth(), contains('DdrSequencer'));
  });

  test('Arty S7 target selects the Xilinx PHY primitives', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      target: const HarborFpgaTarget.spartan7(
        device: 's50',
        package: 'csga324',
      ),
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    // Xilinx 7-series DDR primitives.
    expect(sv, contains('ODDR'));
    // Read path now uses IDDR (ISERDESE2 is not routeable on openXC7 xc7s50:
    // its CLKDIV pin needs a BUFR bel, which the chipdb lacks).
    expect(sv, contains('IDDR'));
    expect(sv, contains('dq_iddr'));
    expect(sv, isNot(contains('ISERDESE2')));
    expect(sv, contains('IDELAYE2'));
    expect(sv, contains('IDELAYCTRL'));
    expect(sv, contains('MMCME2_ADV'));
    // No Lattice primitives leaked in.
    expect(sv, isNot(contains('ODDRX1F')));
    expect(sv, isNot(contains('IDDRX1F')));
    expect(sv, isNot(contains('EHXPLLL')));
  });

  test('OrangeCrab keeps the ECP5 PHY, no Xilinx primitives', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      target: const HarborFpgaTarget.ecp5(device: '85f', package: 'CABGA381'),
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    expect(sv, contains('ODDRX1F'));
    expect(sv, isNot(contains('IDELAYE2')));
    expect(sv, isNot(contains('MMCME2_ADV')));
  });

  test('non-power-of-two array size is rejected', () {
    // The address mask and the single-bit control-window decode both assume a
    // power-of-two size. A non-power-of-two would alias the control window into
    // the array. Constructed via the generic ctor to bypass the named presets.
    expect(
      () => HarborDdrController(
        config: const HarborDdrConfig(
          type: HarborDdrType.ddr3,
          size: 100 * 1024 * 1024, // not a power of two
          frequency: 400000000,
        ),
        baseAddress: 0x80000000,
      ),
      throwsArgumentError,
    );
  });

  test(
    'trainableRead on a Xilinx target now builds (IDELAY VAR_LOAD train)',
    () async {
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.artyS7(),
        baseAddress: 0x80000000,
        trainableRead: true,
        target: const HarborFpgaTarget.spartan7(
          device: 's50',
          package: 'csga324',
        ),
      );
      await ddr.build();
      final sv = ddr.generateSynth();
      expect(sv, contains('XilinxReadTrainRegs'));
      expect(sv, contains('.IDELAY_TYPE("VAR_LOAD")'));
    },
  );

  test('asyncClock builds the CDC bridge and exposes ddr_clk', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x80000000,
      busAddressWidth: 32,
      busDataWidth: 64,
      clockHz: 48000000, // ddr_clk rate
      asyncClock: true,
      target: const HarborFpgaTarget.ecp5(device: '25f', package: 'CSFBGA285'),
    );
    // The async datapath adds the second clock domain ports.
    expect(ddr.tryInput('ddr_clk'), isNotNull);
    expect(ddr.tryInput('ddr_reset'), isNotNull);
    await ddr.build();
    final sv = ddr.generateSynth();
    // The clock-crossing bridge and the proven datapath both elaborate.
    expect(sv, contains('HarborWishboneCdcBridge'));
    expect(sv, contains('DdrSequencer'));
    expect(sv, contains('DdrPhyEcp5'));
  });

  test(
    'asyncClock + trainableRead coexist (DQS read leveling on async DDR)',
    () async {
      // The old mutual exclusion is gone: the training control window decodes on
      // the bus clock while the steppers + PHY runtime controls live in the sclk
      // datapath domain, crossed by 2-flop synchronizers. creek needs both. This
      // proves the combined build elaborates and emits the CDC + delay controller.
      final ddr = HarborDdrController(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x80000000,
        busAddressWidth: 32,
        busDataWidth: 64,
        clockHz: 48000000,
        asyncClock: true,
        trainableRead: true,
        target: const HarborFpgaTarget.ecp5(
          device: '25f',
          package: 'CSFBGA285',
        ),
      );
      expect(ddr.tryInput('ddr_clk'), isNotNull);
      await ddr.build();
      final sv = ddr.generateSynth();
      expect(sv, contains('HarborWishboneCdcBridge'));
      expect(sv, contains('DdrPhyEcp5'));
      // The DELAYF read-tap walker is instantiated in the datapath domain.
      expect(sv, contains('ecp5_delay_controller'));
      // The DQS read status outputs are exposed for the STATUS register.
      expect(sv, contains('rd_datavalid'));
      expect(sv, contains('rd_burstdet'));
    },
  );
}
