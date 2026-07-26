import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// Captures a frame from the framebuffer display in simulation and checks the
/// rendered pixels match the source framebuffer. With word(x,y) = its linear
/// index, the captured ARGB pixel is 0xFF000000 | index.
void main() {
  test('captures the framebuffer as an ARGB frame', () async {
    const timing = HarborDisplayTiming(
      hActive: 4,
      hFrontPorch: 1,
      hSyncWidth: 1,
      hBackPorch: 1,
      vActive: 2,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 1000000,
    );
    // 4x2 framebuffer, each word = its linear index.
    final fb = [for (var i = 0; i < 8; i++) i];

    final frame = await captureFramebufferFrame(
      timing: timing,
      framebuffer: fb,
    );

    expect(frame.width, equals(4));
    expect(frame.height, equals(2));
    expect(frame.argb.length, equals(8));
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 4; x++) {
        final index = y * 4 + x;
        expect(
          frame.argb[index],
          equals(0xFF000000 | index),
          reason: 'pixel ($x,$y)',
        );
      }
    }
  });
}
