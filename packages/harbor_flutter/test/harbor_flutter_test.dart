import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_flutter/harbor_flutter.dart';

void main() {
  testWidgets('VideoMonitor paints a frame without error', (tester) async {
    const frame = CapturedFrame(
      width: 2,
      height: 2,
      argb: [0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: VideoMonitor(frame: frame)),
        ),
      ),
    );
    expect(find.byType(VideoMonitor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
