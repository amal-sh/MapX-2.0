import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/models/outdoor_models.dart';
import 'package:mapx/screens/admin_studio_screen.dart';
import 'package:mapx/screens/connector_links_screen.dart';
import 'package:mapx/screens/outdoor_map_screen.dart';
import 'package:mapx/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
      'AdminStudioScreen tapping Connector Links navigates to ConnectorLinksScreen',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(
        home: AdminStudioScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connector Links'), findsOneWidget);
    await tester.tap(find.text('Connector Links'));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectorLinksScreen), findsOneWidget);
    expect(find.text('ADMIN'), findsWidgets);
  });

  testWidgets(
      'OutdoorMapScreen displays linked buildings in read-only mode without delete/add buttons',
      (WidgetTester tester) async {
    final connection = BuildingConnection(
      a: const EntranceRef(building: 'Building Alpha', floor: 1, label: 'Main Door'),
      b: const EntranceRef(building: 'Building Beta', floor: 1, label: 'East Gate'),
      distanceMeters: 45,
      durationSeconds: 35,
      route: const [(12.97, 77.59), (12.971, 77.591)],
    );

    final mapAlpha = {
      'name': 'Building Alpha',
      'floor': 1,
      'latitude': 12.97,
      'longitude': 77.59,
      'waypoints': [
        Waypoint(
          0,
          'Main Door',
          floor: 1,
          category: Waypoint.entranceCategory,
          latitude: 12.97,
          longitude: 77.59,
        ).toJson(),
      ],
    };

    SharedPreferences.setMockInitialValues({
      'map_Building Alpha#1': jsonEncode(mapAlpha),
      'building_connections': jsonEncode([connection.toJson()]),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: OutdoorMapScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap on Building Alpha pin to open bottom sheet
    await tester.tap(find.text('Building Alpha'));
    await tester.pumpAndSettle();

    // Verifies linked building info is visible
    expect(find.text('Linked buildings'), findsOneWidget);
    expect(find.text('Building Beta'), findsOneWidget);
    expect(find.textContaining('From Main Door to East Gate'), findsOneWidget);

    // Verify there are NO edit or delete (link_off) or add-link buttons in OutdoorMapScreen
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.text('Link to another building'), findsNothing);
  });

  testWidgets(
      'ConnectorLinksScreen provides option to link to building and remove links',
      (WidgetTester tester) async {
    final connection = BuildingConnection(
      a: const EntranceRef(building: 'Building Alpha', floor: 1, label: 'Main Door'),
      b: const EntranceRef(building: 'Building Beta', floor: 1, label: 'East Gate'),
      distanceMeters: 45,
      durationSeconds: 35,
      route: const [(12.97, 77.59), (12.971, 77.591)],
    );

    final mapAlpha = {
      'name': 'Building Alpha',
      'floor': 1,
      'latitude': 12.97,
      'longitude': 77.59,
      'waypoints': [
        Waypoint(
          0,
          'Main Door',
          floor: 1,
          category: Waypoint.entranceCategory,
          latitude: 12.97,
          longitude: 77.59,
        ).toJson(),
      ],
    };

    final mapBeta = {
      'name': 'Building Beta',
      'floor': 1,
      'latitude': 12.971,
      'longitude': 77.591,
      'waypoints': [
        Waypoint(
          0,
          'East Gate',
          floor: 1,
          category: Waypoint.entranceCategory,
          latitude: 12.971,
          longitude: 77.591,
        ).toJson(),
      ],
    };

    SharedPreferences.setMockInitialValues({
      'map_Building Alpha#1': jsonEncode(mapAlpha),
      'map_Building Beta#1': jsonEncode(mapBeta),
      'building_connections': jsonEncode([connection.toJson()]),
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: ConnectorLinksScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Building Alpha pin to open bottom sheet
    await tester.tap(find.text('Building Alpha'));
    await tester.pumpAndSettle();

    // In ConnectorLinksScreen (Admin Studio workflow):
    // 1. Linked buildings have the delete/remove link icon button
    expect(find.text('Linked buildings'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);

    // 2. "Link to another building" button exists
    expect(find.text('Link to another building'), findsOneWidget);

    // Tap "Link to another building"
    await tester.tap(find.text('Link to another building'));
    await tester.pumpAndSettle();

    // Bottom sheet closes and banner prompts to tap the target building
    expect(find.text('Tap the building to link Building Alpha to'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // Tapping Cancel dismisses the link mode
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Tap the building to link Building Alpha to'), findsNothing);
  });

  testWidgets(
      'OutdoorMapScreen and ConnectorLinksScreen load cached user location and cache screen data',
      (WidgetTester tester) async {
    OutdoorMapScreen.resetStaticCache();
    ConnectorLinksScreen.resetStaticCache();

    // Set cached location in LocationService
    final now = DateTime.now();
    final mockLoc = BuildingLocation(
      latitude: 12.9716,
      longitude: 77.5946,
      accuracy: 5.0,
      timestamp: now,
    );
    LocationService.instance.setCachedLocation(mockLoc);

    SharedPreferences.setMockInitialValues({
      'last_known_gps_location': jsonEncode(mockLoc.toJson()),
    });

    // 1. Pump OutdoorMapScreen
    await tester.pumpWidget(
      const MaterialApp(
        home: OutdoorMapScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify screen rendered without staying stuck in loading
    expect(find.text('Outdoor Map'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Verify user location dot is rendered
    expect(find.byType(OutdoorMapScreen), findsOneWidget);

    // 2. Pump ConnectorLinksScreen
    await tester.pumpWidget(
      const MaterialApp(
        home: ConnectorLinksScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connector Links'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 3. Tap My Location button
    final myLocButton = find.byTooltip('My location');
    expect(myLocButton, findsOneWidget);
    await tester.tap(myLocButton);
    await tester.pumpAndSettle();

    // Clean up
    OutdoorMapScreen.resetStaticCache();
    ConnectorLinksScreen.resetStaticCache();
    LocationService.instance.setCachedLocation(null);
  });
}
