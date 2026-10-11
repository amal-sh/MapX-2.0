import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/search_models.dart';
import 'package:mapx/providers/search_providers.dart';
import 'package:mapx/screens/dashboard_screen.dart';
import 'package:mapx/screens/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');
  const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, (MethodCall methodCall) async {
      if (methodCall.method == 'isLocationServiceEnabled') {
        return false;
      }
      return null;
    });
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, null);
  });

  testWidgets('Tapping search bar in Dashboard navigates to SearchScreen with Hero',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify search bar is present in bottom sheet
    final searchBarFinder = find.text('Search rooms, labs, stairs, restrooms...');
    expect(searchBarFinder, findsOneWidget);

    // Tap search bar
    await tester.tap(searchBarFinder);
    await tester.pump(); // Start transition
    await tester.pumpAndSettle(); // Complete expanding hero animation

    // Verify SearchScreen is rendered
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.chevron_left), findsOneWidget);
    expect(find.text('CAMPUS GPS READY · SEARCHING ALL MAPS'), findsNothing); // Checks case insensitivity
    expect(find.textContaining('Campus GPS ready'), findsOneWidget);

    // Pop back to dashboard
    await tester.tap(find.byIcon(CupertinoIcons.chevron_left));
    await tester.pumpAndSettle();

    // Search screen is popped
    expect(find.byType(SearchScreen), findsNothing);
    expect(find.byType(DashboardScreen), findsOneWidget);
  });

  testWidgets('SearchScreen renders Cupertino controls, categories, and handles input',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Category pills
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Rooms & Places'), findsOneWidget);
    expect(find.text('Buildings'), findsOneWidget);
    expect(find.text('Stairs & Lifts'), findsOneWidget);

    // Enter search text
    final inputFinder = find.byType(TextField);
    expect(inputFinder, findsOneWidget);
    await tester.enterText(inputFinder, 'Lab');
    await tester.pumpAndSettle();

    // Verify clear button appears and clears text
    expect(find.byIcon(CupertinoIcons.clear_circled_solid), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.clear_circled_solid));
    await tester.pumpAndSettle();

    expect(find.text('Lab'), findsNothing);
  });

  testWidgets('SearchScreen renders skeleton loader while context is loading',
      (WidgetTester tester) async {
    final completer = Completer<SearchLocationContext>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchContextProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(
          home: SearchScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300)); // Render loading skeleton

    // Verify skeleton loader is present
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(TextField), findsOneWidget); // Header search bar is ready

    completer.complete(const SearchLocationContext(
      currentBuilding: null,
      nearbyBuildings: [],
      userLocation: null,
    ));
    await tester.pumpAndSettle();
  });
}

