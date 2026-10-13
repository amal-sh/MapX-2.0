import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/screens/admin_studio_screen.dart';
import 'package:mapx/screens/mapping_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mapx/arcore');
  const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, null);
  });

  testWidgets(
      'Shows circular loader and "Setting it up..." when creating a building before navigating',
      (WidgetTester tester) async {
    final completer = Completer<Map<String, dynamic>?>();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel,
            (MethodCall methodCall) async {
      if (methodCall.method == 'isLocationServiceEnabled') {
        return true;
      }
      if (methodCall.method == 'checkPermission') {
        return 3; // whileInUse
      }
      if (methodCall.method == 'getCurrentPosition') {
        return completer.future;
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: AdminStudioScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap "Walk & Record New Floor"
    expect(find.text('Walk & Record New Floor'), findsOneWidget);
    await tester.tap(find.text('Walk & Record New Floor'));
    await tester.pumpAndSettle();

    // Verify CreateBuildingDialog is displayed
    expect(find.text('Walk & Record Floor'), findsOneWidget);
    expect(find.text('BUILDING NAME'), findsOneWidget);

    // Enter name & select floor
    await tester.enterText(find.byType(TextField).first, 'Innovation Hub');
    await tester.tap(find.text('G (0)'));
    await tester.pumpAndSettle();

    // Tap "Start Recording"
    await tester.tap(find.text('Start Recording'));
    await tester.pump(); // Pump frame where dialog pops and _startNewMap sets _isSettingUp = true

    // Verify that the dialog is closed and the "Setting it up..." loader is visible
    expect(find.text('Setting it up...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    // Complete the location future
    completer.complete({
      'latitude': 37.4219999,
      'longitude': -122.0840575,
      'accuracy': 5.0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Pump to settle navigation to MappingScreen
    await tester.pumpAndSettle();

    // MappingScreen is now navigated to
    expect(find.byType(MappingScreen), findsOneWidget);
    // Overlay is no longer present on MappingScreen
    expect(find.text('Setting it up...'), findsNothing);
  });
}
