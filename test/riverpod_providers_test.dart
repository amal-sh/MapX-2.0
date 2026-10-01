import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/logic/floor_route_planner.dart';
import 'package:mapx/logic/spatial_sensor_fusion.dart';
import 'package:mapx/providers/dashboard_providers.dart';
import 'package:mapx/providers/navigation_providers.dart';
import 'package:mapx/providers/search_providers.dart';
import 'package:mapx/providers/service_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Service Providers', () {
    test('exposes singleton instances through providers', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(firestoreServiceProvider), isNotNull);
      expect(container.read(locationServiceProvider), isNotNull);
      expect(container.read(searchServiceProvider), isNotNull);
    });
  });

  group('DashboardNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'map_AcademicBlock#0': '{"name":"AcademicBlock","floor":0}',
        'map_AcademicBlock#1': '{"name":"AcademicBlock","floor":1}',
        'map_Library#0': '{"name":"Library","floor":0}',
      });
    });

    test('loads and groups maps by building', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      final state = container.read(dashboardProvider);
      expect(state.isLoading, isFalse);
      expect(state.entries.length, 3);

      final grouped = state.groupedByBuilding;
      expect(grouped.containsKey('AcademicBlock'), isTrue);
      expect(grouped['AcademicBlock']!.length, 2);
      expect(grouped['AcademicBlock']![0].floor, 0);
      expect(grouped['AcademicBlock']![1].floor, 1);

      expect(notifier.exists('AcademicBlock', 0), isTrue);
      expect(notifier.exists('AcademicBlock', 2), isFalse);
    });
  });

  group('Search Providers', () {
    test('updates query and filter states reactively', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(searchQueryProvider), isEmpty);
      expect(container.read(searchCategoryFilterProvider), 'all');
      expect(container.read(searchFocusedBuildingProvider), isNull);

      container.read(searchQueryProvider.notifier).state = 'Lab';
      expect(container.read(searchQueryProvider), 'Lab');

      container.read(searchCategoryFilterProvider.notifier).state = 'places';
      expect(container.read(searchCategoryFilterProvider), 'places');

      container.read(searchFocusedBuildingProvider.notifier).state = 'IT Block';
      expect(container.read(searchFocusedBuildingProvider), 'IT Block');
    });
  });

  group('NavigationNotifier', () {
    test('tracks route, legs, and updates tracking status', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(navigationProvider.notifier);
      final wp1 = Waypoint(0, 'Entrance', floor: 0);
      final wp2 = Waypoint(10, 'Room 101', floor: 1);

      final leg1 = TripLeg(floor: 0, from: wp1, to: wp2);
      final leg2 = TripLeg(floor: 1, from: wp2, to: wp2);

      notifier.setRoute(
        start: wp1,
        destination: wp2,
        legs: [leg1, leg2],
        totalDistance: 20.0,
        instructions: const [],
      );

      var state = container.read(navigationProvider);
      expect(state.startLocation?.label, 'Entrance');
      expect(state.destination?.label, 'Room 101');
      expect(state.isMultiFloorRoute, isTrue);
      expect(state.currentLeg?.floor, 0);

      notifier.proceedToNextLeg();
      state = container.read(navigationProvider);
      expect(state.currentLegIndex, 1);
      expect(state.currentFloor, 1);

      notifier.updateTrackingStatus(
        confidence: TrackingConfidence.high,
        isDrifting: false,
        driftReason: '',
        liveProgress: 15.0,
        isFacingPath: true,
        isTravelingBackward: false,
        extraTurnDistance: 0.0,
        offPathAngleDelta: 2.5,
        turnDirection: 'straight',
      );

      state = container.read(navigationProvider);
      expect(state.trackingConfidence, TrackingConfidence.high);
      expect(state.liveProgress, 15.0);
      expect(state.offPathAngleDelta, 2.5);
    });
  });
}
