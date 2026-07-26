import '../peripherals/display.dart';

/// Output types that currently have a built backend.
///
/// DVI and HDMI both ride the TMDS transmitter ([DviTransmitter]). HDMI's
/// signaling is DVI-compatible (audio/CEC are a later HDMI-only extra). VGA
/// (parallel RGB to a resistor DAC) and DisplayPort/LVDS/MIPI are accepted by
/// the type system so genip can offer them, but are not driven yet.
const Set<HarborDisplayInterface> _supportedDisplayOutputs = {
  HarborDisplayInterface.dvi,
  HarborDisplayInterface.hdmi,
};

/// Whether Harbor can currently drive [type].
bool isDisplayOutputSupported(HarborDisplayInterface type) =>
    _supportedDisplayOutputs.contains(type);

/// Throws an [UnsupportedError] if [type] has no backend yet.
void requireDisplayOutputSupported(HarborDisplayInterface type) {
  if (!isDisplayOutputSupported(type)) {
    final supported = _supportedDisplayOutputs.map((e) => e.name).join(', ');
    throw UnsupportedError(
      'Display output "${type.name}" is not implemented yet. '
      'Supported: $supported. (VGA and DisplayPort are planned.)',
    );
  }
}
