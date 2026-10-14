import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/providers/dashboard_providers.dart';
import 'package:mapx/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String mapPayload(String name, int floor) => jsonEncode({
      'name': name,
      'floor': floor,
      'stepCount': 2,
      'segments': [
        {
          'floor': floor,
          'steps': [
            {'heading': 0.0, 'length': 5.0, 'floor': floor},
            {'heading': 90.0, 'length': 5.0, 'floor': floor},
          ],
        },
      ],
      'waypoints': [
        {'globalStepIndex': 1, 'label': 'A', 'floor': floor, 'category': 'lift'},
      ],
      'walls': [],
      'links': [],
      'latitude': 1.0,
      'longitude': 2.0,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Building editing', () {
    test('floor label set, shown, and cleared', () async {
      SharedPreferences.setMockInitialValues({
        'map_Hall#0': mapPayload('Hall', 0),
        'building_registry': '["Hall"]',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      expect(
          container
              .read(dashboardProvider)
              .entries
              .first
              .displayTitle,
          'Floor 0');

      expect(
          await notifier.setFloorLabel(
              building: 'Hall', floor: 0, label: 'Lobby Level'),
          isTrue);
      var entry =
          container.read(dashboardProvider).entries.first;
      expect(entry.displayTitle, 'Lobby Level');
      expect(entry.label, 'Lobby Level');

      expect(
          await notifier.setFloorLabel(
              building: 'Hall', floor: 0, label: '  '),
          isTrue);
      entry = container.read(dashboardProvider).entries.first;
      expect(entry.label, isNull);
      expect(entry.displayTitle, 'Floor 0');

      expect(
          await notifier.setFloorLabel(
              building: 'Hall', floor: 9, label: 'X'),
          isFalse);
    });

    test('renumber migrates key, payload fields, and connections', () async {
      SharedPreferences.setMockInitialValues({
        'map_Hall#0': mapPayload('Hall', 0),
        'map_Hall#1': mapPayload('Hall', 1),
        'building_registry': '["Hall","Other"]',
        'building_connections': jsonEncode([
          {
            'a': {'building': 'Hall', 'floor': 0, 'label': 'Gate'},
            'b': {'building': 'Other', 'floor': 0, 'label': 'Door'},
            'distanceMeters': 10.0,
            'durationSeconds': 60.0,
            'route': [
              {'lat': 1.0, 'lng': 2.0},
              {'lat': 1.1, 'lng': 2.1}
            ],
            'source': 'osrm',
          },
        ]),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      // Occupied number rejected, same number rejected.
      expect(
          await notifier.renumberFloor(
              building: 'Hall', oldFloor: 0, newFloor: 1),
          isFalse);
      expect(
          await notifier.renumberFloor(
              building: 'Hall', oldFloor: 0, newFloor: 0),
          isFalse);

      expect(
          await notifier.renumberFloor(
              building: 'Hall', oldFloor: 0, newFloor: 2),
          isTrue);
      final state = container.read(dashboardProvider);
      expect(notifier.exists('Hall', 0), isFalse);
      expect(notifier.exists('Hall', 2), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('map_Hall#0'), isFalse);
      final moved =
          jsonDecode(prefs.getString('map_Hall#2')!) as Map<String, dynamic>;
      expect(moved['floor'], 2);
      expect((moved['segments'] as List).first['floor'], 2);
      expect((moved['segments'] as List).first['steps'][0]['floor'], 2);
      expect((moved['waypoints'] as List).first['floor'], 2);

      final conns = jsonDecode(
          prefs.getString('building_connections')!) as List;
      expect(conns.length, 1);
      expect((conns.first as Map)['a']['floor'], 2);
      expect((conns.first as Map)['b']['floor'], 0);
      expect(state.floorStats.containsKey('map_Hall#2'), isTrue);
      expect(state.floorStats.containsKey('map_Hall#0'), isFalse);
    });

    test('location update applies to cache and payloads', () async {
      SharedPreferences.setMockInitialValues({
        'map_Hall#0': mapPayload('Hall', 0),
        'building_registry': '["Hall"]',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      final loc = BuildingLocation(
        latitude: 37.5,
        longitude: -122.1,
        accuracy: 5.0,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      await notifier.updateBuildingLocation('Hall', loc);

      final state = container.read(dashboardProvider);
      expect(state.buildingLocations['Hall']?.latitude, 37.5);
      final prefs = await SharedPreferences.getInstance();
      final gps = jsonDecode(prefs.getString('building_gps_Hall')!) as Map;
      expect(gps['latitude'], 37.5);
      final payload =
          jsonDecode(prefs.getString('map_Hall#0')!) as Map<String, dynamic>;
      expect(payload['latitude'], 37.5);
      expect(payload['longitude'], -122.1);
    });

    test('rename and delete migrate/drop connections', () async {
      SharedPreferences.setMockInitialValues({
        'map_Hall#0': mapPayload('Hall', 0),
        'building_registry': '["Hall","Other"]',
        'building_connections': jsonEncode([
          {
            'a': {'building': 'Hall', 'floor': 0, 'label': 'Gate'},
            'b': {'building': 'Other', 'floor': 0, 'label': 'Door'},
            'distanceMeters': 10.0,
            'durationSeconds': 60.0,
            'route': [
              {'lat': 1.0, 'lng': 2.0}
            ],
            'source': 'straight',
          },
        ]),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      expect(await notifier.renameBuilding('Hall', 'Tower'), isTrue);
      var prefs = await SharedPreferences.getInstance();
      var conns =
          jsonDecode(prefs.getString('building_connections')!) as List;
      expect((conns.first as Map)['a']['building'], 'Tower');
      expect(prefs.containsKey('map_Hall#0'), isFalse);
      expect(prefs.containsKey('map_Tower#0'), isTrue);
      expect(container.read(dashboardProvider).allBuildingNames, contains('Tower'));
      expect(container.read(dashboardProvider).allBuildingNames, isNot(contains('Hall')));

      // Subsequent loadMaps does NOT resurrect Hall
      await notifier.loadMaps();
      expect(container.read(dashboardProvider).allBuildingNames, contains('Tower'));
      expect(container.read(dashboardProvider).allBuildingNames, isNot(contains('Hall')));

      await notifier.deleteBuilding('Tower');
      prefs = await SharedPreferences.getInstance();
      conns = jsonDecode(prefs.getString('building_connections')!) as List;
      expect(conns, isEmpty);
      expect(
          container.read(dashboardProvider).allBuildingNames,
          isNot(contains('Tower')));

      // Subsequent loadMaps does NOT resurrect Tower
      await notifier.loadMaps();
      expect(
          container.read(dashboardProvider).allBuildingNames,
          isNot(contains('Tower')));
    });

    test('rename handles legacy keys without hash correctly', () async {
      SharedPreferences.setMockInitialValues({
        'map_OldHall': mapPayload('OldHall', 0),
        'building_registry': '["OldHall"]',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(dashboardProvider.notifier);
      await notifier.loadMaps();

      expect(container.read(dashboardProvider).allBuildingNames, contains('OldHall'));

      expect(await notifier.renameBuilding('OldHall', 'NewHall'), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('map_OldHall'), isFalse);
      expect(prefs.containsKey('map_NewHall#0'), isTrue);
      expect(container.read(dashboardProvider).allBuildingNames, contains('NewHall'));
      expect(container.read(dashboardProvider).allBuildingNames, isNot(contains('OldHall')));

      await notifier.loadMaps();
      expect(container.read(dashboardProvider).allBuildingNames, contains('NewHall'));
      expect(container.read(dashboardProvider).allBuildingNames, isNot(contains('OldHall')));
    });
  });
}
