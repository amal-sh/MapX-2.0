import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/outdoor_models.dart';
import 'package:mapx/screens/map_viewer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Renders Exit and Entry between Origin and Destination for inter-building trip', (tester) async {
    final connection = BuildingConnection(
      a: const EntranceRef(building: 'Building A', floor: 0, label: 'Exit Door A'),
      b: const EntranceRef(building: 'Building B', floor: 0, label: 'Entry Door B'),
      distanceMeters: 45,
      durationSeconds: 30,
      route: const [(12.0, 77.0), (12.0001, 77.0001)],
    );

    SharedPreferences.setMockInitialValues({
      'building_connections': jsonEncode([connection.toJson()]),
      'map_Building A#0': jsonEncode({
        'name': 'Building A',
        'building': 'Building A',
        'floor': 0,
        'stepCount': 2,
        'segments': [
          {
            'floor': 0,
            'steps': [
              {'heading': 90.0, 'length': 1.0, 'floor': 0},
              {'heading': 90.0, 'length': 1.0, 'floor': 0},
            ],
          },
        ],
        'waypoints': [
          {
            'label': 'Room 1',
            'globalStepIndex': 0,
            'category': 'room',
            'floor': 0,
            'building': 'Building A',
          },
          {
            'label': 'Exit Door A',
            'globalStepIndex': 1,
            'category': 'entrance',
            'floor': 0,
            'building': 'Building A',
          },
        ],
        'walls': [],
      }),
      'map_Building B#0': jsonEncode({
        'name': 'Building B',
        'building': 'Building B',
        'floor': 0,
        'stepCount': 2,
        'segments': [
          {
            'floor': 0,
            'steps': [
              {'heading': 90.0, 'length': 1.0, 'floor': 0},
              {'heading': 90.0, 'length': 1.0, 'floor': 0},
            ],
          },
        ],
        'waypoints': [
          {
            'label': 'Entry Door B',
            'globalStepIndex': 0,
            'category': 'entrance',
            'floor': 0,
            'building': 'Building B',
          },
          {
            'label': 'Room 7',
            'globalStepIndex': 1,
            'category': 'room',
            'floor': 0,
            'building': 'Building B',
          },
        ],
        'walls': [],
      }),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: MapViewerScreen(
          mapKey: 'map_Building A#0',
          mapName: 'Building A',
          targetDestinationName: 'Room 7',
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Origin and Destination titles with building labels
    expect(find.text('Origin · Building A'), findsOneWidget);
    expect(find.text('Room 1'), findsOneWidget);

    expect(find.text('Destination · Building B'), findsOneWidget);
    expect(find.text('Room 7'), findsOneWidget);

    // Verify Exit from Building A
    expect(find.text('Exit from Building A'), findsOneWidget);
    expect(find.text('Exit Door A'), findsOneWidget);

    // Verify Outdoor walk step
    expect(find.text('Walk 45 m outside'), findsOneWidget);

    // Verify Entry to Building B
    expect(find.text('Entry to Building B'), findsOneWidget);
    expect(find.text('Entry Door B'), findsOneWidget);

    // Verify icons
    expect(find.byIcon(CupertinoIcons.square_arrow_right), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.arrow_right_to_line), findsOneWidget);
    expect(find.byIcon(Icons.directions_walk), findsWidgets);

    // Tap on Entry to Building B to switch viewed building
    await tester.tap(find.text('Entry to Building B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify top bar now shows BUILDING B
    expect(find.textContaining('BUILDING B'), findsWidgets);
  });
}
