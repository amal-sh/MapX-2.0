import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/logic/floor_route_planner.dart';
import 'package:mapx/logic/spatial_sensor_fusion.dart';
import 'package:mapx/providers/dashboard_providers.dart';
import 'package:mapx/providers/navigation_providers.dart';
import 'package:mapx/providers/search_providers.dart';
import 'package:mapx/providers/service_providers.dart';
import 'package:mapx/services/location_service.dart';
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

    test('basemapPreferenceProvider defaults to dark and updates state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(basemapPreferenceProvider), 'dark');
      await container.read(basemapPreferenceProvider.notifier).setBasemap('light');
      expect(container.read(basemapPreferenceProvider), 'light');
      await container.read(basemapPreferenceProvider.notifier).setBasemap('standard');
      expect(container.read(basemapPreferenceProvider), 'standard');
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

    test('loads connections and entrance waypoints', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await prefs.setString(
        'map_AcademicBlock#0',
        jsonEncode({
          'name': 'AcademicBlock',
          'floor': 0,
          'latitude': 12.9716,
          'longitude': 77.5946,
          'waypoints': [
            {
              'globalStepIndex': 0,
              'label': 'Main Gate',
              'floor': 0,
              'category': 'entrance',
              'latitude': 12.9716,
              'longitude': 77.5946,
            }
          ]
        }),
      );
      await prefs.setString(
        'building_connections',
        jsonEncode([
          {
            'a': {'building': 'AcademicBlock', 'floor': 0, 'label': 'Main Gate'},
            'b': {'building': 'Library', 'floor': 0, 'label': 'North Gate'},
            'distanceMeters': 120.0,
            'durationSeconds': 90.0,
            'route': [
              {'lat': 12.9716, 'lng': 77.5946},
              {'lat': 12.9720, 'lng': 77.5950},
            ],
            'source': 'straight',
          }
        ]),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      final state = container.read(dashboardProvider);
      expect(state.connections.length, 1);
      expect(state.connections.first.distanceMeters, 120.0);
      expect(state.connections.first.route.length, 2);
      expect(state.entrancesWithGps.length, 1);
      expect(state.entrancesWithGps.first.label, 'Main Gate');
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

  group('Building Pin Location and Entrance Fallback', () {
    test('DashboardState.buildingPinLocation prioritizes entrance GPS over recorded location', () {
      final state = DashboardState(
        buildingLocations: {
          'Alan': BuildingLocation(
            latitude: 12.0,
            longitude: 77.0,
            accuracy: 5.0,
            timestamp: DateTime.now(),
          ),
        },
        buildingEntrances: {
          'Alan': [
            Waypoint(0, 'Main Door', latitude: 12.001, longitude: 77.002, category: 'entrance'),
          ],
        },
      );

      final pin = state.buildingPinLocation('Alan');
      expect(pin, isNotNull);
      expect(pin!.$1, 12.001);
      expect(pin.$2, 77.002);
    });

    test('DashboardState.buildingPinLocation falls back to recorded location when entrance has no GPS', () {
      final state = DashboardState(
        buildingLocations: {
          'Alan': BuildingLocation(
            latitude: 12.0,
            longitude: 77.0,
            accuracy: 5.0,
            timestamp: DateTime.now(),
          ),
        },
        buildingEntrances: {
          'Alan': [
            Waypoint(0, 'Main Door', category: 'entrance'),
          ],
        },
      );

      final pin = state.buildingPinLocation('Alan');
      expect(pin, isNotNull);
      expect(pin!.$1, 12.0);
      expect(pin.$2, 77.0);
    });
  });
}
