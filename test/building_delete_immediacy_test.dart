import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/providers/dashboard_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleteBuilding reflects immediately and keeps working with 0 floors',
      () async {
    SharedPreferences.setMockInitialValues({
      'map_TowerA#0': '{"name":"TowerA","floor":0}',
      'map_TowerA#1': '{"name":"TowerA","floor":1}',
      'building_registry': '["TowerA","EmptyHall"]',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(dashboardProvider.notifier);
    await notifier.loadMaps();

    expect(container.read(dashboardProvider).allBuildingNames,
        containsAll(['TowerA', 'EmptyHall']));

    // Delete building with floors — state updates synchronously-ish.
    final removedFuture = notifier.deleteBuilding('TowerA');
    // Immediately after the call (before awaiting), UI state must be clean.
    await Future.microtask(() {});
    expect(container.read(dashboardProvider).allBuildingNames,
        isNot(contains('TowerA')));
    final removed = await removedFuture;
    expect(removed, 2);
    expect(container.read(dashboardProvider).allBuildingNames,
        isNot(contains('TowerA')));
    // Zero-floor building survives.
    expect(container.read(dashboardProvider).allBuildingNames,
        contains('EmptyHall'));

    // Delete zero-floor building too.
    await notifier.deleteBuilding('EmptyHall');
    expect(container.read(dashboardProvider).allBuildingNames, isEmpty);

    // Rename works and is immediate.
    SharedPreferences.setMockInitialValues({
      'map_Old#0': '{"name":"Old","floor":0}',
      'building_registry': '["Old"]',
    });
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    final n2 = c2.read(dashboardProvider.notifier);
    await n2.loadMaps();
    final ok = await n2.renameBuilding('Old', 'New');
    expect(ok, isTrue);
    expect(c2.read(dashboardProvider).allBuildingNames, ['New']);
    expect(n2.exists('New', 0), isTrue);
  });
}
