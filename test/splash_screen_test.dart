import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/screens/splash_screen.dart';
import 'package:mapx/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocationService.instance.setCachedLocation(null);
  });

  testWidgets('SplashScreen renders black background and logo elements',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SplashScreen(),
        ),
      ),
    );

    // Initial frame
    await tester.pump();

    // Verify background color is pure black
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.black);

    // Verify X image asset is present
    final imageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName == 'assets/images/x_light.png',
    );
    expect(imageFinder, findsOneWidget);

    // Verify 'Map' text exists in the widget tree
    expect(find.text('Map'), findsOneWidget);

    // Let animation advance through initial phase
    await tester.pump(const Duration(milliseconds: 600));
    expect(imageFinder, findsOneWidget);

    // Advance through the 'Map' reveal phase
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Map'), findsOneWidget);

    // Advance past completion
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('LocationService caches location correctly', () {
    final sampleLocation = BuildingLocation(
      latitude: 37.7749,
      longitude: -122.4194,
      accuracy: 5.0,
      timestamp: DateTime.now(),
    );

    LocationService.instance.setCachedLocation(sampleLocation);
    expect(LocationService.instance.cachedLocation, isNotNull);
    expect(LocationService.instance.cachedLocation!.latitude, 37.7749);
    expect(LocationService.instance.cachedLocation!.longitude, -122.4194);
    expect(LocationService.instance.lastLocation, isNotNull);
  });
}
