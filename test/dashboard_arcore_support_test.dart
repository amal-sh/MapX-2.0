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

  testWidgets('Does not show blocking dialog when ARCore is supported',
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

    expect(find.text('Device Not Supported'), findsNothing);
    expect(find.textContaining("This device isn't supported"), findsNothing);
  });

  testWidgets(
      'Shows blocking dialog when ARCore is not installed on device/emulator (SUPPORTED_NOT_INSTALLED)',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'SUPPORTED_NOT_INSTALLED';
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Device Not Supported'), findsOneWidget);
    expect(find.textContaining("This device isn't supported"), findsOneWidget);
  });

  testWidgets(
      'Shows blocking dialog when device does not support ARCore (UNSUPPORTED_DEVICE_NOT_CAPABLE)',
      (WidgetTester tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'checkAvailability') {
        return 'UNSUPPORTED_DEVICE_NOT_CAPABLE';
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify dialog elements
    expect(find.text('Device Not Supported'), findsOneWidget);
    expect(
      find.text(
          'This device isn\'t supported. MapX requires ARCore support to function properly.'),
      findsOneWidget,
    );
    expect(find.text('Exit App'), findsOneWidget);

    // Verify that dialog is blocking: tapping outside (barrier) does not dismiss it
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Device Not Supported'), findsOneWidget);

    // Verify PopScope canPop is false
    final popScopes = tester.widgetList<PopScope>(find.byType(PopScope));
    expect(popScopes.any((ps) => ps.canPop == false), isTrue);
  });
}
