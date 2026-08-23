import 'package:rohd/rohd.dart';

import '../soc/target.dart';
import 'tmds_serializer.dart';

import '../peripherals/display.dart';
import 'display_output.dart';
import 'double_buffer_scanout.dart';
import 'dvi_transmitter.dart';
import 'video_timing.dart';

/// A framebuffer display datapath: timing generator + double-buffer scanout DMA
/// + RGB extraction + DVI/HDMI transmitter.
///
/// Reads an `0xXXRRGGBB` framebuffer from memory (one 32-bit word per pixel)
/// over a Wishbone-style master, scans it out for [timing], and emits both the
/// parallel RGB+sync (for a VGA-style backend or observation) and the four
/// serialized GPDI lanes. The whole datapath is in the pixel clock domain. The
/// system-bus clock crossing is handled outside via a Wishbone CDC bridge.
///
/// `frameStart` is pulsed at the top of vertical blanking to prime the line
/// buffers before the next frame. `lineStart` is pulsed during each active
/// line's horizontal blanking to swap to the prefetched line and fetch the
/// next, so the buffer is settled before the next line's first pixel.
class HarborFramebufferDisplay extends Module {
  /// Serialized TMDS lanes ({clk, red, green, blue} from MSB).
  Logic get gpdi => output('gpdi');

  /// The four complement lanes, present only on a target that drives its own
  /// ([TmdsSerializer.needsComplement]).
  Logic get gpdiN => output('gpdi_n');

  /// Parallel video (for a VGA-style backend or observation).
  Logic get de => output('de');
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  /// Current scan coordinates and the raw framebuffer word (observability).
  Logic get x => output('x');
  Logic get y => output('y');
  Logic get pixelWord => output('pixel_word');

  /// Wishbone master (framebuffer reads).
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final HarborDisplayTiming timing;

  /// The display output type (DVI/HDMI today).
  final HarborDisplayInterface outputType;

  HarborFramebufferDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic shiftClk,
    required Logic shiftReset,
    required Logic enable,
    required Logic fbBase,
    required Logic mDataIn,
    required Logic mAck,
    this.outputType = HarborDisplayInterface.hdmi,
    required HarborDeviceTarget target,
    super.name = 'framebuffer_display',
  }) : super(definitionName: 'HarborFramebufferDisplay') {
    // dvi/hdmi share the TMDS transmitter. Reject types without a backend.
    requireDisplayOutputSupported(outputType);

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftClk = addInput('shift_clk', shiftClk);
    shiftReset = addInput('shift_reset', shiftReset);
    enable = addInput('enable', enable);
    fbBase = addInput('fb_base', fbBase, width: 32);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;
    addOutput('gpdi', width: 4);
    final tmdsComplement = TmdsSerializer.needsComplement(target);
    if (tmdsComplement) {
      addOutput('gpdi_n', width: 4);
    }
    addOutput('de');
    addOutput('hsync');
    addOutput('vsync');
    addOutput('red', width: 8);
    addOutput('green', width: 8);
    addOutput('blue', width: 8);
    addOutput('x', width: hbits);
    addOutput('y', width: vbits);
    addOutput('pixel_word', width: 32);
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

    // frameStart: one pulse at the top of vertical blanking, leaving the whole
    // blanking period to prime the next frame's first two lines.
    final frameStart = enable & tx.eq(0) & ty.eq(timing.vActive);
    // lineStart: pulsed in each active line's horizontal blanking (x == hActive)
    // so the buffer swap settles before the next line's first pixel.
    final lineStart = enable & tx.eq(timing.hActive) & ty.lt(timing.vActive);

    final scanout = HarborDoubleBufferScanout(
      clk: pixelClk,
      reset: pixelReset,
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

    // Master port passthrough.
    mStb <= scanout.mStb;
    mCyc <= scanout.mCyc;
    mWe <= scanout.mWe;
    mAddr <= scanout.mAddr;
    mSel <= scanout.mSel;
    mDataOut <= scanout.mDataOut;

    final word = scanout.pixel;
    pixelWord <= word;

    // 0xXXRRGGBB, blanked outside the active region.
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
      target: target,
      pixelClk: pixelClk,
      shiftClk: shiftClk,
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
    if (tmdsComplement) {
      gpdiN <= transmitter.gpdiN;
    }
  }
}
