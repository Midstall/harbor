import 'package:rohd/rohd.dart';

/// Common contract for a DDR PHY: the pin-side getters the
/// [HarborDdrController] wires to its pads, plus the read return path.
///
/// The controller and [DdrSequencer] are PHY-agnostic. A concrete PHY (ECP5,
/// Xilinx, ...) creates outputs with these names in its constructor and the
/// getters here expose them, so the controller can hold one `DdrPhy phy`
/// regardless of the target.
abstract class DdrPhy extends Module {
  DdrPhy({super.name});

  /// Read data back to the controller (one bus word) and its valid pulse.
  Logic get rdData => output('rd_data');
  Logic get rdValid => output('rd_valid');

  // SDRAM pin-side outputs.
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

  /// DQ/DQS drive values and output enables (the controller owns the tristate
  /// pads, since the inout ports live on its module boundary).
  Logic get dqOut => output('dq_out');
  Logic get dqOe => output('dq_oe');
  Logic get dqsOut => output('dqs_out');
  Logic get dqsNOut => output('dqs_n_out');
  Logic get dqsOe => output('dqs_oe');
}
