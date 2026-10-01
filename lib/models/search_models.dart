import '../services/location_service.dart';

class SearchWaypointInfo {
  final String name;
  final String buildingName;
  final int floor;
  final String mapKey;
  final double? buildingLatitude;
  final double? buildingLongitude;
  final double? distanceMeters;
  final bool isConnector;

  const SearchWaypointInfo({
    required this.name,
    required this.buildingName,
    required this.floor,
    required this.mapKey,
    this.buildingLatitude,
    this.buildingLongitude,
    this.distanceMeters,
    this.isConnector = false,
  });

  String get locationDescription => '$buildingName · Floor $floor';
}

class BuildingSearchInfo {
  final String name;
  final List<int> floors;
  final double? latitude;
  final double? longitude;
  final double? distanceMeters;
  final List<SearchWaypointInfo> waypoints;
  final String primaryMapKey;

  const BuildingSearchInfo({
    required this.name,
    required this.floors,
    this.latitude,
    this.longitude,
    this.distanceMeters,
    required this.waypoints,
    required this.primaryMapKey,
  });

  String get floorSummary => floors.length == 1 ? '1 floor' : '${floors.length} floors';

  String get distanceFormatted {
    if (distanceMeters == null) return '';
    if (distanceMeters! < 1000) {
      return '${distanceMeters!.round()}m away';
    }
    return '${(distanceMeters! / 1000).toStringAsFixed(1)}km away';
  }
}

class SearchLocationContext {
  /// The building the user is currently inside or adjacent to (<= 60 meters).
  final BuildingSearchInfo? currentBuilding;

  /// All known buildings sorted by proximity to the user.
  final List<BuildingSearchInfo> nearbyBuildings;

  /// The device's current GPS location, if available.
  final BuildingLocation? userLocation;

  const SearchLocationContext({
    this.currentBuilding,
    required this.nearbyBuildings,
    this.userLocation,
  });

  bool get isInBuilding => currentBuilding != null;
}
