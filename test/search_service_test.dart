import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/search_models.dart';
import 'package:mapx/services/location_service.dart';
import 'package:mapx/services/search_service.dart';

void main() {
  group('SearchService Search & Filtering Tests', () {
    late SearchLocationContext dummyContext;

    setUp(() {
      final buildingA = BuildingSearchInfo(
        name: 'Block A',
        floors: [0, 1],
        latitude: 12.9716,
        longitude: 77.5946,
        distanceMeters: 25.0, // Inside Block A
        primaryMapKey: 'map_Block A#0',
        waypoints: const [
          SearchWaypointInfo(
            name: 'Room 101',
            buildingName: 'Block A',
            floor: 0,
            mapKey: 'map_Block A#0',
            distanceMeters: 25.0,
            isConnector: false,
          ),
          SearchWaypointInfo(
            name: 'Stairs A',
            buildingName: 'Block A',
            floor: 0,
            mapKey: 'map_Block A#0',
            distanceMeters: 25.0,
            isConnector: true,
          ),
          SearchWaypointInfo(
            name: 'Physics Lab',
            buildingName: 'Block A',
            floor: 1,
            mapKey: 'map_Block A#1',
            distanceMeters: 25.0,
            isConnector: false,
          ),
        ],
      );

      final buildingB = BuildingSearchInfo(
        name: 'Library',
        floors: [0],
        latitude: 12.9720,
        longitude: 77.5950,
        distanceMeters: 180.0, // Farther away
        primaryMapKey: 'map_Library#0',
        waypoints: const [
          SearchWaypointInfo(
            name: 'Main Reading Room',
            buildingName: 'Library',
            floor: 0,
            mapKey: 'map_Library#0',
            distanceMeters: 180.0,
            isConnector: false,
          ),
          SearchWaypointInfo(
            name: 'Elevator',
            buildingName: 'Library',
            floor: 0,
            mapKey: 'map_Library#0',
            distanceMeters: 180.0,
            isConnector: true,
          ),
        ],
      );

      dummyContext = SearchLocationContext(
        currentBuilding: buildingA, // User is within 25m of Block A
        nearbyBuildings: [buildingA, buildingB],
        userLocation: BuildingLocation(
          latitude: 12.97161,
          longitude: 77.59461,
          accuracy: 5.0,
          timestamp: DateTime.now(),
        ),
      );
    });

    test('Prioritizes current building waypoints when query is empty', () {
      final results = SearchService.instance.search(
        query: '',
        context: dummyContext,
      );

      // In current building (Block A), empty query returns all Block A waypoints
      expect(results.waypoints.length, equals(3));
      expect(results.waypoints.every((w) => w.buildingName == 'Block A'), isTrue);
    });

    test('Searches across all buildings when specific query matches both', () {
      // Both buildings have connectors (stairs or elevator)
      final results = SearchService.instance.search(
        query: 'stairs',
        context: dummyContext,
      );

      expect(results.waypoints.length, equals(1));
      expect(results.waypoints.first.name, equals('Stairs A'));
    });

    test('Matches room by substring and prioritizes focused building', () {
      final results = SearchService.instance.search(
        query: 'room',
        context: dummyContext,
      );

      // Matches 'Room 101' in Block A and 'Main Reading Room' in Library
      expect(results.waypoints.length, equals(2));
      expect(results.waypoints.first.name, equals('Room 101'));
      expect(results.waypoints.last.name, equals('Main Reading Room'));
    });

    test('Filters by category correctly', () {
      final connectorResults = SearchService.instance.search(
        query: '',
        context: dummyContext,
        focusBuildingName: 'Block A',
        categoryFilter: 'connectors',
      );

      expect(connectorResults.waypoints.length, equals(1));
      expect(connectorResults.waypoints.first.name, equals('Stairs A'));
      expect(connectorResults.waypoints.first.isConnector, isTrue);

      final buildingResults = SearchService.instance.search(
        query: 'library',
        context: dummyContext,
        categoryFilter: 'buildings',
      );

      expect(buildingResults.buildings.length, equals(1));
      expect(buildingResults.buildings.first.name, equals('Library'));
      expect(buildingResults.waypoints, isEmpty);
    });
  });
}
