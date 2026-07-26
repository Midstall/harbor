import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr_sequencer.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Guards the real-speed DDR3-667 ISERDESE2 read datapath (the UberDDR3 /
/// LiteDRAM gearbox). The gate for this work is ROUTES CLEAN on openXC7, these
/// tests cover the RTL structure/emission + the pure-fabric assembly logic that
/// the ISERDESE2 (an unmodelled leaf) cannot co-sim.
void main() {
  tearDown(() async => Simulator.reset());

  test('Oserdese2SimModel serializes D1..D8 (DDR) onto OQ, D1 first', () async {
    // clk is the fast serialize clock, clkdiv reloads the 8 beats per 8 clk
    // edges. Drive clkdiv high for one clk edge (reload), then observe OQ pop
    // D1,D2,...,D8 one per clk edge.
    final clk = SimpleClockGenerator(10).clk;
    final clkdiv = Logic()..put(0);
    final reset = Logic()..put(1);
    final pattern = [1, 0, 1, 1, 0, 0, 1, 0]; // D1..D8
    final d = [for (final b in pattern) Logic()..put(b)];
    final t1 = Logic()..put(0);
    final m = Oserdese2SimModel(
      clk,
      d: d,
      t1: t1,
      clkdiv: clkdiv,
      reset: reset,
    );
    await m.build();

    Simulator.registerAction(12, () => reset.put(0));
    // Pulse clkdiv high across exactly one clk rising edge (t=25) to reload.
    Simulator.registerAction(21, () => clkdiv.put(1));
    Simulator.registerAction(29, () => clkdiv.put(0));

    // Sample OQ right after each clk rising edge from the reload edge onward.
    final seen = <int>[];
    for (var k = 0; k < 8; k++) {
      Simulator.registerAction(26 + k * 10, () => seen.add(m.oq.value.toInt()));
    }
    Simulator.setMaxSimTime(140);
    await Simulator.run();
    expect(seen, pattern, reason: 'OQ pops D1 first .. D8 last, DDR order');
  });

  test('Oserdese2SimModel TQ follows T1 (in-site BUF tristate)', () async {
    final clk = SimpleClockGenerator(10).clk;
    final t1 = Logic()..put(0);
    final d = [for (var i = 0; i < 8; i++) Logic()..put(0)];
    final m = Oserdese2SimModel(clk, d: d, t1: t1);
    await m.build();
    Simulator.registerAction(15, () => t1.put(1));
    Simulator.registerAction(25, () {
      expect(m.tq.value.toInt(), 1, reason: 'TQ = T1 when T1 high');
    });
    Simulator.registerAction(35, () => t1.put(0));
    Simulator.registerAction(45, () {
      expect(m.tq.value.toInt(), 0, reason: 'TQ = T1 when T1 low');
    });
    Simulator.setMaxSimTime(60);
    await Simulator.run();
  });

  test(
    'DdrBl8WriteGearbox spreads the addressed word into 8 beats + DM',
    () async {
      // wrWord = {fall, rise} = {0xBBBB, 0xAAAA}, addressed beat-pair wrBeat=2
      // (beats 4/5), all byte lanes enabled (wrSel=0xF).
      final wrWord = Logic(width: 32)..put(0xBBBBAAAA);
      final wrSel = Logic(width: 4)..put(0xF);
      final wrBeat = Logic(width: 2)..put(2);
      final g = DdrBl8WriteGearbox(
        wrWord: wrWord,
        wrSel: wrSel,
        wrBeat: wrBeat,
        dataBits: 16,
      );
      await g.build();

      final line = g.dataLine.value.toBigInt();
      BigInt beat(int b) => (line >> (b * 16)) & BigInt.from(0xFFFF);
      // beats 4 (rise=0xAAAA) and 5 (fall=0xBBBB) carry data, others 0.
      expect(beat(4), BigInt.from(0xAAAA), reason: 'beat 2*wrBeat = rise');
      expect(beat(5), BigInt.from(0xBBBB), reason: 'beat 2*wrBeat+1 = fall');
      for (final b in [0, 1, 2, 3, 6, 7]) {
        expect(beat(b), BigInt.zero, reason: 'non-addressed beat $b is 0');
      }
      // DM: 2 lanes/beat, 8 beats = 16 bits. DM=0 (write) only on beats 4/5 lanes,
      // DM=1 (masked) everywhere else.
      final dm = g.dmLine.value.toInt();
      int dmBeat(int b) => (dm >> (b * 2)) & 0x3;
      expect(dmBeat(4), 0, reason: 'beat 4 both lanes enabled (DM=0)');
      expect(dmBeat(5), 0, reason: 'beat 5 both lanes enabled (DM=0)');
      for (final b in [0, 1, 2, 3, 6, 7]) {
        expect(dmBeat(b), 0x3, reason: 'beat $b masked (DM=1)');
      }
    },
  );

  test('DdrBl8WriteGearbox honours the byte-enable mask per lane', () async {
    // Only lane 0 of the rise half and lane 1 of the fall half enabled.
    final wrWord = Logic(width: 32)..put(0x33334444);
    final wrSel = Logic(width: 4)
      ..put(0x9); // bit0 (rise lane0), bit3 (fall lane1)
    final wrBeat = Logic(width: 2)..put(0);
    final g = DdrBl8WriteGearbox(
      wrWord: wrWord,
      wrSel: wrSel,
      wrBeat: wrBeat,
      dataBits: 16,
    );
    await g.build();
    final dm = g.dmLine.value.toInt();
    // beat0 (rise): lane0 enabled (DM bit=0), lane1 masked (DM bit=1) -> 0b10.
    expect((dm >> 0) & 0x3, 0x2);
    // beat1 (fall): lane1 enabled (DM bit=0 at lane1), lane0 masked -> 0b01.
    expect((dm >> 2) & 0x3, 0x1);
  });

  test(
    'DW8 IserdesE2SimModel deserializes an 8-sample stream onto Q1..Q8',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..put(1);
      final ddly = Logic()..put(0);
      final bitslip = Logic()..put(0);
      final m = IserdesE2SimModel(
        clk,
        ddly: ddly,
        bitslip: bitslip,
        reset: reset,
        dataWidth: 8,
      );
      await m.build();

      // Drive samples 1,0,1,1,0,0,1,0 one per rising edge (oldest first).
      final pattern = [1, 0, 1, 1, 0, 0, 1, 0];
      Simulator.registerAction(12, () => reset.put(0));
      for (var t = 0; t < 8; t++) {
        Simulator.registerAction(20 + t * 10, () => ddly.put(pattern[t]));
      }
      // After all 8 have shifted in, the real ISERDESE2 convention presents
      // Q1=NEWEST (last-arriving) .. Q8=OLDEST (first-arriving). Samples were driven
      // oldest-first, so Q1..Q8 == the pattern REVERSED.
      var q = List<int>.filled(8, -1);
      Simulator.registerAction(20 + 8 * 10 + 5, () {
        for (var k = 1; k <= 8; k++) {
          q[k - 1] = m.q(k).value.toInt();
        }
      });
      Simulator.setMaxSimTime(20 + 8 * 10 + 20);
      await Simulator.run();

      expect(
        q,
        pattern.reversed.toList(),
        reason: 'Q1=newest .. Q8=oldest (reversed drive order)',
      );
    },
  );

  test(
    'DdrBl8SerdesAssembler selects the beatSel word from the 128-bit line',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..put(1);
      final beatLine = Logic(width: 16 * 8);
      final rdStart = Logic()..put(0);
      final beatSel = Logic(width: 2)..put(0);
      final windowOpen = Logic()..put(0);

      final asm = DdrBl8SerdesAssembler(
        clk,
        reset,
        beatLine: beatLine,
        rdStart: rdStart,
        beatSel: beatSel,
        windowOpen: windowOpen,
        dataBits: 16,
      );
      await asm.build();

      // Line: beat b = 0x1000 + b (each 16 bits), packed beat0 in the low half.
      var line = BigInt.zero;
      for (var b = 0; b < 8; b++) {
        line |= BigInt.from(0x1000 + b) << (b * 16);
      }

      beatLine.put(line);
      Simulator.registerAction(25, () => reset.put(0));
      // Latch beatSel=2 (word2 = {beat5, beat4}) at rd_start (t=35 edge), then
      // open the window at the t=55 edge.
      Simulator.registerAction(31, () {
        beatSel.put(2);
        rdStart.put(1);
      });
      Simulator.registerAction(41, () => rdStart.put(0));
      // Open the window across exactly one rising edge (t=55): high 51..59.
      Simulator.registerAction(51, () => windowOpen.put(1));
      Simulator.registerAction(59, () => windowOpen.put(0));

      var sawValid = false;
      var word = BigInt.zero;
      // rdValid pulses on the windowOpen edge (t=55), sample after that edge and
      // before the next edge (t=65) clears the one-cycle pulse.
      Simulator.registerAction(60, () {
        sawValid = asm.rdValid.value.toBool();
        word = asm.rdData.value.toBigInt();
      });
      Simulator.setMaxSimTime(90);
      await Simulator.run();

      expect(
        sawValid,
        isTrue,
        reason: 'rd_valid should pulse after windowOpen',
      );
      // word2 = {beat5, beat4} = {0x1005, 0x1004} => 0x10051004.
      expect(word, BigInt.from(0x10051004));
    },
  );

  test('ddr3Fast Xilinx controller emits 16x ISERDESE2 DW8 + IDELAYCTRL + '
      'VAR_LOAD IDELAY + the BL8 SERDES assembler, no IDDR', () async {
    // Build the trainable ddr3Fast controller (the ddrlevelx arrangement). The
    // ddr3Fast/ddr_clk clock ports are left undriven (as the existing asyncClock
    // elab test does): generateSynth emits the netlist without needing driven
    // clocks, and wiring SimpleClockGenerators onto them breaks generateSynth.
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      clockHz: 83000000,
      target: const HarborFpgaTarget.spartan7(
        device: 's50',
        package: 'csga324',
      ),
      asyncClock: true,
      ddr3Fast: true,
      trainableRead: true,
    );
    expect(ddr.tryInput('ddr_ck_fast'), isNotNull);
    expect(ddr.tryInput('ddr_ck90_fast'), isNotNull);
    expect(ddr.tryInput('ddr_idelay_ref'), isNotNull);
    await ddr.build();
    final sv = ddr.generateSynth();

    expect(sv, contains('DdrPhyXilinx'));
    // 16 DQ lanes -> 16 ISERDESE2 DATA_WIDTH=8 NETWORKING.
    expect('ISERDESE2'.allMatches(sv).length, 16);
    expect(sv, contains('.DATA_WIDTH(8)'));
    expect(sv, contains('.INTERFACE_TYPE("NETWORKING")'));
    expect(sv, contains('.IOBDELAY("IFD")'));
    // VAR_LOAD IDELAY on each lane, one IDELAYCTRL.
    expect(sv, contains('.IDELAY_TYPE("VAR_LOAD")'));
    expect(sv, contains('IDELAYCTRL'));
    // The BL8 SERDES assembler (whole line per cycle), not the IDDR path.
    expect(sv, contains('DdrBl8SerdesAssembler'));
    expect(
      sv,
      isNot(contains('dq_iddr')),
      reason: 'ddr3Fast must use ISERDESE2, not the IDDR fallback',
    );
    // OCLK/OCLKB must be UNCONNECTED (the openXC7 routing fix).
    expect(
      sv,
      isNot(contains('.OCLK(')),
      reason: 'OCLK must be left unconnected for openXC7 routing',
    );
  });

  test('DdrSequencer at ckCyclesPerTick=4 + CL=5/CWL=5 builds and encodes the '
      'DDR3-667 mode registers (MR0=0x510, MR2=0x200)', () async {
    // The retimed ddr3Fast sequencer: ctrl83 (clkMhz=83) with CK=CK/4*4=333, the
    // DDR3-667 speed-bin CL=5/CWL=5. Must build (relaxed asserts) and emit the
    // correct MR0/MR2 constants, the rowWidth-wide Const encodes them.
    final clk = Logic();
    final reset = Logic();
    final seq = DdrSequencer(
      clk,
      reset,
      Logic(), // req
      Logic(), // we
      Logic(width: 32), // reqAddr
      Logic(width: 32), // reqData
      Logic(width: 4), // reqSel
      config: const HarborDdrConfig.artyS7(),
      clkMhz: 83,
      ckCyclesPerTick: 4,
      cl: 5,
      cwl: 5,
    );
    await seq.build();
    final sv = seq.generateSynth();
    // rowWidth = 14 for the Arty part -> 14'h... width. Match the MR0/MR2 values
    // regardless of the exact Const literal formatting.
    expect(sv, contains("15'h510"), reason: 'MR0 must encode CL=5 (0x510)');
    expect(sv, contains("15'h200"), reason: 'MR2 must encode CWL=5 (0x200)');
    expect(
      sv,
      isNot(contains("15'h520")),
      reason: 'CL=6 MR0 (0x520) must NOT appear at CL=5',
    );
  });

  test('DdrSequencer keeps the 48 MHz / 144 MHz MR encodings at CL=6/CWL=6 '
      '(byte-identical regression: MR0=0x520, MR2=0x208)', () async {
    final seq = DdrSequencer(
      Logic(),
      Logic(),
      Logic(),
      Logic(),
      Logic(width: 32),
      Logic(width: 32),
      Logic(width: 4),
      config: const HarborDdrConfig.artyS7(),
      clkMhz: 48,
      // defaults: ckCyclesPerTick=1, cl=6, cwl=6
    );
    await seq.build();
    final sv = seq.generateSynth();
    expect(sv, contains("15'h520"), reason: 'CL=6 MR0 unchanged (0x520)');
    expect(sv, contains("15'h208"), reason: 'CWL=6 MR2 unchanged (0x208)');
  });

  test('DdrSequencer rejects ckCyclesPerTick=3 (only 1/2/4 legal)', () {
    // Non-{1,2,4} ratios trip the (assert-guarded) unit-bridge check.
    expect(
      () => DdrSequencer(
        Logic(),
        Logic(),
        Logic(),
        Logic(),
        Logic(width: 32),
        Logic(width: 32),
        Logic(width: 4),
        config: const HarborDdrConfig.artyS7(),
        clkMhz: 83,
        ckCyclesPerTick: 3,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('ddr3Fast serializes ALL command/control/address pins through matched '
      'SDR-W4 (4:1) OSERDES so the whole command bus is CK-aligned', () async {
    final ddr = HarborDdrController(
      config: const HarborDdrConfig.artyS7(),
      baseAddress: 0x80000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      clockHz: 83000000,
      target: const HarborFpgaTarget.spartan7(
        device: 's50',
        package: 'csga324',
      ),
      asyncClock: true,
      ddr3Fast: true,
      trainableRead: true,
    );
    await ddr.build();
    final sv = ddr.generateSynth();
    // Every command/control pin has its own named command OSERDES (the UberDDR3
    // OSERDESE2_cmd), so each reaches the pad through an identical OLOGIC path.
    for (final name in [
      'csnf_oserdes',
      'rasnf_oserdes',
      'casnf_oserdes',
      'wenf_oserdes',
      'ckef_oserdes',
      'odtf_oserdes',
      'resetnf_oserdes',
    ]) {
      expect(
        sv,
        contains(name),
        reason: 'ddr3Fast must serialize $name onto its CK slot',
      );
    }
    // Address + bank are serialized per bit (arty-s7: 14 addr + 3 ba).
    expect(
      sv,
      contains('addrf_oserdes_0'),
      reason: 'address serialized per bit, latency-matched to cs_n',
    );
    expect(
      sv,
      contains('baf_oserdes_0'),
      reason: 'bank serialized per bit, latency-matched to cs_n',
    );
    // The command path is SDR/4 (4:1), the data path DDR/8. Both must appear.
    expect(
      sv,
      contains('.DATA_RATE_OQ("SDR")'),
      reason: 'command OSERDES = SDR 4:1 (the oracle OSERDESE2_cmd recipe)',
    );
    expect(
      sv,
      contains('.DATA_WIDTH(4)'),
      reason: 'command OSERDES DATA_WIDTH=4 (four CK slots per tick)',
    );
    // Total OSERDESE2 count now far exceeds the 16 DQ (16 DQ + 2 DM + 4 DQS +
    // 7 control + 14 addr + 3 ba = 46 for arty-s7).
    expect(
      'OSERDESE2'.allMatches(sv).length,
      greaterThan(16),
      reason: 'command/address SERDES add many OSERDESE2 beyond the 16 DQ',
    );
  });

  test(
    'ddr3Fast without asyncClock or on a non-Xilinx target is rejected',
    () async {
      expect(
        () => HarborDdrController(
          config: const HarborDdrConfig.artyS7(),
          baseAddress: 0x80000000,
          target: const HarborFpgaTarget.spartan7(
            device: 's50',
            package: 'csga324',
          ),
          ddr3Fast: true, // asyncClock defaults false -> reject
        ),
        throwsArgumentError,
      );
    },
  );
}
