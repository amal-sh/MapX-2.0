import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/screens/dashboard_screen.dart';
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

    // Verify Drawer Header
    expect(find.text('v2.0 • Indoor AR Engine'), findsOneWidget);

    // Verify Explore section (live offline data, no hardcoded badge/subtitle)
    expect(find.text('EXPLORE'), findsOneWidget);
    expect(find.text('Campus Overview'), findsOneWidget);
    expect(find.text('Saved Places & Rooms'), findsOneWidget);
    expect(find.text('Recent Trips'), findsOneWidget);
    // Empty history shows a placeholder instead of a hardcoded destination.
    expect(find.text('No trips yet'), findsOneWidget);
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
}
