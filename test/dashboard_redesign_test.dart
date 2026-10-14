import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/screens/dashboard_screen.dart';
import 'package:mapx/services/geocoding_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');
  const geolocatorChannel =
      MethodChannel('flutter.baseflow.com/geolocator');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // No location services in widget tests: answer promptly so the
    // header's location loader hides and pumpAndSettle() can settle.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'isLocationServiceEnabled') {
        return false;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, null);
  });

  testWidgets('Renders redesigned Dashboard UI with search, chips and directory',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Search bar
    expect(find.text('Search rooms, labs, stairs, restrooms...'), findsOneWidget);

    // Verify Category filter chips
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Classrooms'), findsOneWidget);
    expect(find.text('Restrooms'), findsOneWidget);
    expect(find.text('Elevators'), findsOneWidget);

    // Verify Campus Directory header
    expect(find.text('CAMPUS DIRECTORY'), findsOneWidget);

    expect(find.text('Science & Engineering Complex'), findsOneWidget);
    expect(find.text('Innovation & Computing Hub'), findsOneWidget);
    // Content lives in a draggable bottom sheet: drag its scroll view
    // up (expands the sheet, then scrolls the list) until the last
    // complex is visible.
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    expect(find.text('Central Library & Learning Commons'), findsOneWidget);
    expect(find.text('Floors'), findsWidgets);
    expect(find.text('L1'), findsWidgets);

    // No compass status pill overlays the map anymore.
    expect(find.text('Indoor Compass Calibrated'), findsNothing);

    // In User Mode, FAB is not visible
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('Opens sidebar drawer and renders user profile, explore items, and Admin Studio card',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Open Drawer via hamburger menu icon
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();

    // Verify Drawer Header (banner shown, subtitle removed)
    expect(find.text('v2.0 • Indoor AR Engine'), findsNothing);

    // Verify Explore section
    expect(find.text('EXPLORE'), findsOneWidget);
    expect(find.text('Campus Overview'), findsOneWidget);
    expect(find.text('Saved Places & Rooms'), findsOneWidget);
    expect(find.text('Recent Trips'), findsNothing);
    // Empty saves show no count badge.
    expect(find.text('4'), findsNothing);

    // Verify Management section with Admin Studio Card
    expect(find.text('MANAGEMENT'), findsOneWidget);
    expect(find.text('ADMIN ONLY'), findsOneWidget);
    expect(find.text('Admin Studio'), findsOneWidget);
    expect(find.text('Floor mapping'), findsOneWidget);

    // Verify bottom options
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('ARCore Diagnostics'), findsOneWidget);
    expect(find.text('Help & Feedback'), findsOneWidget);
  });

  testWidgets('Tapping Admin Studio navigates to dedicated AdminStudioScreen',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Open Drawer via hamburger menu icon
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();

    // Tap Admin Studio
    await tester.tap(find.text('Admin Studio'));
    await tester.pumpAndSettle();

    // Verify AdminStudioScreen header and elements
    expect(find.text('MapX Studio'), findsOneWidget);
    expect(find.text('ADMIN'), findsOneWidget);
    expect(find.text('Walk & Record New Floor'), findsOneWidget);
    expect(find.text('Connector Links'), findsOneWidget);
    expect(find.text('MAPPED BUILDINGS & FLOORS'), findsOneWidget);
  });

  testWidgets('Dashboard renders cached user current location place name',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    await GeocodingService.instance.writeUserPlace(
      3.15,
      101.7,
      const PlaceName(
        short: 'Engineering Quad',
        full: 'Engineering Quad, North Campus',
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Engineering Quad'), findsOneWidget);
  });

  testWidgets('Dashboard renders PolylineLayer and door marker when building links exist',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await prefs.setString(
      'map_BlockA#0',
      jsonEncode({
        'name': 'BlockA',
        'floor': 0,
        'latitude': 12.9716,
        'longitude': 77.5946,
        'waypoints': [
          {
            'globalStepIndex': 0,
            'label': 'Door A',
            'floor': 0,
            'category': 'entrance',
            'latitude': 12.9716,
            'longitude': 77.5946,
          }
        ]
      }),
    );
    await prefs.setString(
      'map_BlockB#0',
      jsonEncode({
        'name': 'BlockB',
        'floor': 0,
        'latitude': 12.9720,
        'longitude': 77.5950,
      }),
    );
    await prefs.setString(
      'building_connections',
      jsonEncode([
        {
          'a': {'building': 'BlockA', 'floor': 0, 'label': 'Door A'},
          'b': {'building': 'BlockB', 'floor': 0, 'label': 'Door B'},
          'distanceMeters': 60.0,
          'durationSeconds': 45.0,
          'route': [
            {'lat': 12.9716, 'lng': 77.5946},
            {'lat': 12.9720, 'lng': 77.5950},
          ],
          'source': 'straight',
        }
      ]),
    );

    await GeocodingService.instance.writeCached(
      'BlockA',
      12.9716,
      77.5946,
      const PlaceName(short: 'Block A', full: 'Block A'),
    );
    await GeocodingService.instance.writeCached(
      'BlockB',
      12.9720,
      77.5950,
      const PlaceName(short: 'Block B', full: 'Block B'),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.byIcon(Icons.door_front_door), findsOneWidget);
  });

  testWidgets(
      'Dashboard bottom sheet counts only buildings within 1 km radius for Complexes Near You',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_INSTALLED';
      }
      return null;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // Building 1: Near (within 100m of user)
    await prefs.setString(
      'map_NearBuilding#0',
      jsonEncode({
        'name': 'NearBuilding',
        'floor': 0,
        'latitude': 12.9716,
        'longitude': 77.5946,
      }),
    );

    // Building 2: Far (over 50 km away)
    await prefs.setString(
      'map_FarBuilding#0',
      jsonEncode({
        'name': 'FarBuilding',
        'floor': 0,
        'latitude': 13.5000,
        'longitude': 78.5000,
      }),
    );

    // Set user position in geolocator mock near NearBuilding (12.9716, 77.5946)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'isLocationServiceEnabled') {
        return true;
      }
      if (methodCall.method == 'checkPermission') {
        return 3; // LocationPermission.always
      }
      if (methodCall.method == 'getCurrentPosition') {
        return {
          'latitude': 12.9716,
          'longitude': 77.5946,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'altitude': 0.0,
          'accuracy': 5.0,
          'heading': 0.0,
          'speed': 0.0,
          'speed_accuracy': 0.0,
        };
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));

    // Only 1 building is within 1 km (NearBuilding), FarBuilding is excluded.
    expect(find.text('1 Complex Near You'), findsOneWidget);
    expect(find.text('2 Complexes Near You'), findsNothing);
  });
}

