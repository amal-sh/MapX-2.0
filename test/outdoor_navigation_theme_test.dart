import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/outdoor_route_planner.dart';
import 'package:mapx/models/outdoor_models.dart';
import 'package:mapx/providers/service_providers.dart';
import 'package:mapx/screens/outdoor_navigation_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');
  const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, (MethodCall methodCall) async {
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

  OutdoorHop createTestHop() {
    const conn = BuildingConnection(
      a: EntranceRef(building: 'Building A', floor: 0, label: 'Main Entrance A'),
      b: EntranceRef(building: 'Building B', floor: 0, label: 'Main Entrance B'),
      distanceMeters: 100,
      durationSeconds: 80,
      route: [(12.971598, 77.594562), (12.972000, 77.595000)],
    );
    return const OutdoorHop(conn, 'Building A');
  }

  testWidgets('OutdoorNavigationScreen renders with standard map theme by default',
      (WidgetTester tester) async {
    final hop = createTestHop();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: OutdoorNavigationScreen(hop: hop),
        ),
      ),
    );
    await tester.pump();

    final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(flutterMap.options.backgroundColor, const Color(0xFFF4F4F5));
    expect(find.text('Walk to Building B'), findsOneWidget);
  });

  testWidgets('OutdoorNavigationScreen renders dark map theme when configured in preferences',
      (WidgetTester tester) async {
    final hop = createTestHop();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(basemapPreferenceProvider.notifier).setBasemap('dark');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: OutdoorNavigationScreen(hop: hop),
        ),
      ),
    );
    await tester.pump();

    final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(flutterMap.options.backgroundColor, const Color(0xFF080E18));
  });

  testWidgets('OutdoorNavigationScreen dynamically updates map theme when preference changes',
      (WidgetTester tester) async {
    final hop = createTestHop();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: OutdoorNavigationScreen(hop: hop),
        ),
      ),
    );
    await tester.pump();

    var flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(flutterMap.options.backgroundColor, const Color(0xFFF4F4F5));

    // Change preference to dark
    container.read(basemapPreferenceProvider.notifier).setBasemap('dark');
    await tester.pump();

    flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(flutterMap.options.backgroundColor, const Color(0xFF080E18));

    // Change preference to light
    container.read(basemapPreferenceProvider.notifier).setBasemap('light');
    await tester.pump();

    flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(flutterMap.options.backgroundColor, const Color(0xFFF4F4F5));
  });
}
