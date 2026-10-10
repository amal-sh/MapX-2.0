import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/campus_models.dart';
import '../models/map_models.dart';
import 'firestore_service.dart';

/// A mapped building as seen from the street map.
class CampusBuilding {
  final String name;

  /// Floor number -> storage key of that floor's map.
  final Map<int, String> floorKeys;

  /// Entrances, with the floor each is on.
  final List<Waypoint> entrances;

  /// Where the building was when it was first mapped, if recorded.
  final GeoPoint? recordedLocation;

  const CampusBuilding({
    required this.name,
    required this.floorKeys,
    required this.entrances,
    this.recordedLocation,
  });

  List<Waypoint> get entrancesWithGps => entrances.where((e) => e.hasGps).toList();

  /// Where to put the building's pin: the middle of its entrances, or the
  /// location recorded when it was mapped.
  GeoPoint? get pinLocation {
    final gps = entrancesWithGps;
    if (gps.isEmpty) return recordedLocation;
    final lat = gps.map((e) => e.latitude!).reduce((a, b) => a + b) / gps.length;
    final lng = gps.map((e) => e.longitude!).reduce((a, b) => a + b) / gps.length;
    return (lat, lng);
  }

  /// The entrance an [EntranceRef] points at, if it still exists.
  Waypoint? entrance(EntranceRef ref) => entrances.where(ref.matches).firstOrNull;
}

/// Buildings and the outdoor connections between them. Connections live in
/// SharedPreferences (so navigation works offline) and in Firestore (so
/// every phone gets them).
class CampusRepository {
  static final CampusRepository instance = CampusRepository._();
  CampusRepository._();

  static const _connectionsKey = 'building_connections';

  FirestoreService get _firestore => FirestoreService.instance;

  /// Every mapped building, from the locally stored floor maps.
  Future<Map<String, CampusBuilding>> loadBuildings() async {
    final prefs = await SharedPreferences.getInstance();
    final floors = <String, Map<int, String>>{};
    final entrances = <String, List<Waypoint>>{};
    final locations = <String, GeoPoint>{};

    for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
      final Map data;
      try {
        data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
      } catch (_) {
        continue;
      }
      final name = data['name'] as String? ?? key.substring(4);
      final floor = data['floor'] as int? ?? 0;
      floors.putIfAbsent(name, () => {})[floor] = key;
      for (final w in (data['waypoints'] as List? ?? const [])) {
        final wp = Waypoint.fromJson(Map<String, dynamic>.from(w as Map));
        if (wp.isEntrance) entrances.putIfAbsent(name, () => []).add(wp);
      }
      if (data['latitude'] != null && data['longitude'] != null) {
        locations.putIfAbsent(name, () => ((data['latitude'] as num).toDouble(), (data['longitude'] as num).toDouble()));
      }
    }
    for (final key in prefs.getKeys().where((k) => k.startsWith('building_gps_'))) {
      final name = key.substring('building_gps_'.length);
      try {
        final loc = jsonDecode(prefs.getString(key)!) as Map;
        locations.putIfAbsent(name, () => ((loc['latitude'] as num).toDouble(), (loc['longitude'] as num).toDouble()));
      } catch (_) {}
    }

    return {
      for (final name in floors.keys)
        name: CampusBuilding(
          name: name,
          floorKeys: floors[name]!,
          entrances: entrances[name] ?? const [],
          recordedLocation: locations[name],
        ),
    };
  }

  /// Stored connections. With [sync], first merges in any added on other
  /// phones (from Firestore).
  Future<List<BuildingConnection>> loadConnections({bool sync = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final local = {for (final c in _readLocal(prefs)) c.id: c};
    if (sync) {
      final remote = await _firestore.fetchConnections();
      if (remote != null) {
        for (final json in remote) {
          try {
            final c = BuildingConnection.fromJson(json);
            local[c.id] = c;
          } catch (_) {}
        }
        await _writeLocal(prefs, local.values.toList());
      }
    }
    return local.values.toList();
  }

  Future<void> saveConnection(BuildingConnection connection) async {
    final prefs = await SharedPreferences.getInstance();
    final all = {for (final c in _readLocal(prefs)) c.id: c}..[connection.id] = connection;
    await _writeLocal(prefs, all.values.toList());
    unawaited(_firestore.saveConnection(connection.id, connection.toJson()));
  }

  Future<void> deleteConnection(BuildingConnection connection) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeLocal(prefs, _readLocal(prefs).where((c) => c.id != connection.id).toList());
    unawaited(_firestore.deleteConnection(connection.id));
  }

  List<BuildingConnection> _readLocal(SharedPreferences prefs) {
    try {
      final list = jsonDecode(prefs.getString(_connectionsKey) ?? '[]') as List;
      return [for (final c in list) BuildingConnection.fromJson(Map<String, dynamic>.from(c as Map))];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeLocal(SharedPreferences prefs, List<BuildingConnection> all) =>
      prefs.setString(_connectionsKey, jsonEncode([for (final c in all) c.toJson()]));
}
