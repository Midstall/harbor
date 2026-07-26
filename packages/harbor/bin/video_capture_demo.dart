/// Captures a frame from the framebuffer display in simulation and writes it as
/// a binary PPM (P6), so the video generator's output can be viewed directly.
///
/// Usage: dart run bin/video_capture_demo.dart [out.ppm]
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';

Future<void> main(List<String> args) async {
  const w = 32;
  const h = 24;
  const timing = HarborDisplayTiming(
    hActive: w,
    hFrontPorch: 4,
    hSyncWidth: 4,
    hBackPorch: 4,
    vActive: h,
    vFrontPorch: 2,
    vSyncWidth: 2,
    vBackPorch: 2,
    pixelClock: 25000000,
  );
  // Red ramps across, green down, blue fixed.
  final fb = [
    for (var y = 0; y < h; y++)
      for (var x = 0; x < w; x++)
        ((x * 255 ~/ w) << 16) | ((y * 255 ~/ h) << 8) | 0x80,
  ];

  final frame = await captureFramebufferFrame(timing: timing, framebuffer: fb);

  final bytes = BytesBuilder();
  bytes.add('P6\n${frame.width} ${frame.height}\n255\n'.codeUnits);
  for (final argb in frame.argb) {
    bytes
      ..addByte((argb >> 16) & 0xFF)
      ..addByte((argb >> 8) & 0xFF)
      ..addByte(argb & 0xFF);
  }
  final out = File(args.isNotEmpty ? args[0] : 'frame.ppm');
  out.writeAsBytesSync(bytes.toBytes());
  stdout.writeln('wrote ${out.path} (${frame.width}x${frame.height})');
}
