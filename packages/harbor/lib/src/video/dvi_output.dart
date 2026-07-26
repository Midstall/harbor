import 'package:rohd/rohd.dart';

import '../peripherals/display.dart';
import 'dvi_transmitter.dart';
import 'video_timing.dart';

/// A self-contained DVI/HDMI test-pattern source for GPDI output.
///
/// Generates video timing for [timing], paints a vertical color-bar pattern,
/// TMDS-encodes the three channels (channel 0 carrying HSYNC/VSYNC during
/// blanking per DVI), and serializes all three plus the TMDS clock channel onto
/// four ECP5 outputs.
///
/// Needs two clocks: [pixelClk] (the timing's pixel clock) and [shiftClk] at 5x
/// (DDR gives the 10x bit rate). [gpdi] is `{clk, red, green, blue}` from MSB:
/// bit 3 is the clock channel, bits 2..0 are TMDS data channels 2..0. Drive each
/// onto the GPDI true pin with IO type `LVCMOS33D`.
class DviOutput extends Module {
  /// Four serialized TMDS lanes: bit3 clock, bit2 red, bit1 green, bit0 blue.
  Logic get gpdi => output('gpdi');

  final HarborDisplayTiming timing;

  DviOutput({
    required this.timing,
    required Logic pixelClk,
    required Logic shiftClk,
    required Logic pixelReset,
    required Logic shiftReset,
    super.name = 'dvi_output',
  }) : super(definitionName: 'DviOutput') {
    pixelClk = addInput('pixel_clk', pixelClk);
    shiftClk = addInput('shift_clk', shiftClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftReset = addInput('shift_reset', shiftReset);
    addOutput('gpdi', width: 4);

    final vtg = VideoTimingGenerator(
      timing: timing,
      clk: pixelClk,
      reset: pixelReset,
    );
    final x = vtg.x;
    final de = vtg.de;

    // Vertical color bars: three x bits pick one of eight colors.
    final red = (~x[7]).replicate(8);
    final green = (~x[8]).replicate(8);
    final blue = (~x[6]).replicate(8);

    final tx = DviTransmitter(
      pixelClk: pixelClk,
      shiftClk: shiftClk,
      pixelReset: pixelReset,
      shiftReset: shiftReset,
      de: de,
      hsync: vtg.hsync,
      vsync: vtg.vsync,
      red: red,
      green: green,
      blue: blue,
    );

    gpdi <= tx.gpdi;
  }
}
