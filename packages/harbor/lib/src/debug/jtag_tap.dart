import 'package:rohd/rohd.dart';

/// JTAG TAP controller states (IEEE 1149.1 state machine).
enum JtagState {
  testLogicReset,
  runTestIdle,
  selectDrScan,
  captureDr,
  shiftDr,
  exit1Dr,
  pauseDr,
  exit2Dr,
  updateDr,
  selectIrScan,
  captureIr,
  shiftIr,
  exit1Ir,
  pauseIr,
  exit2Ir,
  updateIr,
}

/// A JTAG instruction registered with the TAP controller.
class JtagInstruction {
  /// Instruction opcode (IR value).
  final int opcode;

  /// Human-readable name.
  final String name;

  /// Width of the data register for this instruction.
  final int drWidth;

  const JtagInstruction({
    required this.opcode,
    required this.name,
    required this.drWidth,
  });
}

/// IEEE 1149.1 JTAG TAP (Test Access Port) controller.
///
/// Implements the standard 16-state TAP FSM, instruction register,
/// and data register shifting. Instructions are added via
/// [addInstruction] before build.
///
/// Standard instructions:
/// - BYPASS (all 1s): single-bit bypass register
/// - IDCODE (0x01): 32-bit device identification
///
/// ```dart
/// final tap = JtagTapController(
///   irWidth: 5,
///   idcode: 0x10001FFF,
/// );
/// tap.addInstruction(JtagInstruction(
///   opcode: 0x11,
///   name: 'DMI_ACCESS',
///   drWidth: 41,
/// ));
/// ```
class JtagTapController extends Module {
  /// Instruction register width.
  final int irWidth;

  /// IDCODE value (32-bit IEEE device ID).
  final int idcode;

  final List<JtagInstruction> _instructions = [];

  /// Current TAP state (encoded).
  Logic get state => output('state');

  /// Current instruction register value.
  Logic get instruction => output('instruction');

  /// Whether the TAP is in shift-DR state.
  Logic get inShiftDr => output('in_shift_dr');

  /// Whether the TAP is in capture-DR state.
  Logic get inCaptureDr => output('in_capture_dr');

  /// Whether the TAP is in update-DR state.
  Logic get inUpdateDr => output('in_update_dr');

  /// Whether the TAP is in reset state.
  Logic get inReset => output('in_reset');

  /// DR shift register output (directly readable per-instruction).
  Logic get drTdo => output('dr_tdo');

  /// Adds a custom instruction to this TAP controller.
  ///
  /// Must be called before the module is built.
  void addInstruction(JtagInstruction instr) {
    _instructions.add(instr);
  }

  JtagTapController({
    required this.irWidth,
    this.idcode = 0x00000000,
    super.name = 'jtag_tap',
  }) : super(definitionName: 'JtagTapController') {
    // JTAG pins
    final tck = addInput('tck', Logic());
    final tms = addInput('tms', Logic());
    final tdi = addInput('tdi', Logic());
    final trstN = addInput('trst_n', Logic());
    final tdo = addOutput('tdo');

    // State outputs
    addOutput('state', width: 4);
    addOutput('instruction', width: irWidth);
    addOutput('in_shift_dr');
    addOutput('in_capture_dr');
    addOutput('in_update_dr');
    addOutput('in_reset');
    addOutput('dr_tdo');

    // Internal state
    final stateReg = Logic(name: 'state_reg', width: 4);
    final stateNext = Logic(name: 'state_next', width: 4);
    final irShift = Logic(name: 'ir_shift', width: irWidth);
    final irReg = Logic(name: 'ir_reg', width: irWidth);
    final bypass = Logic(name: 'bypass');
    final idcodeShift = Logic(name: 'idcode_shift', width: 32);

    // State encoding
    const sReset = 0;
    const sIdle = 1;
    const sDrSelect = 2;
    const sDrCapture = 3;
    const sDrShift = 4;
    const sDrExit1 = 5;
    const sDrPause = 6;
    const sDrExit2 = 7;
    const sDrUpdate = 8;
    const sIrSelect = 9;
    const sIrCapture = 10;
    const sIrShift = 11;
    const sIrExit1 = 12;
    const sIrPause = 13;
    const sIrExit2 = 14;
    const sIrUpdate = 15;

    // TAP FSM next-state logic
    // Helper: each state transitions based on TMS
    CaseItem fsmCase(int from, int tmsHigh, int tmsLow) =>
        CaseItem(Const(from, width: 4), [
          If(
            tms,
            then: [stateNext < Const(tmsHigh, width: 4)],
            orElse: [stateNext < Const(tmsLow, width: 4)],
          ),
        ]);

    Combinational([
      stateNext < Const(sReset, width: 4),
      Case(stateReg, [
        fsmCase(sReset, sReset, sIdle),
        fsmCase(sIdle, sDrSelect, sIdle),
        fsmCase(sDrSelect, sIrSelect, sDrCapture),
        fsmCase(sDrCapture, sDrExit1, sDrShift),
        fsmCase(sDrShift, sDrExit1, sDrShift),
        fsmCase(sDrExit1, sDrUpdate, sDrPause),
        fsmCase(sDrPause, sDrExit2, sDrPause),
        fsmCase(sDrExit2, sDrUpdate, sDrShift),
        fsmCase(sDrUpdate, sDrSelect, sIdle),
        fsmCase(sIrSelect, sReset, sIrCapture),
        fsmCase(sIrCapture, sIrExit1, sIrShift),
        fsmCase(sIrShift, sIrExit1, sIrShift),
        fsmCase(sIrExit1, sIrUpdate, sIrPause),
        fsmCase(sIrPause, sIrExit2, sIrPause),
        fsmCase(sIrExit2, sIrUpdate, sIrShift),
        fsmCase(sIrUpdate, sDrSelect, sIdle),
      ]),
    ]);

    // State register + IR/DR shifting
    Sequential(tck, [
      If(
        ~trstN,
        then: [
          stateReg < Const(sReset, width: 4),
          irReg < Const((1 << irWidth) - 1, width: irWidth), // BYPASS on reset
          irShift < Const(0, width: irWidth),
          bypass < Const(0),
          idcodeShift < Const(idcode, width: 32),
        ],
        orElse: [
          stateReg < stateNext,

          // IR operations
          If(
            stateReg.eq(Const(sIrCapture, width: 4)),
            then: [
              irShift < Const(0x01, width: irWidth), // capture value per spec
            ],
          ),
          If(
            stateReg.eq(Const(sIrShift, width: 4)),
            then: [
              irShift <
                  (tdi.zeroExtend(irWidth) <<
                          Const(irWidth - 1, width: irWidth)) |
                      (irShift >> Const(1, width: irWidth)),
            ],
          ),
          If(stateReg.eq(Const(sIrUpdate, width: 4)), then: [irReg < irShift]),

          // DR operations: bypass
          If(stateReg.eq(Const(sDrShift, width: 4)), then: [bypass < tdi]),

          // DR operations: IDCODE
          If(
            stateReg.eq(Const(sDrCapture, width: 4)) &
                irReg.eq(Const(0x01, width: irWidth)),
            then: [idcodeShift < Const(idcode, width: 32)],
          ),
          If(
            stateReg.eq(Const(sDrShift, width: 4)) &
                irReg.eq(Const(0x01, width: irWidth)),
            then: [
              idcodeShift <
                  (tdi.zeroExtend(32) << Const(31, width: 32)) |
                      (idcodeShift >> Const(1, width: 32)),
            ],
          ),
        ],
      ),
    ]);

    // TDO mux
    final isBypass = irReg.eq(Const((1 << irWidth) - 1, width: irWidth));
    final isIdcode = irReg.eq(Const(0x01, width: irWidth));

    Combinational([
      tdo < Const(0),
      drTdo < Const(0),
      If(
        stateReg.eq(Const(sIrShift, width: 4)),
        then: [tdo < irShift[0]],
        orElse: [
          If(
            stateReg.eq(Const(sDrShift, width: 4)),
            then: [
              If(
                isIdcode,
                then: [tdo < idcodeShift[0], drTdo < idcodeShift[0]],
                orElse: [
                  If(
                    isBypass,
                    then: [tdo < bypass, drTdo < bypass],
                    orElse: [tdo < Const(0), drTdo < Const(0)],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // State outputs
    state <= stateReg;
    instruction <= irReg;
    inShiftDr <= stateReg.eq(Const(sDrShift, width: 4));
    inCaptureDr <= stateReg.eq(Const(sDrCapture, width: 4));
    inUpdateDr <= stateReg.eq(Const(sDrUpdate, width: 4));
    inReset <= stateReg.eq(Const(sReset, width: 4));
  }
}
