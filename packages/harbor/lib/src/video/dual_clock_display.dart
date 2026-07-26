import 'package:rohd/rohd.dart';

import '../peripherals/display.dart';
import 'display_output.dart';
import 'dual_clock_scanout.dart';
import 'dvi_transmitter.dart';
import 'video_timing.dart';

/// A framebuffer display that streams from shared main memory across clock
/// domains: pixel-domain timing + TMDS, system-domain framebuffer DMA.
///
/// The system-domain Wishbone master ([mStb] etc.) joins the SoC fabric
/// directly (no per-word CDC bridge). The clock crossing lives inside the
/// double line buffer. Emits parallel RGB+sync (for a VGA-style backend or
/// observation) and the four GPDI lanes. See [HarborFramebufferDisplay] for the
/// single-clock variant used by the test-pattern path.
class HarborDualClockDisplay extends Module {
  Logic get gpdi => output('gpdi');
  Logic get de => output('de');
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');
  Logic get x => output('x');
  Logic get y => output('y');
  Logic get pixelWord => output('pixel_word');
  Logic get underrun => output('underrun');

  /// Wishbone master (system domain) for framebuffer reads.
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final HarborDisplayTiming timing;
  final HarborDisplayInterface outputType;

  HarborDualClockDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic shiftClk,
    required Logic shiftReset,
    required Logic sysClk,
    required Logic sysReset,
    required Logic enable,
    required Logic fbBase,
    required Logic mDataIn,
    required Logic mAck,
    this.outputType = HarborDisplayInterface.hdmi,
    super.name = 'dual_clock_display',
  }) : super(definitionName: 'HarborDualClockDisplay') {
    requireDisplayOutputSupported(outputType);

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftClk = addInput('shift_clk', shiftClk);
    shiftReset = addInput('shift_reset', shiftReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    enable = addInput('enable', enable);
    fbBase = addInput('fb_base', fbBase, width: 32);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;
    addOutput('gpdi', width: 4);
    addOutput('de');
    addOutput('hsync');
    addOutput('vsync');
    addOutput('red', width: 8);
    addOutput('green', width: 8);
    addOutput('blue', width: 8);
    addOutput('x', width: hbits);
    addOutput('y', width: vbits);
    addOutput('pixel_word', width: 32);
    addOutput('underrun');
    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);

    final timingGen = VideoTimingGenerator(
      timing: timing,
      clk: pixelClk,
      reset: pixelReset,
    );
    final tx = timingGen.x;
    final ty = timingGen.y;
    final deActive = timingGen.de & enable;
    x <= tx;
    y <= ty;

    final frameStart = enable & tx.eq(0) & ty.eq(timing.vActive);
    final lineStart = enable & tx.eq(timing.hActive) & ty.lt(timing.vActive);

    final scanout = HarborDualClockScanout(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: tx,
      fbBase: fbBase,
      stride: Const(timing.hActive * 4, width: 32),
      wordsPerLine: Const(timing.hActive, width: 16),
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: timing.hActive,
    );

    mStb <= scanout.mStb;
    mCyc <= scanout.mCyc;
    mWe <= scanout.mWe;
    mAddr <= scanout.mAddr;
    mSel <= scanout.mSel;
    mDataOut <= scanout.mDataOut;
    underrun <= scanout.underrun;

    final word = scanout.pixel;
    pixelWord <= word;

    final r = mux(deActive, word.getRange(16, 24), Const(0, width: 8));
    final g = mux(deActive, word.getRange(8, 16), Const(0, width: 8));
    final b = mux(deActive, word.getRange(0, 8), Const(0, width: 8));
    red <= r;
    green <= g;
    blue <= b;
    de <= deActive;
    hsync <= timingGen.hsync;
    vsync <= timingGen.vsync;

    final transmitter = DviTransmitter(
      pixelClk: pixelClk,
      shiftClk: shiftClk, // 5x pixel clock from the SoC's display PLL
      pixelReset: pixelReset,
      shiftReset: shiftReset,
      de: deActive,
      hsync: timingGen.hsync,
      vsync: timingGen.vsync,
      red: r,
      green: g,
      blue: b,
    );
    gpdi <= transmitter.gpdi;
  }
}
