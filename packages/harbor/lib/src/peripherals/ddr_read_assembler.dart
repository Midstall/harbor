import 'package:rohd/rohd.dart';

/// The BL8 read assemble-and-select, extracted as a pure-ROHD (co-simmable)
/// unit so it is unit-tested independent of the un-cosimmable ISERDESE2. Each
/// [beatWord] is one DDR beat-pair {fallBits, riseBits} = dataBits*2 wide.
///
/// On the [windowOpen] pulse the assembler captures [beatWord] live into
/// rdWords[0] and activates the burst counter (rdBeats starts at 1). Over the
/// next three cycles (rdBeats = 1, 2, 3) it captures rdWords[1..2] and on
/// rdBeats==3 it selects the [beatSel]-addressed word: beats 0-2 from the
/// registered rdWords[0..2], beat3 taken from the live [beatWord] (rdWords[3]
/// would be registered on the same edge and is therefore stale). It then
/// pulses [rdValid] for one cycle. Same rd_data/rd_valid contract as the
/// inline IDDR capture in [DdrPhyXilinx], minus the pairMode gearbox.
///
/// Regression note: this module was extracted to guard #142 (streaming-read
/// collapse). The ECP5-style assembled-select (register every beat, select
/// after the burst) means a one-cycle window jitter yields real shifted data
/// instead of a static-DQ collapse where hi16 == lo16.
class DdrReadWordAssembler extends Module {
  Logic get rdData => output('rd_data');
  Logic get rdValid => output('rd_valid');

  DdrReadWordAssembler(
    Logic clk,
    Logic reset, {
    required Logic beatWord,
    required Logic rdStart,
    required Logic beatSel,
    required Logic windowOpen,
    int dataBits = 16,
    super.name = 'rd_assembler',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    beatWord = addInput('beat_word', beatWord, width: dataBits * 2);
    rdStart = addInput('rd_start', rdStart);
    beatSel = addInput('beat_sel', beatSel, width: 2);
    windowOpen = addInput('window_open', windowOpen);
    final rdData = addOutput('rd_data', width: dataBits * 2);
    final rdValid = addOutput('rd_valid');

    // 3-bit counter: starts at 1 on windowOpen (beat0 captured live that
    // cycle), counts 1->2->3 for beats 1-2-3, then deactivates.
    final rdBeats = Logic(name: 'rd_beats', width: 3);
    final rdActive = Logic(name: 'rd_active');
    final rdBeat = Logic(name: 'rd_beat', width: 2);
    // The 4 words of one BL8 line, registered as each beat streams by so a
    // one-cycle window jitter yields real shifted data instead of a collapsed
    // static-DQ level (streaming-read bug #142).
    final rdWords = [
      for (var w = 0; w < 4; w++) Logic(name: 'rd_word$w', width: dataBits * 2),
    ];

    Sequential(clk, reset: reset, [
      // Latch the addressed word-in-line when the read command arrives.
      If(rdStart, then: [rdBeat < beatSel]),
      // rdValid is a one-cycle pulse. Default low every cycle.
      rdValid < 0,
      // CONTRACT for the PHY that drives this: windowOpen MUST be asserted on the
      // exact cycle beatWord carries beat0 (NOT one cycle earlier). beat0 is
      // captured LIVE on the windowOpen cycle. Beats 1-3 on the next 3 cycles.
      // The CL+slack pipe tap that produces windowOpen is positioned accordingly.
      If(windowOpen, then: [rdActive < 1, rdBeats < 1, rdWords[0] < beatWord]),
      // Active burst: capture beats 1-2 by register, beat3 taken live (its
      // rdWords[3] register latches on the same edge and is still stale).
      If(
        rdActive,
        then: [
          rdBeats < rdBeats + 1,
          If(rdBeats.eq(Const(1, width: 3)), then: [rdWords[1] < beatWord]),
          If(rdBeats.eq(Const(2, width: 3)), then: [rdWords[2] < beatWord]),
          If(
            rdBeats.eq(Const(3, width: 3)),
            then: [
              rdActive < 0,
              rdData <
                  mux(
                    rdBeat.eq(Const(0, width: 2)),
                    rdWords[0],
                    mux(
                      rdBeat.eq(Const(1, width: 2)),
                      rdWords[1],
                      mux(rdBeat.eq(Const(2, width: 2)), rdWords[2], beatWord),
                    ),
                  ),
              rdValid < 1,
            ],
          ),
        ],
      ),
    ]);
  }
}

/// The DDR3-667 (real-speed) counterpart of [DdrReadWordAssembler]: at
/// DATA_WIDTH=8 the ISERDESE2 delivers the WHOLE BL8 line (8 beats x dataBits)
/// in ONE controller (CLKDIV) cycle on Q1..Q8, instead of 2 beats/cycle over 4
/// cycles. So there is no multi-cycle beat accumulation. The entire 128-bit
/// line arrives at once. This unit captures that line on the [windowOpen] pulse
/// (positioned at the real read latency off rd_start) and selects the addressed
/// 32-bit WORD (two consecutive beats) for the controller's word-per-beatSel
/// read face, keeping the same rd_data (dataBits*2) / rd_valid contract.
///
/// [beatLine] is the assembled line, dataBits*8 wide, packed beat-major with
/// beat0 in the LOW dataBits: `{beat7, beat6, ... beat1, beat0}`. [beatSel]
/// (0..3) selects word w = beats {2w, 2w+1}: word0 = {beat1, beat0}, word3 =
/// {beat7, beat6}. rd_data = {beat[2w+1], beat[2w]} (rise beat low, fall high),
/// matching the {fall, rise} half-word packing the controller downsizer expects.
///
/// Pure ROHD (co-simmable): the ISERDESE2 that produces [beatLine] is a leaf,
/// so this fabric select+valid logic is unit-tested against the DW8
/// [IserdesE2SimModel] at the same 1-cycle latency.
class DdrBl8SerdesAssembler extends Module {
  Logic get rdData => output('rd_data');
  Logic get rdValid => output('rd_valid');

  DdrBl8SerdesAssembler(
    Logic clk,
    Logic reset, {
    required Logic beatLine,
    required Logic rdStart,
    required Logic beatSel,
    required Logic windowOpen,
    int dataBits = 16,
    super.name = 'rd_bl8_assembler',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    beatLine = addInput('beat_line', beatLine, width: dataBits * 8);
    rdStart = addInput('rd_start', rdStart);
    beatSel = addInput('beat_sel', beatSel, width: 2);
    windowOpen = addInput('window_open', windowOpen);
    // A bus word is [beatsPerWord] beats = 32 bits (x16: 2 beats, x8: 4 beats).
    final rdData = addOutput('rd_data', width: (32 ~/ dataBits) * dataBits);
    final rdValid = addOutput('rd_valid');

    final rdBeat = Logic(name: 'rd_beat', width: 2);
    // The whole 128-bit line, registered on windowOpen so the addressed word is
    // selected combinationally from a stable capture (avoids depending on the
    // live ISERDESE2 outputs a cycle later).
    final lineReg = Logic(name: 'rd_line', width: dataBits * 8);

    Sequential(clk, reset: reset, [
      If(rdStart, then: [rdBeat < beatSel]),
      rdValid < 0,
      If(
        windowOpen,
        then: [
          lineReg < beatLine,
          // rd_data = word rdBeat = {beat[2*rdBeat+1], beat[2*rdBeat]}. Select the
          // live beatLine on the capture cycle (same edge lineReg latches, so use
          // the incoming value) so rd_valid pulses exactly one cycle after
          // windowOpen with the correct word.
          rdData < _selectWord(beatLine, rdBeat, dataBits),
          rdValid < 1,
        ],
      ),
    ]);
  }

  /// word w = the [beatsPerWord] beats [w*beatsPerWord .. +beatsPerWord),
  /// chunk localBeat -> word[localBeat*dataBits:] (the write gearbox's inverse).
  /// x16: word w = {beat[2w+1], beat[2w]}. x8: 4 beats concatenated.
  static Logic _selectWord(Logic line, Logic sel, int dataBits) {
    final beatsPerWord = 32 ~/ dataBits;
    final numWords = 8 ~/ beatsPerWord; // 4 for x16, 2 for x8
    Logic beat(int b) => line.getRange(b * dataBits, (b + 1) * dataBits);
    Logic word(int w) => [
      for (var lb = beatsPerWord - 1; lb >= 0; lb--)
        beat(w * beatsPerWord + lb),
    ].swizzle();
    Logic pick(int w) => w == numWords - 1
        ? word(w)
        : mux(sel.eq(Const(w, width: 2)), word(w), pick(w + 1));
    return pick(0);
  }
}

/// The BL8 WRITE gearbox: the launch-side mirror of [DdrBl8SerdesAssembler].
///
/// Harbor writes ONE 32-bit bus word per DDR access (one BL8 beat-pair). The
/// other three beat-pairs of the burst are DM-masked. On the OSERDESE2 DW8 write
/// path the whole BL8 (8 beats) launches in ONE CLKDIV cycle, so this gearbox
/// spreads the single addressed word [wrWord] (a {fall, rise} half-word pair)
/// into the 8-beat data line and builds the 8-beat DM line, placing the two
/// active beats at `2*wrBeat` (rise) and `2*wrBeat+1` (fall) and masking the
/// rest.
///
/// Outputs (combinational, presented on the launch cycle. The caller registers
/// them into the OSERDESE2 D1..D8 alongside its own launch strobe):
///   [dataLine]  dataBits*8, beat-major {beat7..beat0}: beat b bit i at
///               [b*dataBits + i]. beat `2w` = rise[i], beat `2w+1` = fall[i]
///               for the addressed word w = [wrBeat], other beats are 0.
///   [dmLine]    (dataBits/8)*8, beat-major: DM=1 (mask/ignore) on every beat
///               except the addressed word's two, where DM = ~byteEnable. This
///               matches the oracle's active-low DQ drive with per-beat masking.
///
/// Pure ROHD (co-simmable): the OSERDESE2 that consumes these lines is a leaf,
/// so this fabric spread logic is unit-tested at the same launch contract.
class DdrBl8WriteGearbox extends Module {
  /// The 8-beat data line, dataBits*8 wide, packed beat-major (beat0 low).
  Logic get dataLine => output('data_line');

  /// The 8-beat DM line, (dataBits/8)*8 wide, packed beat-major (beat0 low).
  /// DM=1 means the byte is masked (not written).
  Logic get dmLine => output('dm_line');

  DdrBl8WriteGearbox({
    // The addressed 32-bit bus word = {fall[dataBits-1:0], rise[dataBits-1:0]}.
    required Logic wrWord,
    // Byte-enable mask: [0]/[1] enable the rise half's byte lanes, [2]/[3] the
    // fall half's, matching the controller downsizer's wr_mask packing.
    required Logic wrSel,
    // Which BL8 beat-pair (0..3) the word belongs to.
    required Logic wrBeat,
    int dataBits = 16,
    super.name = 'wr_bl8_gearbox',
  }) {
    wrWord = addInput('wr_word', wrWord, width: 32);
    wrSel = addInput('wr_sel', wrSel, width: 4);
    wrBeat = addInput('wr_beat', wrBeat, width: 2);
    final dmLanes = dataBits ~/ 8;
    final dataLine = addOutput('data_line', width: dataBits * 8);
    final dmLine = addOutput('dm_line', width: dmLanes * 8);

    // A 32-bit bus word spans [beatsPerWord] DDR beats: 2 for a x16 lane (the
    // classic rise/fall pair) and 4 for a x8 lane (the low byte-lane bring-up).
    // The word occupies beats [wrBeat*beatsPerWord .. +beatsPerWord). Beat b
    // carries the word's chunk [localBeat] = b % beatsPerWord. For dataBits=16
    // this is byte-identical to the old rise/fall scheme (localBeat 0 = rise =
    // word[0:16], localBeat 1 = fall = word[16:32]). dataBits=8 adds the x8 case.
    final beatsPerWord = 32 ~/ dataBits;

    final beats = <Logic>[]; // beats[b] = dataBits-wide beat b
    final dmBeats = <Logic>[]; // dmBeats[b] = dmLanes-wide DM for beat b
    for (var b = 0; b < 8; b++) {
      final w = b ~/ beatsPerWord; // which word-slot this beat belongs to
      final localBeat = b % beatsPerWord; // which chunk of the 32-bit word
      final beatHit = wrBeat.eq(Const(w, width: 2));
      final chunk = wrWord.getRange(
        localBeat * dataBits,
        (localBeat + 1) * dataBits,
      );
      // Data beat: drive the word's chunk when this beat is the addressed one,
      // else 0 (DM masks it anyway).
      beats.add(mux(beatHit, chunk, Const(0, width: dataBits)));
      // DM per byte lane for this beat: masked (1) unless this is the addressed
      // beat AND the lane's byte-enable is set. Byte-enable index = localBeat's
      // lanes (x16: {0,1}=rise, {2,3}=fall, x8: {0,1,2,3} = the 4 beats).
      final dmBits = <Logic>[];
      for (var l = 0; l < dmLanes; l++) {
        final selBit = wrSel[localBeat * dmLanes + l];
        dmBits.add(~(beatHit & selBit));
      }
      dmBeats.add(dmBits.rswizzle());
    }
    dataLine <= [for (var b = 7; b >= 0; b--) beats[b]].swizzle();
    dmLine <= [for (var b = 7; b >= 0; b--) dmBeats[b]].swizzle();
  }
}
