import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_models.dart';
import '../models/search_models.dart';
import 'location_service.dart';

class SearchResults {
  final List<SearchWaypointInfo> waypoints;
  final List<BuildingSearchInfo> buildings;

  const SearchResults({
    required this.waypoints,
    required this.buildings,
  });

  bool get isEmpty => waypoints.isEmpty && buildings.isEmpty;
  int get totalCount => waypoints.length + buildings.length;
}

class SearchService {
  static final SearchService instance = SearchService._();
  SearchService._();

  /// Distance threshold in meters to assume a user is currently inside or right at the building.
  static const double kInsideBuildingThresholdMeters = 60.0;

  /// Loads all local buildings and places, correlating them with GPS coordinates.
  Future<SearchLocationContext> loadSearchContext({
    BuildingLocation? currentLocation,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Resolve user location
    BuildingLocation? userLoc = currentLocation;
    userLoc ??= await LocationService.instance.getCurrentLocation();

    // 2. Discover building coordinates from building_gps_ cache
    final buildingCoords = <String, ({double lat, double lng})>{};
    for (final key in prefs.getKeys().where((k) => k.startsWith('building_gps_'))) {
      final name = key.substring('building_gps_'.length);
      try {
        final locData = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
        buildingCoords[name] = (
          lat: (locData['latitude'] as num).toDouble(),
          lng: (locData['longitude'] as num).toDouble(),
        );
      } catch (_) {}
    }

    // 3. Scan all floor maps
    final buildingFloors = <String, Set<int>>{};
    final buildingWaypoints = <String, List<SearchWaypointInfo>>{};
    final buildingPrimaryMap = <String, String>{};

    for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
      try {
        final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
        final buildingName = data['name'] as String? ?? key.substring(4);
        final floor = data['floor'] as int? ?? 0;

        // If coordinates embedded in map, cache if not already found
        if (!buildingCoords.containsKey(buildingName) &&
            data['latitude'] != null &&
            data['longitude'] != null) {
          buildingCoords[buildingName] = (
            lat: (data['latitude'] as num).toDouble(),
            lng: (data['longitude'] as num).toDouble(),
          );
        }

        buildingFloors.putIfAbsent(buildingName, () => {}).add(floor);
        buildingPrimaryMap.putIfAbsent(buildingName, () => key);

        // Extract waypoints
        final rawWaypoints = data['waypoints'] as List? ?? [];
        for (final wpItem in rawWaypoints) {
          if (wpItem is Map) {
            final wp = Waypoint.fromJson(Map<String, dynamic>.from(wpItem));
            buildingWaypoints.putIfAbsent(buildingName, () => []).add(
                  SearchWaypointInfo(
                    name: wp.displayName,
                    buildingName: buildingName,
                    floor: floor,
                    mapKey: key,
                    isConnector: wp.isConnector,
                  ),
                );
          }
        }
      } catch (e) {
        debugPrint('Error parsing map "$key" for search: $e');
      }
    }

    // 4. Construct BuildingSearchInfo with distance calculations
    final buildingList = <BuildingSearchInfo>[];

    for (final entry in buildingFloors.entries) {
      final name = entry.key;
      final floors = entry.value.toList()..sort();
      final coords = buildingCoords[name];

      double? dist;
      if (userLoc != null && coords != null) {
        dist = Geolocator.distanceBetween(
          userLoc.latitude,
          userLoc.longitude,
          coords.lat,
          coords.lng,
        );
      }

      // Attach distance to waypoints
      final waypoints = (buildingWaypoints[name] ?? []).map((wp) {
        return SearchWaypointInfo(
          name: wp.name,
          buildingName: wp.buildingName,
          floor: wp.floor,
          mapKey: wp.mapKey,
          buildingLatitude: coords?.lat,
          buildingLongitude: coords?.lng,
          distanceMeters: dist,
          isConnector: wp.isConnector,
        );
      }).toList();

      buildingList.add(
        BuildingSearchInfo(
          name: name,
          floors: floors,
          latitude: coords?.lat,
          longitude: coords?.lng,
          distanceMeters: dist,
          waypoints: waypoints,
          primaryMapKey: buildingPrimaryMap[name] ?? 'map_$name#${floors.firstOrNull ?? 0}',
        ),
      );
    }

    // 5. Sort buildings: known distance first (ascending), then alphabetical
    buildingList.sort((a, b) {
      if (a.distanceMeters != null && b.distanceMeters != null) {
        return a.distanceMeters!.compareTo(b.distanceMeters!);
      }
      if (a.distanceMeters != null) return -1;
      if (b.distanceMeters != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    // 6. Check if user is in a particular building
    BuildingSearchInfo? currentBuilding;
    if (buildingList.isNotEmpty &&
        buildingList.first.distanceMeters != null &&
        buildingList.first.distanceMeters! <= kInsideBuildingThresholdMeters) {
      currentBuilding = buildingList.first;
    }

    return SearchLocationContext(
      currentBuilding: currentBuilding,
      nearbyBuildings: buildingList,
      userLocation: userLoc,
    );
  }

  /// Searches waypoints and buildings according to user query, current building context, and category.
  SearchResults search({
    required String query,
    required SearchLocationContext context,
    String? focusBuildingName,
    String categoryFilter = 'all', // 'all', 'places', 'buildings', 'connectors'
  }) {
    final cleanQuery = query.trim().toLowerCase();
    final effectiveFocus = focusBuildingName ?? context.currentBuilding?.name;

    final matchedWaypoints = <SearchWaypointInfo>[];
    final matchedBuildings = <BuildingSearchInfo>[];

    // Filter buildings
    if (categoryFilter == 'all' || categoryFilter == 'buildings') {
      for (final b in context.nearbyBuildings) {
        if (cleanQuery.isEmpty) {
          // If empty query and no focused building, display all nearby buildings
          if (effectiveFocus == null) {
            matchedBuildings.add(b);
          }
        } else if (b.name.toLowerCase().contains(cleanQuery)) {
          matchedBuildings.add(b);
        }
      }
    }

    // Filter waypoints / places
    if (categoryFilter == 'all' || categoryFilter == 'places' || categoryFilter == 'connectors') {
      for (final b in context.nearbyBuildings) {
        // If searching within a focused building and query is empty, show all places of that building
        // If query is not empty, search across buildings, prioritizing focused building
        for (final wp in b.waypoints) {
          if (categoryFilter == 'connectors' && !wp.isConnector) {
            continue;
          }
          if (categoryFilter == 'places' && wp.isConnector) {
            continue;
          }

          if (cleanQuery.isEmpty) {
            if (effectiveFocus != null && b.name == effectiveFocus) {
              matchedWaypoints.add(wp);
            }
          } else {
            final matchesName = wp.name.toLowerCase().contains(cleanQuery);
            final matchesBuilding = wp.buildingName.toLowerCase().contains(cleanQuery);
            final matchesFloor = 'floor ${wp.floor}'.contains(cleanQuery);

            if (matchesName || matchesBuilding || matchesFloor) {
              matchedWaypoints.add(wp);
            }
          }
        }
      }
    }

    // Sort waypoints:
    // 1. Matches in focused building first
    // 2. Proximity by distance
    // 3. Alphabetical
    matchedWaypoints.sort((a, b) {
      if (effectiveFocus != null) {
        final aInFocus = a.buildingName == effectiveFocus;
        final bInFocus = b.buildingName == effectiveFocus;
        if (aInFocus && !bInFocus) return -1;
        if (!aInFocus && bInFocus) return 1;
      }
      if (a.distanceMeters != null && b.distanceMeters != null) {
        final distComp = a.distanceMeters!.compareTo(b.distanceMeters!);
        if (distComp != 0) return distComp;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return SearchResults(
      waypoints: matchedWaypoints,
      buildings: matchedBuildings,
    );
  }
}
