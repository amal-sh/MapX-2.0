import 'dart:ui' show PictureRecorder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/main.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/widgets/navigation/ar_path_painter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('MapXApp smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MapXApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('MapX Dashboard'), findsOneWidget);
  });

  test('ArPathPainter floor-anchored direction arrows paint test', () {
    final route = [
      PathNode(0, 0, 0.0, 0.0),
      PathNode(1, 0, 0.0, 3.0),
      PathNode(2, 90, 3.0, 3.0),
    ];

    final painter = ArPathPainter(
      route: route,
      liveEast: 0.0,
      liveNorth: 0.0,
      headingDegrees: 0.0,
      tiltDegrees: 45.0,
      animationProgress: 0.5,
      startLabel: 'Entrance',
      destinationLabel: 'Lab 1',
      cameraHeight: 1.4,
      verticalFovDegrees: 60.0,
      liveProgress: 0.0,
    );

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(1080, 1920);

    // Painting should succeed without any throws or unhandled errors
    expect(() => painter.paint(canvas, size), returnsNormally);
    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });
}

