import 'package:flutter/material.dart';
import 'package:harbor/harbor.dart';

/// Paints a [CapturedFrame] as a virtual monitor.
///
/// Each framebuffer pixel is drawn as a scaled rectangle (nearest-neighbor
/// upscale), which keeps small simulated frames crisp. Wrap in a sized box or
/// [FittedBox] to control the on-screen size.
class VideoMonitor extends StatelessWidget {
  /// The frame to display.
  final CapturedFrame frame;

  /// On-screen pixels per framebuffer pixel.
  final double scale;

  const VideoMonitor({super.key, required this.frame, this.scale = 8});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(frame.width * scale, frame.height * scale),
      painter: _FramePainter(frame),
    );
  }
}

class _FramePainter extends CustomPainter {
  final CapturedFrame frame;

  _FramePainter(this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.width == 0 || frame.height == 0) return;
    final pw = size.width / frame.width;
    final ph = size.height / frame.height;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        paint.color = Color(frame.argb[y * frame.width + x] | 0xFF000000);
        // Slight overlap avoids seams between rects on fractional scales.
        canvas.drawRect(
          Rect.fromLTWH(x * pw, y * ph, pw + 0.5, ph + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      !identical(oldDelegate.frame, frame);
}
