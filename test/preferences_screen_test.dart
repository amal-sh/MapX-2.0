import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/providers/service_providers.dart';
import 'package:mapx/screens/preferences_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildSubject({ProviderContainer? container}) {
    return UncontrolledProviderScope(
      container: container ?? ProviderContainer(),
      child: const MaterialApp(
        home: PreferencesScreen(),
      ),
    );
  }

  testWidgets('PreferencesScreen renders redesigned layout without feet option',
      (tester) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    // Verify title and header cards
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('Local Device Settings'), findsOneWidget);
    expect(find.text('Offline & Private'), findsOneWidget);

    // Verify basemap theme options
    expect(find.text('DEFAULT MAP THEME'), findsOneWidget);
    expect(find.text('Dark Blue'), findsOneWidget);
    expect(find.text('Monochrome Light'), findsOneWidget);
    expect(find.text('Standard OpenStreetMap'), findsOneWidget);

    // Verify measurement system section shows Metric meters and NO Feet option
    expect(find.text('MEASUREMENT SYSTEM'), findsOneWidget);
    expect(find.text('Metric (Meters & km)'), findsOneWidget);
    expect(find.text('Meters'), findsOneWidget);
    expect(find.text('Feet'), findsNothing);

    // Verify data and cache section
    expect(find.text('DATA & CACHE'), findsOneWidget);
    expect(find.text('Local Map Storage'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('Selecting a basemap card updates the preference in provider',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(buildSubject(container: container));
    await tester.pumpAndSettle();

    // Initial state is standard
    expect(container.read(basemapPreferenceProvider), 'standard');

    // Tap Dark Blue
    await tester.tap(find.text('Dark Blue'));
    await tester.pumpAndSettle();

    expect(container.read(basemapPreferenceProvider), 'dark');

    // Tap Monochrome Light
    await tester.tap(find.text('Monochrome Light'));
    await tester.pumpAndSettle();

    expect(container.read(basemapPreferenceProvider), 'light');
  });
}
