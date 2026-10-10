import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/screens/dashboard_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('Renders redesigned Dashboard UI with search, chips, directory and compass pill',
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
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Central Library & Learning Commons'), findsOneWidget);
    expect(find.text('Floors'), findsWidgets);
    expect(find.text('L1'), findsWidgets);

    // Verify Compass calibration status pill
    expect(find.text('Indoor Compass Calibrated'), findsOneWidget);

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
