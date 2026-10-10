import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mapx/screens/map_viewer_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'map_Science Complex#1': jsonEncode({
        'building': 'Science Complex',
        'floor': 1,
        'stepCount': 5,
        'nodes': [
          {'index': 0, 'heading': 0.0, 'east': 0.0, 'north': 0.0},
          {'index': 1, 'heading': 90.0, 'east': 3.0, 'north': 0.0},
          {'index': 2, 'heading': 0.0, 'east': 3.0, 'north': 3.8},
        ],
        'waypoints': [
          {
            'label': 'Entrance Lobby',
            'globalStepIndex': 0,
            'category': 'room',
            'floor': 1,
            'building': 'Science Complex',
          },
          {
            'label': 'Robotics Lab 304',
            'globalStepIndex': 5,
            'category': 'room',
            'floor': 1,
            'building': 'Science Complex',
          },
        ],
        'walls': [],
      }),
    });
  });

  testWidgets('Renders redesigned MapViewerScreen 2D overview matching reference layout', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MapViewerScreen(
          mapKey: 'map_Science Complex#1',
          mapName: 'Science Complex',
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify header title and subtitle
    expect(find.text('Route Overview'), findsOneWidget);
    expect(find.textContaining('SCIENCE COMPLEX'), findsOneWidget);

    // Verify Origin and Destination card
    expect(find.text('Origin'), findsOneWidget);
    expect(find.text('Destination'), findsOneWidget);
    expect(find.text('Entrance Lobby'), findsOneWidget);
    expect(find.text('Robotics Lab 304'), findsOneWidget);
    expect(find.text('F1'), findsWidgets);
    expect(find.text('Level 1'), findsWidgets);

    // Verify Metrics Pill row
    expect(find.textContaining('steps'), findsWidgets);
    expect(find.textContaining('Nodes'), findsOneWidget);
    expect(find.textContaining('m'), findsWidgets);

    // Verify map scale overlay
    expect(find.text('1 m grid'), findsOneWidget);

    // Verify floating controls
    expect(find.text('N'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.plus), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.minus), findsOneWidget);

    // Verify Start AR Navigation button and accessible options
    expect(find.text('Start AR Navigation'), findsOneWidget);
    expect(find.text('Accessible route options'), findsOneWidget);
  });

  testWidgets('Tapping Accessible route options opens route options bottom sheet', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MapViewerScreen(
          mapKey: 'map_Science Complex#1',
          mapName: 'Science Complex',
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Tap Accessible route options
    await tester.tap(find.text('Accessible route options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Route & Accessibility Options'), findsOneWidget);
    expect(find.text('Elevator / Lift'), findsOneWidget);
    expect(find.text('Stairs'), findsOneWidget);
    expect(find.text('Edit Map'), findsNothing);
    expect(find.textContaining('Sensor AR'), findsOneWidget);
  });
}
