import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// ECP5 EHXPLLL - Primary PLL.
class Ecp5Ehxplll extends BridgeModule {
  Ecp5Ehxplll({
    required int clkiDiv,
    required int clkfbDiv,
    required int clkopDiv,
    required Logic clk,
    required Logic clkfb,
    Logic? rst,
    String feedbackPath = 'CLKOP',
    // Optional secondary output: same rules as CLKOP, with a static phase
    // shift in VCO cycles (CPHASE). A 90-degree shift of the CLKOP frequency
    // is clkosDiv/4 (the DDR PHY uses this for centered write data).
    int? clkosDiv,
    int clkosCphase = 0,
    super.name = 'pll',
  }) : super('EHXPLLL', isSystemVerilogLeaf: true) {
    clk = addInput('CLKI', clk);
    clkfb = addInput('CLKFB', clkfb);
    addInput('RST', rst ?? Const(0));
    addOutput('CLKOP');
    addOutput('CLKOS');
    addOutput('CLKOS2');
    addOutput('CLKOS3');
    addOutput('LOCK');
    addOutput('INTLOCK');

    createParameter('CLKI_DIV', '$clkiDiv');
    createParameter('CLKFB_DIV', '$clkfbDiv');
    createParameter('CLKOP_DIV', '$clkopDiv');
    createParameter('FEEDBK_PATH', '"$feedbackPath"');
    if (clkosDiv != null) {
      createParameter('CLKOS_ENABLE', '"ENABLED"');
      createParameter('CLKOS_DIV', '$clkosDiv');
      createParameter('CLKOS_CPHASE', '$clkosCphase');
    }
  }
}

/// ECP5 DCCA - Dynamic clock control with clock mux.
class Ecp5Dcca extends BridgeModule {
  Ecp5Dcca({super.name = 'dcca'}) : super('DCCA', isSystemVerilogLeaf: true) {
    createPort('CLKI', PortDirection.input);
    createPort('CE', PortDirection.input);
    addOutput('CLKO');
  }
}

/// ECP5 BB - Bidirectional I/O buffer.
class Ecp5Bb extends BridgeModule {
  Ecp5Bb({super.name = 'bb'}) : super('BB', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    createPort('T', PortDirection.input);
    addOutput('O');
    createPort('B', PortDirection.inOut);
  }
}

/// ECP5 IB - Input buffer.
class Ecp5Ib extends BridgeModule {
  Ecp5Ib({super.name = 'ib'}) : super('IB', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// ECP5 OB - Output buffer.
class Ecp5Ob extends BridgeModule {
  Ecp5Ob({super.name = 'ob'}) : super('OB', isSystemVerilogLeaf: true) {
    createPort('I', PortDirection.input);
    addOutput('O');
  }
}

/// ECP5 DP16KD - 16Kbit dual-port block RAM.
///
/// Ports use per-bit naming to match Yosys's cells_sim.v definition.
class Ecp5Dp16kd extends BridgeModule {
  Ecp5Dp16kd({
    required Logic clkA,
    required Logic ceA,
    required Logic weA,
    required Logic oceA,
    required Logic rstA,
    required Logic adA,
    required Logic diA,
    required Logic clkB,
    required Logic ceB,
    required Logic weB,
    required Logic oceB,
    required Logic rstB,
    required Logic adB,
    required Logic diB,
    Logic? csA,
    Logic? csB,
    // Port data width (18, 9, 4, 2, or 1). x9 yields one byte lane per BRAM,
    // which is how byte-granular write enables are built (x18 has no byte
    // masks). In sub-18 widths the word address occupies the UPPER AD bits
    // (x9: AD[13:3], low bits zero).
    int dataWidthA = 18,
    int dataWidthB = 18,
    super.name = 'bram',
  }) : super('DP16KD', isSystemVerilogLeaf: true) {
    createParameter('DATA_WIDTH_A', '$dataWidthA');
    createParameter('DATA_WIDTH_B', '$dataWidthB');
    // Port A inputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addInput('DIA$i', diA.width > i ? diA[i] : Const(0));
    }
    for (var i = 0; i < 14; i++) {
      addInput('ADA$i', adA.width > i ? adA[i] : Const(0));
    }
    addInput('CLKA', clkA);
    addInput('CEA', ceA);
    addInput('OCEA', oceA);
    addInput('WEA', weA);
    addInput('RSTA', rstA);
    for (var i = 0; i < 3; i++) {
      addInput('CSA$i', csA != null && csA.width > i ? csA[i] : Const(0));
    }

    // Port A outputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addOutput('DOA$i');
    }

    // Port B inputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addInput('DIB$i', diB.width > i ? diB[i] : Const(0));
    }
    for (var i = 0; i < 14; i++) {
      addInput('ADB$i', adB.width > i ? adB[i] : Const(0));
    }
    addInput('CLKB', clkB);
    addInput('CEB', ceB);
    addInput('OCEB', oceB);
    addInput('WEB', weB);
    addInput('RSTB', rstB);
    for (var i = 0; i < 3; i++) {
      addInput('CSB$i', csB != null && csB.width > i ? csB[i] : Const(0));
    }

    // Port B outputs (per-bit)
    for (var i = 0; i < 18; i++) {
      addOutput('DOB$i');
    }
  }

  /// Port A read data as a bus.
  Logic get doA => [for (var i = 17; i >= 0; i--) output('DOA$i')].swizzle();

  /// Port B read data as a bus.
  Logic get doB => [for (var i = 17; i >= 0; i--) output('DOB$i')].swizzle();
}

/// ECP5 DTR - Die temperature readout.
class Ecp5Dtr extends BridgeModule {
  Ecp5Dtr({super.name = 'dtr'}) : super('DTR', isSystemVerilogLeaf: true) {
    createPort('STARTPULSE', PortDirection.input);
    addOutput('DTROUT8', width: 8);
  }
}

/// ECP5 ODDRX1F - 1:2 gearing DDR output register. [d0] launches on the
/// rising edge of [sclk], [d1] on the falling edge.
class Ecp5Oddrx1f extends BridgeModule {
  Logic get q => output('Q');

  Ecp5Oddrx1f({
    required Logic sclk,
    required Logic rst,
    required Logic d0,
    required Logic d1,
    super.name = 'oddr',
  }) : super('ODDRX1F', isSystemVerilogLeaf: true) {
    addInput('SCLK', sclk);
    addInput('RST', rst);
    addInput('D0', d0);
    addInput('D1', d1);
    addOutput('Q');
  }
}

/// ECP5 IDDRX1F - 1:2 gearing DDR input register. [q0] is the bit captured
/// on the rising edge of [sclk], [q1] the falling-edge bit.
class Ecp5Iddrx1f extends BridgeModule {
  Logic get q0 => output('Q0');
  Logic get q1 => output('Q1');

  Ecp5Iddrx1f({
    required Logic sclk,
    required Logic rst,
    required Logic d,
    super.name = 'iddr',
  }) : super('IDDRX1F', isSystemVerilogLeaf: true) {
    addInput('SCLK', sclk);
    addInput('RST', rst);
    addInput('D', d);
    addOutput('Q0');
    addOutput('Q1');
  }
}

/// ECP5 DELAYG - static input delay line (128 taps of ~25ps). Used to move
/// the read-data sampling point into the eye; the tap count is fixed at
/// synthesis ([delValue]), so read training picks a value per board/build.
class Ecp5Delayg extends BridgeModule {
  Logic get z => output('Z');

  Ecp5Delayg({required Logic a, int delValue = 0, super.name = 'delayg'})
    : super('DELAYG', isSystemVerilogLeaf: true) {
    createParameter('DEL_MODE', '"USER_DEFINED"');
    createParameter('DEL_VALUE', '$delValue');
    addInput('A', a);
    addOutput('Z');
  }
}

/// ECP5 JTAGG - JTAG interface access.
class Ecp5Jtagg extends BridgeModule {
  Ecp5Jtagg({super.name = 'jtag'}) : super('JTAGG', isSystemVerilogLeaf: true) {
    addOutput('JTCK');
    addOutput('JTDI');
    addOutput('JSHIFT');
    addOutput('JUPDATE');
    addOutput('JRSTN');
    addOutput('JCE1');
    addOutput('JCE2');
    addOutput('JRTI1');
    addOutput('JRTI2');
    createPort('JTDO1', PortDirection.input);
    createPort('JTDO2', PortDirection.input);
  }
}
