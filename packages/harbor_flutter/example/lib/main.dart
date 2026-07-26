import 'package:flutter/material.dart';
import 'package:harbor_flutter/harbor_flutter.dart';

void main() => runApp(const HarborVideoApp());

const _w = 32;
const _h = 24;

/// A tiny 32x24 mode so the simulation renders a frame quickly.
const _timing = HarborDisplayTiming(
  hActive: _w,
  hFrontPorch: 4,
  hSyncWidth: 4,
  hBackPorch: 4,
  vActive: _h,
  vFrontPorch: 2,
  vSyncWidth: 2,
  vBackPorch: 2,
  pixelClock: 25000000,
);

/// A colorful 0xXXRRGGBB framebuffer: red ramps across, green down, blue fixed.
List<int> _pattern() => [
  for (var y = 0; y < _h; y++)
    for (var x = 0; x < _w; x++)
      ((x * 255 ~/ _w) << 16) | ((y * 255 ~/ _h) << 8) | 0x80,
];

class HarborVideoApp extends StatelessWidget {
  const HarborVideoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Harbor Video',
    theme: ThemeData.dark(useMaterial3: true),
    home: const VideoDemoScreen(),
  );
}

class VideoDemoScreen extends StatefulWidget {
  const VideoDemoScreen({super.key});

  @override
  State<VideoDemoScreen> createState() => _VideoDemoScreenState();
}

class _VideoDemoScreenState extends State<VideoDemoScreen> {
  late final Future<CapturedFrame> _frame = captureFramebufferFrame(
    timing: _timing,
    framebuffer: _pattern(),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Harbor video generator (simulated)')),
    body: Center(
      child: FutureBuilder<CapturedFrame>(
        future: _frame,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Simulating the display RTL...'),
              ],
            );
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: FittedBox(child: VideoMonitor(frame: snap.data!, scale: 12)),
          );
        },
      ),
    ),
  );
}
