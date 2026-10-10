import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mapx/models/navigation_trip.dart';
import 'package:mapx/services/navigation_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('logTrip stores newest first and latest() returns it', () async {
    final service = NavigationHistoryService.instance;
    await service.logTrip(
      fromBuilding: 'Alpha',
      fromFloor: 0,
      fromLabel: 'Entrance A',
      toBuilding: 'Alpha',
      toFloor: 1,
      toLabel: 'Lab 101',
      distanceMeters: 42.5,
      completedAt: DateTime(2026, 1, 1, 10, 0),
    );
    await service.logTrip(
      fromBuilding: 'Alpha',
      fromFloor: 1,
      fromLabel: 'Lab 101',
      toBuilding: 'Beta',
      toFloor: 0,
      toLabel: 'Entrance B',
      completedAt: DateTime(2026, 1, 2, 10, 0),
    );

    final trips = await service.load();
    expect(trips.length, 2);
    expect(trips.first.toLabel, 'Entrance B');
    expect((await service.latest())?.toBuilding, 'Beta');
  });

  test('duplicate route within a minute is ignored', () async {
    final service = NavigationHistoryService.instance;
    final now = DateTime(2026, 3, 1, 12, 0);
    final first = await service.logTrip(
      fromBuilding: 'Alpha',
      fromFloor: 0,
      fromLabel: 'A',
      toBuilding: 'Beta',
      toFloor: 0,
      toLabel: 'B',
      completedAt: now,
    );
    expect(first, isNotNull);
    final second = await service.logTrip(
      fromBuilding: 'Alpha',
      fromFloor: 0,
      fromLabel: 'A',
      toBuilding: 'Beta',
      toFloor: 0,
      toLabel: 'B',
      completedAt: now.add(const Duration(seconds: 10)),
    );
    expect(second, isNull);
    expect((await service.load()).length, 1);
  });

  test('invalid trips are rejected', () async {
    final service = NavigationHistoryService.instance;
    expect(
      await service.logTrip(
        fromBuilding: '',
        fromLabel: 'A',
        toBuilding: 'Beta',
        toLabel: 'B',
      ),
      isNull,
    );
    expect(await service.load(), isEmpty);
  });

  test('trip json round trip', () {
    final trip = NavigationTrip(
      id: '1',
      fromBuilding: 'Alpha',
      fromFloor: 0,
      fromLabel: 'Entrance A',
      toBuilding: 'Beta',
      toFloor: 2,
      toLabel: 'Lab 202',
      distanceMeters: 120,
      completedAt: DateTime(2026, 5, 5),
    );
    final restored =
        NavigationTrip.fromJson(Map<String, dynamic>.from(trip.toJson()));
    expect(restored.id, '1');
    expect(restored.routeSummary.contains('Alpha'), isTrue);
    expect(restored.routeSummary.contains('Beta'), isTrue);
  });

  test('delete and clear work', () async {
    final service = NavigationHistoryService.instance;
    final trip = await service.logTrip(
      fromBuilding: 'A',
      fromLabel: 'X',
      toBuilding: 'B',
      toLabel: 'Y',
    );
    await service.delete(trip!.id);
    expect(await service.load(), isEmpty);
    await service.logTrip(
      fromBuilding: 'A',
      fromLabel: 'X',
      toBuilding: 'B',
      toLabel: 'Y',
      completedAt: DateTime(2026, 6, 1),
    );
    await service.clear();
    expect(await service.load(), isEmpty);
  });
}
