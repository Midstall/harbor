import 'package:rohd/rohd.dart';

import '../soc/target.dart';

import 'tmds_encoder.dart';
import 'tmds_serializer.dart';

/// TMDS backend for DVI/HDMI: turns parallel RGB plus HSYNC/VSYNC/DE into the
/// four serialized GPDI lanes.
///
/// Output-source agnostic, so it serves both the test-pattern [DviOutput] and a
/// framebuffer display controller. TMDS-encodes the three channels (channel 0
/// carries HSYNC/VSYNC during blanking per DVI), adds the fixed TMDS clock
/// channel, and serializes all four.
///
/// Needs [pixelClk] (the pixel clock) and [shiftClk] at 5x, each with its own
/// synchronized reset. [gpdi] is `{clk, red, green, blue}` from MSB: bit 3 is
/// the clock channel, bits 2..0 are TMDS data channels 2..0. HDMI uses the same
/// signaling as DVI (audio/data islands are a later HDMI-only extra).
class DviTransmitter extends Module {
  /// Four serialized TMDS lanes: bit3 clock, bit2 red, bit1 green, bit0 blue.
  Logic get gpdi => output('gpdi');

  /// The four complement lanes, in the same order as [gpdi]. Present only on a
  /// target that drives its own complements ([TmdsSerializer.needsComplement]).
  Logic get gpdiN => output('gpdi_n');

  DviTransmitter({
    required Logic pixelClk,
    required Logic shiftClk,
    required Logic pixelReset,
    required Logic shiftReset,
    required Logic de,
    required Logic hsync,
    required Logic vsync,
    required Logic red,
    required Logic green,
    required Logic blue,
    required HarborDeviceTarget target,
    super.name = 'dvi_transmitter',
  }) : super(definitionName: 'DviTransmitter') {
    pixelClk = addInput('pixel_clk', pixelClk);
    shiftClk = addInput('shift_clk', shiftClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftReset = addInput('shift_reset', shiftReset);
    de = addInput('de', de);
    hsync = addInput('hsync', hsync);
    vsync = addInput('vsync', vsync);
    red = addInput('red', red, width: 8);
    green = addInput('green', green, width: 8);
    blue = addInput('blue', blue, width: 8);
    addOutput('gpdi', width: 4);
    final complement = TmdsSerializer.needsComplement(target);
    if (complement) {
      addOutput('gpdi_n', width: 4);
    }

    Logic encode(Logic data, Logic ctrl) => TmdsEncoder(
      clk: pixelClk,
      reset: pixelReset,
      de: de,
      data: data,
      ctrl: ctrl,
    ).q;

    // Channel 0 carries the sync signals during blanking ({c1, c0} = {vsync,
    // hsync}), the other channels carry control 0.
    final sym0 = encode(blue, [vsync, hsync].swizzle());
    final sym1 = encode(green, Const(0, width: 2));
    final sym2 = encode(red, Const(0, width: 2));

    TmdsSerializer serialize(Logic symbol) => TmdsSerializer(
      shiftClk: shiftClk,
      reset: shiftReset,
      symbol: symbol,
      target: target,
    );

    final ch0 = serialize(sym0);
    final ch1 = serialize(sym1);
    final ch2 = serialize(sym2);
    // TMDS clock channel: a fixed 0b1111100000 pattern is the pixel clock.
    final chClk = serialize(Const(0x3E0, width: 10));

    gpdi <= [chClk.q, ch2.q, ch1.q, ch0.q].swizzle();
    if (complement) {
      gpdiN <= [chClk.qn, ch2.qn, ch1.qn, ch0.qn].swizzle();
    }
  }
}
