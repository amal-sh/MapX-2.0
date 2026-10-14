import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/floor_graph.dart';
import '../models/outdoor_models.dart';
import '../models/map_models.dart';
import '../services/building_repository.dart';
import '../services/firestore_service.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import 'service_providers.dart';

/// Real per-floor stats derived from the stored map payload (segments,
/// waypoints, links) — never hardcoded.
class FloorMapStats {
  final int nodeCount;
  final int placeCount;
  final int liftCount;
  final int stairsCount;
  final int entranceCount;
  final double distanceMeters;
  final int stepCount;

  const FloorMapStats({
    this.nodeCount = 0,
    this.placeCount = 0,
    this.liftCount = 0,
    this.stairsCount = 0,
    this.entranceCount = 0,
    this.distanceMeters = 0,
    this.stepCount = 0,
  });

  String _plural(int n, String one, String many) =>
      '$n ${n == 1 ? one : many}';

  /// One-line summary, e.g. "64 Nodes · 5 Places · 2 Lifts · 1 Staircase".
  /// Only non-zero parts are shown (nodes always).
  String get subtitle {
    final parts = <String>[_plural(nodeCount, 'Node', 'Nodes')];
    if (placeCount > 0) parts.add(_plural(placeCount, 'Place', 'Places'));
    if (liftCount > 0) parts.add(_plural(liftCount, 'Lift', 'Lifts'));
    if (stairsCount > 0) {
      parts.add(_plural(stairsCount, 'Staircase', 'Staircases'));
    }
    if (entranceCount > 0) {
      parts.add(_plural(entranceCount, 'Entrance', 'Entrances'));
    }
    return parts.join(' · ');
  }

  /// Walked distance, e.g. "(248 m)" or "(1.2 km)". Empty when nothing walked.
  String get distanceLabel {
    if (distanceMeters <= 0) return '';
    if (distanceMeters >= 1000) {
      return '(${(distanceMeters / 1000).toStringAsFixed(1)} km)';
    }
    return '(${distanceMeters.round()} m)';
  }

  /// Derives stats from a decoded `map_<building>#<floor>` payload.
  /// Returns zero stats (never throws) when the payload is corrupt.
  static FloorMapStats fromPayload(Map data) {
    try {
      final raw = Map<String, dynamic>.from(data);
      final floor = raw['floor'] as int? ?? 0;
      final stepCount = raw['stepCount'] as int? ?? 0;

      final segments = <PathSegment>[
        for (final e in (raw['segments'] as List? ?? const []))
          PathSegment.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
      final links = <PathLink>[
        for (final e in (raw['links'] as List? ?? const []))
          PathLink.fromJson(Map<String, dynamic>.from(e as Map)),
      ];

      var distance = 0.0;
      for (final s in segments) {
        for (final step in s.steps) {
          distance += step.length;
        }
      }

      int nodes;
      try {
        nodes = FloorGraph.build(segments, floor, links).nodes.length;
      } catch (_) {
        nodes = stepCount + 1;
      }

      var places = 0, lifts = 0, stairs = 0, entrances = 0;
      for (final e in (raw['waypoints'] as List? ?? const [])) {
        final wp = Map<String, dynamic>.from(e as Map);
        switch (wp['category'] as String?) {
          case Waypoint.liftCategory:
            lifts++;
            break;
          case Waypoint.stairsCategory:
            stairs++;
            break;
          case Waypoint.entranceCategory:
            entrances++;
            break;
          default:
            places++;
        }
      }

      return FloorMapStats(
        nodeCount: nodes,
        placeCount: places,
        liftCount: lifts,
        stairsCount: stairs,
        entranceCount: entrances,
        distanceMeters: distance,
        stepCount: stepCount,
      );
    } catch (_) {
      return const FloorMapStats();
    }
  }
}

/// Represents a single saved floor map entry.
class BuildingMapEntry {
  final String key;
  final String name;
  final int? floor;

  /// Admin-assigned custom label (e.g. "Lobby Level"). Null/empty = default.
  final String? label;

  const BuildingMapEntry({
    required this.key,
    required this.name,
    this.floor,
    this.label,
  });

  String get title => floor == null ? name : '$name · Floor $floor';

  /// Human title for lists: custom label when set, else the default title.
  String get displayTitle {
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l;
    return floor == null ? 'Floor 1' : 'Floor $floor';
  }
}

/// State for the dashboard screen: maps list, building locations, and sync status.
class DashboardState {
  final List<BuildingMapEntry> entries;
  final Map<String, BuildingLocation> buildingLocations;
  /// OSM place names keyed by building name (short form). Absent = unresolved.
  final Map<String, String> buildingPlaceNames;
  /// Buildings known to exist even when they have zero recorded floors.
  /// Persisted in SharedPreferences under `building_registry` (+ `building_gps_`).
  final Set<String> knownBuildings;
  /// Real per-floor stats keyed by map key (`map_<building>#<floor>`).
  final Map<String, FloorMapStats> floorStats;
  /// Stored outdoor connections between buildings.
  final List<BuildingConnection> connections;
  /// Entrances mapped across buildings, keyed by building name.
  final Map<String, List<Waypoint>> buildingEntrances;
  final bool isLoading;
  final bool isSyncing;
  final String? errorMessage;

  const DashboardState({
    this.entries = const [],
    this.buildingLocations = const {},
    this.buildingPlaceNames = const {},
    this.knownBuildings = const {},
    this.floorStats = const {},
    this.connections = const [],
    this.buildingEntrances = const {},
    this.isLoading = true,
    this.isSyncing = false,
    this.errorMessage,
  });

  DashboardState copyWith({
    List<BuildingMapEntry>? entries,
    Map<String, BuildingLocation>? buildingLocations,
    Map<String, String>? buildingPlaceNames,
    Set<String>? knownBuildings,
    Map<String, FloorMapStats>? floorStats,
    List<BuildingConnection>? connections,
    Map<String, List<Waypoint>>? buildingEntrances,
    bool? isLoading,
    bool? isSyncing,
    String? errorMessage,
  }) {
    return DashboardState(
      entries: entries ?? this.entries,
      buildingLocations: buildingLocations ?? this.buildingLocations,
      buildingPlaceNames: buildingPlaceNames ?? this.buildingPlaceNames,
      knownBuildings: knownBuildings ?? this.knownBuildings,
      floorStats: floorStats ?? this.floorStats,
      connections: connections ?? this.connections,
      buildingEntrances: buildingEntrances ?? this.buildingEntrances,
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      errorMessage: errorMessage,
    );
  }

  /// All unique entrance waypoints across all buildings that have GPS coordinates.
  List<Waypoint> get entrancesWithGps {
    final seen = <String>{};
    final result = <Waypoint>[];
    for (final entry in buildingEntrances.entries) {
      for (final e in entry.value) {
        if (e.hasGps) {
          final key = '${entry.key}_${e.floor}_${e.label}_${e.latitude}_${e.longitude}';
          if (seen.add(key)) {
            result.add(e);
          }
        }
      }
    }
    return result;
  }

  /// Effective GPS pin location for a building: mean of entrances with GPS if available,
  /// else recorded building location.
  (double, double)? buildingPinLocation(String buildingName) {
    final entrances = (buildingEntrances[buildingName] ?? const [])
        .where((e) => e.hasGps)
        .toList();
    if (entrances.isNotEmpty) {
      final lat = entrances.map((e) => e.latitude!).reduce((a, b) => a + b) / entrances.length;
      final lng = entrances.map((e) => e.longitude!).reduce((a, b) => a + b) / entrances.length;
      return (lat, lng);
    }
    final loc = buildingLocations[buildingName];
    if (loc != null) return (loc.latitude, loc.longitude);
    return null;
  }

  /// Groups map entries by building name, sorted ascending by floor.
  Map<String, List<BuildingMapEntry>> get groupedByBuilding {
    final byBuilding = <String, List<BuildingMapEntry>>{};
    for (final e in entries) {
      byBuilding.putIfAbsent(e.name, () => []).add(e);
    }
    for (final floors in byBuilding.values) {
      floors.sort((a, b) => (a.floor ?? 1 << 30).compareTo(b.floor ?? 1 << 30));
    }
    return byBuilding;
  }

  /// Every known building: ones with floors, ones with only cached GPS,
  /// and ones registered explicitly with zero floors. Sorted A–Z.
  List<String> get allBuildingNames {
    final names = <String>{
      ...groupedByBuilding.keys,
      ...buildingLocations.keys,
      ...knownBuildings,
    };
    final sorted = names.toList()..sort();
    return sorted;
  }
}

/// Controller for Dashboard screen maps, loading, syncing, and deletion.
class DashboardNotifier extends Notifier<DashboardState> {
  @override
  DashboardState build() {
    // Initial state is loading; kick off initial map load
    Future.microtask(() => loadMaps());
    return const DashboardState(isLoading: true);
  }

  FirestoreService get _firestore => ref.read(firestoreServiceProvider);

  GeocodingService get _geo => GeocodingService.instance;

  /// Registry key tracking buildings that exist with zero floors.
  static const registryKey = 'building_registry';
  static const _tombstonePrefix = 'building_tombstone_';

  static Set<String> _decodeRegistry(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = jsonDecode(raw) as List;
      return {for (final e in list) e.toString()};
    } catch (_) {
      return {};
    }
  }

  /// Loads saved maps from local storage and syncs with Firestore.
  /// Buildings are never auto-removed: deleting the last floor of a
  /// building keeps the building (with zero floors) registered.
  Future<void> loadMaps() async {
    state = state.copyWith(isSyncing: true);

    // Sync any new maps/buildings from Firestore in background
    try {
      await _firestore.syncFromFirestore();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final entries = <BuildingMapEntry>[];
    final locations = <String, BuildingLocation>{};
    final stats = <String, FloorMapStats>{};
    final buildingEntrances = <String, List<Waypoint>>{};

    for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
      try {
        final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
        final name = data['name'] as String? ?? key.substring(4);
        final floor = data['floor'] as int?;
        final label = (data['label'] as String?)?.trim();

        entries.add(BuildingMapEntry(
          key: key,
          name: name,
          floor: floor,
          label: (label == null || label.isEmpty) ? null : label,
        ));
        stats[key] = FloorMapStats.fromPayload(data);

        for (final w in (data['waypoints'] as List? ?? const [])) {
          try {
            final wp = Waypoint.fromJson(Map<String, dynamic>.from(w as Map));
            if (wp.isEntrance) {
              buildingEntrances.putIfAbsent(name, () => []).add(wp);
            }
          } catch (_) {}
        }

        if (data['latitude'] != null && data['longitude'] != null && !locations.containsKey(name)) {
          locations[name] = BuildingLocation(
            latitude: (data['latitude'] as num).toDouble(),
            longitude: (data['longitude'] as num).toDouble(),
            accuracy: (data['accuracy'] ?? data['gpsAccuracy'] as num?)?.toDouble() ?? 0.0,
            timestamp: DateTime.tryParse(data['timestamp'] as String? ?? '') ?? DateTime.now(),
          );
        }
      } catch (_) {}
    }

    // Load connections between buildings (from Firestore / SharedPreferences cache)
    List<BuildingConnection> connections = const [];
    try {
      connections = await BuildingRepository.instance.loadConnections(sync: true);
    } catch (_) {
      try {
        connections = _readConnections(prefs);
      } catch (_) {}
    }

    // Also check building_gps_ cache
    for (final key in prefs.getKeys().where((k) => k.startsWith('building_gps_'))) {
      final bName = key.substring('building_gps_'.length);
      if (!locations.containsKey(bName)) {
        try {
          final locData = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
          locations[bName] = BuildingLocation.fromJson(locData);
        } catch (_) {}
      }
    }

    // Explicit registry (covers buildings with no GPS and no floors).
    final registry = _decodeRegistry(prefs.getString(registryKey));
    // Every building with floors or GPS implicitly exists — persist that
    // so a restart never drops an empty building.
    registry.addAll([for (final e in entries) e.name, ...locations.keys]);

    // Tombstones win: names deleted on this device stay deleted even if
    // the cloud still serves them (remote delete pending or offline).
    final tombstoned = {
      for (final k in prefs.getKeys().where((k) => k.startsWith(_tombstonePrefix)))
        k.substring(_tombstonePrefix.length),
    };
    if (tombstoned.isNotEmpty) {
      entries.removeWhere((e) => tombstoned.contains(e.name));
      stats.removeWhere((key, _) => tombstoned.any((n) => key.startsWith('map_$n#')));
      locations.removeWhere((name, _) => tombstoned.contains(name));
      buildingEntrances.removeWhere((name, _) => tombstoned.contains(name));
      registry.removeAll(tombstoned);
    }
    await prefs.setString(registryKey, jsonEncode(registry.toList()));

    // Cached OSM place names load synchronously so the list paints
    // instantly; fresh lookups happen in the background below.
    final places = Map<String, String>.from(state.buildingPlaceNames);
    places.removeWhere((name, _) =>
        tombstoned.contains(name) || !registry.contains(name));
    for (final name in registry) {
      final loc = locations[name];
      if (loc == null) continue;
      try {
        final cached = await _geo.readCached(name);
        if (cached == null) continue;
        if (GeocodingService.isStale(
          cachedLat: cached.lat,
          cachedLon: cached.lon,
          currentLat: loc.latitude,
          currentLon: loc.longitude,
          fetchedAt: cached.fetchedAt,
        )) {
          continue;
        }
        places[name] = cached.place.short;
      } catch (_) {}
    }

    state = state.copyWith(
      entries: entries,
      buildingLocations: locations,
      buildingPlaceNames: places,
      knownBuildings: registry,
      floorStats: stats,
      connections: connections,
      buildingEntrances: buildingEntrances,
      isLoading: false,
      isSyncing: false,
    );

    unawaited(refreshPlaceNames());
  }

  /// Background OSM reverse-geocode for buildings with GPS but no fresh
  /// cached place name. Respects Nominatim fair-use (serial, ≥1s apart via
  /// [GeocodingService]); updates cards incrementally as names arrive.
  Future<void> refreshPlaceNames() async {
    try {
      final names = state.allBuildingNames
          .where((n) => state.buildingLocations[n] != null)
          .toList();
      for (final name in names) {
        final loc = state.buildingLocations[name];
        if (loc == null) continue;
        try {
          final cached = await _geo.readCached(name);
          if (cached != null &&
              !GeocodingService.isStale(
                cachedLat: cached.lat,
                cachedLon: cached.lon,
                currentLat: loc.latitude,
                currentLon: loc.longitude,
                fetchedAt: cached.fetchedAt,
              )) {
            if (state.buildingPlaceNames[name] != cached.place.short) {
              state = state.copyWith(
                buildingPlaceNames: Map<String, String>.from(
                    state.buildingPlaceNames)
                  ..[name] = cached.place.short,
              );
            }
            continue;
          }
        } catch (_) {}
        final place =
            await _geo.reverseGeocode(loc.latitude, loc.longitude);
        if (place == null) continue;
        try {
          await _geo.writeCached(name, loc.latitude, loc.longitude, place);
        } catch (_) {}
        state = state.copyWith(
          buildingPlaceNames:
              Map<String, String>.from(state.buildingPlaceNames)
                ..[name] = place.short,
        );
      }
    } catch (_) {}
  }

  /// Registers a building shell (possibly with zero floors) so it survives
  /// reloads and appears in the studio even before anything is recorded.
  Future<void> registerBuilding(String name, [BuildingLocation? location]) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    // Recreating a name clears any prior delete tombstone.
    await prefs.remove('$_tombstonePrefix$trimmed');
    final registry = _decodeRegistry(prefs.getString(registryKey))..add(trimmed);
    await prefs.setString(registryKey, jsonEncode(registry.toList()));
    if (location != null) {
      await prefs.setString('building_gps_$trimmed', jsonEncode(location.toJson()));
    }
    unawaited(_firestore.saveBuilding(
      buildingName: trimmed,
      location: location,
    ));
    state = state.copyWith(knownBuildings: registry);
    if (location != null) unawaited(refreshPlaceNames());
  }

  /// Deletes a map from local storage and dual-deletes in Firestore.
  /// The parent building is intentionally kept (possibly with zero floors).
  /// The entry is removed from state synchronously so the UI reflects
  /// the deletion immediately; persistence + cloud follow.
  Future<void> deleteMap(String key) async {
    final entry = state.entries.cast<BuildingMapEntry?>().firstWhere(
      (e) => e?.key == key,
      orElse: () => null,
    );

    // 1. Optimistic UI update.
    state = state.copyWith(
      entries: state.entries.where((e) => e.key != key).toList(),
      floorStats: Map<String, FloorMapStats>.from(state.floorStats)
        ..remove(key),
      isSyncing: true,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);

    if (entry != null) {
      try {
        await _firestore.deleteMap(
          mapKey: key,
          buildingName: entry.name,
          floor: entry.floor ?? 0,
        );
      } catch (_) {}
      // Drop outdoor connections anchored to the deleted floor.
      if (entry.floor != null) {
        final ops = <Future>[];
        await _dropFloorConnections(
            prefs, ops, entry.name, entry.floor!);
        await Future.wait(ops);
      }
    }

    await loadMaps();
  }

  /// Checks if a floor in a building already exists.
  bool exists(String name, int floor) {
    return state.entries.any((e) => e.name == name && e.floor == floor);
  }

  /// Case-insensitive check for whether a building name is taken.
  bool buildingExists(String name) {
    final needle = name.trim().toLowerCase();
    return state.allBuildingNames.any((b) => b.toLowerCase() == needle);
  }

  /// Renames a building and all of its floor maps (local + Firestore).
  /// Returns true on success; false when [newName] is invalid/taken.
  Future<bool> renameBuilding(String oldName, String newName) async {
    final from = oldName.trim();
    final to = newName.trim();
    if (from.isEmpty || to.isEmpty || from == to) return false;
    if (!state.allBuildingNames.contains(from)) return false;
    if (buildingExists(to)) return false;

    // 1. Optimistic UI update — immediate.
    final renamedEntries = [
      for (final e in state.entries)
        e.name == from
            ? BuildingMapEntry(key: e.key.replaceFirst('map_$from#', 'map_$to#'), name: to, floor: e.floor, label: e.label)
            : e,
    ];
    final renamedLocations =
        Map<String, BuildingLocation>.from(state.buildingLocations);
    final movedLoc = renamedLocations.remove(from);
    if (movedLoc != null) renamedLocations[to] = movedLoc;
    final renamedKnown = Set<String>.from(state.knownBuildings)
      ..remove(from)
      ..add(to);
    final renamedStats = <String, FloorMapStats>{};
    state.floorStats.forEach((key, value) {
      renamedStats[key.startsWith('map_$from#')
          ? key.replaceFirst('map_$from#', 'map_$to#')
          : key] = value;
    });
    state = state.copyWith(
      entries: renamedEntries,
      buildingLocations: renamedLocations,
      buildingPlaceNames: Map<String, String>.from(state.buildingPlaceNames)
        ..remove(from),
      knownBuildings: renamedKnown,
      floorStats: renamedStats,
      isSyncing: true,
    );

    final prefs = await SharedPreferences.getInstance();
    // Renaming onto a previously-deleted name revives it.
    await prefs.remove('$_tombstonePrefix$to');

    // Migrate every floor payload + key: map_<old>#<floor> -> map_<new>#<floor>.
    final floorKeys = prefs
        .getKeys()
        .where((k) => k.startsWith('map_$from#'))
        .toList();
    final remoteOps = <Future>[];
    for (final oldKey in floorKeys) {
      final raw = prefs.getString(oldKey);
      final suffix = oldKey.substring('map_$from#'.length);
      final newKey = 'map_$to#$suffix';
      if (raw != null) {
        try {
          final data = Map<String, dynamic>.from(
              jsonDecode(raw) as Map);
          data['name'] = to;
          await prefs.setString(newKey, jsonEncode(data));
        } catch (_) {
          await prefs.setString(newKey, raw);
        }
      }
      await prefs.remove(oldKey);
      final floor = int.tryParse(suffix);
      remoteOps.add(_firestore.renameFloorMap(
        oldMapKey: oldKey,
        newMapKey: newKey,
        oldBuilding: from,
        newBuilding: to,
        floor: floor ?? 0,
      ).catchError((_) {}));
    }

    // Migrate cached GPS.
    final oldGps = prefs.getString('building_gps_$from');
    if (oldGps != null) {
      await prefs.setString('building_gps_$to', oldGps);
      await prefs.remove('building_gps_$from');
    }

    // Migrate cached OSM place name.
    final oldPlace = prefs.getString(GeocodingService.cacheKey(from));
    if (oldPlace != null) {
      await prefs.setString(GeocodingService.cacheKey(to), oldPlace);
      await prefs.remove(GeocodingService.cacheKey(from));
    }

    // Update registry.
    final registry = _decodeRegistry(prefs.getString(registryKey))
      ..remove(from)
      ..add(to);
    await prefs.setString(registryKey, jsonEncode(registry.toList()));

    // Outdoor connections referencing the old building name.
    await _migrateConnections(prefs, remoteOps,
        renameFrom: from, renameTo: to);

    // Await remote ops so the reconciling loadMaps() can't re-pull stale names.
    remoteOps.add(_firestore.renameBuilding(
      oldName: from,
      newName: to,
      gpsRaw: oldGps,
    ).catchError((_) {}));
    await Future.wait(remoteOps);

    await loadMaps();
    return true;
  }

  /// Deletes a building shell plus all of its floor maps (local + Firestore).
  /// Works for buildings with zero floors too. Returns floors removed.
  /// The building is removed from state synchronously so the UI reflects
  /// the deletion immediately; persistence + cloud follow.
  Future<int> deleteBuilding(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 0;

    // 1. Optimistic UI update — immediate.
    final removedCount =
        state.entries.where((e) => e.name == trimmed).length;
    state = state.copyWith(
      entries: state.entries.where((e) => e.name != trimmed).toList(),
      buildingLocations: Map<String, BuildingLocation>.from(
          state.buildingLocations)
        ..remove(trimmed),
      buildingPlaceNames: Map<String, String>.from(state.buildingPlaceNames)
        ..remove(trimmed),
      knownBuildings: Set<String>.from(state.knownBuildings)
        ..remove(trimmed),
      floorStats: Map<String, FloorMapStats>.from(state.floorStats)
        ..removeWhere((key, _) => key.startsWith('map_$trimmed#')),
      isSyncing: true,
    );

    // 2. Local persistence. The tombstone stops a later cloud sync from
    // resurrecting the building when the remote delete hasn't landed yet
    // (or this device is offline).
    final prefs = await SharedPreferences.getInstance();
    final floorKeys = prefs
        .getKeys()
        .where((k) => k.startsWith('map_$trimmed#'))
        .toList();
    for (final key in floorKeys) {
      await prefs.remove(key);
    }
    await prefs.remove('building_gps_$trimmed');
    await prefs.remove(GeocodingService.cacheKey(trimmed));
    final registry = _decodeRegistry(prefs.getString(registryKey))
      ..remove(trimmed);
    await prefs.setString(registryKey, jsonEncode(registry.toList()));
    await prefs.setString(
        '$_tombstonePrefix$trimmed', DateTime.now().toIso8601String());

    // 3. Remote deletes — awaited so the reconciling loadMaps() below
    // can't re-pull the just-deleted building from Firestore.
    final remoteDeletes = <Future>[];
    for (final key in floorKeys) {
      final floor = int.tryParse(key.substring('map_$trimmed#'.length)) ?? 0;
      remoteDeletes.add(_firestore.deleteMap(
        mapKey: key,
        buildingName: trimmed,
        floor: floor,
      ).catchError((_) {}));
    }
    remoteDeletes.add(
        _firestore.deleteBuilding(buildingName: trimmed).catchError((_) {}));
    // Outdoor connections touching the deleted building go too.
    await _migrateConnections(prefs, remoteDeletes, dropBuilding: trimmed);

    await Future.wait(remoteDeletes);

    // 4. Reconcile with storage.
    await loadMaps();
    return removedCount;
  }

  // ---- Building & floor editing -----------------------------------------

  static const _connectionsKey = 'building_connections';

  List<BuildingConnection> _readConnections(SharedPreferences prefs) {
    try {
      final list = jsonDecode(prefs.getString(_connectionsKey) ?? '[]') as List;
      return [
        for (final c in list)
          BuildingConnection.fromJson(Map<String, dynamic>.from(c as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeConnections(
      SharedPreferences prefs, List<BuildingConnection> all) {
    return prefs.setString(
        _connectionsKey, jsonEncode([for (final c in all) c.toJson()]));
  }

  EntranceRef _movedEnd(EntranceRef end,
      {String? renameFrom,
      String? renameTo,
      String? building,
      int? oldFloor,
      int? newFloor}) {
    var b = end.building;
    var f = end.floor;
    if (renameFrom != null && renameTo != null && b == renameFrom) b = renameTo;
    if (building != null && oldFloor != null && newFloor != null) {
      if (b == building && f == oldFloor) f = newFloor;
    }
    if (b == end.building && f == end.floor) return end;
    return EntranceRef(building: b, floor: f, label: end.label);
  }

  /// Rewrites stored outdoor connections after a rename / renumber.
  /// When [dropBuilding] is set, connections touching it are deleted instead.
  /// Queues matching Firestore ops into [remoteOps].
  Future<void> _migrateConnections(
    SharedPreferences prefs,
    List<Future> remoteOps, {
    String? renameFrom,
    String? renameTo,
    String? building,
    int? oldFloor,
    int? newFloor,
    String? dropBuilding,
  }) async {
    final current = _readConnections(prefs);
    if (current.isEmpty) return;
    final next = <BuildingConnection>[];
    var changed = false;
    for (final c in current) {
      if (dropBuilding != null && c.involves(dropBuilding)) {
        changed = true;
        remoteOps.add(
            _firestore.deleteConnection(c.id).catchError((_) {}));
        continue;
      }
      final a = _movedEnd(c.a,
          renameFrom: renameFrom,
          renameTo: renameTo,
          building: building,
          oldFloor: oldFloor,
          newFloor: newFloor);
      final b = _movedEnd(c.b,
          renameFrom: renameFrom,
          renameTo: renameTo,
          building: building,
          oldFloor: oldFloor,
          newFloor: newFloor);
      if (identical(a, c.a) && identical(b, c.b)) {
        next.add(c);
        continue;
      }
      changed = true;
      final moved = BuildingConnection(
        a: a,
        b: b,
        distanceMeters: c.distanceMeters,
        durationSeconds: c.durationSeconds,
        route: c.route,
        source: c.source,
      );
      next.add(moved);
      remoteOps.add(_firestore.deleteConnection(c.id).catchError((_) {}));
      remoteOps.add(
          _firestore.saveConnection(moved.id, moved.toJson()).catchError((_) {}));
    }
    if (changed) await _writeConnections(prefs, next);
  }

  /// Deletes stored outdoor connections anchored to one building floor
  /// (used when that floor is deleted). Queues Firestore ops into [remoteOps].
  Future<void> _dropFloorConnections(
    SharedPreferences prefs,
    List<Future> remoteOps,
    String building,
    int floor,
  ) async {
    final current = _readConnections(prefs);
    if (current.isEmpty) return;
    final keep = <BuildingConnection>[];
    var changed = false;
    for (final c in current) {
      final touches = (c.a.building == building && c.a.floor == floor) ||
          (c.b.building == building && c.b.floor == floor);
      if (touches) {
        changed = true;
        remoteOps
            .add(_firestore.deleteConnection(c.id).catchError((_) {}));
      } else {
        keep.add(c);
      }
    }
    if (changed) await _writeConnections(prefs, keep);
  }

  /// Sets (or clears, when [label] is blank) a floor's custom display label.
  /// Returns false when the floor doesn't exist.
  Future<bool> setFloorLabel({
    required String building,
    required int floor,
    required String label,
  }) async {
    final key = 'map_$building#$floor';
    if (!state.entries.any((e) => e.key == key)) return false;
    final trimmed = label.trim();

    state = state.copyWith(
      entries: [
        for (final e in state.entries)
          e.key == key
              ? BuildingMapEntry(
                  key: e.key,
                  name: e.name,
                  floor: e.floor,
                  label: trimmed.isEmpty ? null : trimmed)
              : e,
      ],
      isSyncing: true,
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) {
      await loadMaps();
      return false;
    }
    try {
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (trimmed.isEmpty) {
        data.remove('label');
      } else {
        data['label'] = trimmed;
      }
      await prefs.setString(key, jsonEncode(data));
      unawaited(_firestore.saveMap(
        mapKey: key,
        buildingName: building,
        floor: floor,
        mapData: data,
        location: state.buildingLocations[building],
      ));
    } catch (_) {}

    await loadMaps();
    return true;
  }

  /// Renumbers a floor, migrating its map key, payload (floor, segments,
  /// steps, waypoints), outdoor connections and cloud records.
  /// Returns false on validation failure or missing floor.
  Future<bool> renumberFloor({
    required String building,
    required int oldFloor,
    required int newFloor,
  }) async {
    if (oldFloor == newFloor) return false;
    if (exists(building, newFloor)) return false;
    final oldKey = 'map_$building#$oldFloor';
    final newKey = 'map_$building#$newFloor';
    if (!state.entries.any((e) => e.key == oldKey)) return false;

    // 1. Optimistic UI update — immediate.
    state = state.copyWith(
      entries: [
        for (final e in state.entries)
          e.key == oldKey
              ? BuildingMapEntry(
                  key: newKey, name: e.name, floor: newFloor, label: e.label)
              : e,
      ],
      floorStats: {
        for (final kv in state.floorStats.entries)
          kv.key == oldKey ? newKey : kv.key: kv.value,
      },
      isSyncing: true,
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(oldKey);
    if (raw == null) {
      await loadMaps();
      return false;
    }

    // 2. Migrate the payload's floor fields.
    final remoteOps = <Future>[];
    try {
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      data['floor'] = newFloor;
      for (final s in (data['segments'] as List? ?? const [])) {
        (s as Map)['floor'] = newFloor;
        for (final st in ((s)['steps'] as List? ?? const [])) {
          (st as Map)['floor'] = newFloor;
        }
      }
      for (final w in (data['waypoints'] as List? ?? const [])) {
        (w as Map)['floor'] = newFloor;
      }
      await prefs.setString(newKey, jsonEncode(data));
      await prefs.remove(oldKey);
      remoteOps.add(_firestore.deleteMap(
        mapKey: oldKey,
        buildingName: building,
        floor: oldFloor,
      ).catchError((_) {}));
      remoteOps.add(_firestore.saveMap(
        mapKey: newKey,
        buildingName: building,
        floor: newFloor,
        mapData: data,
        location: state.buildingLocations[building],
      ).catchError((_) {}));
      remoteOps.add(_firestore.updateBuildingFloors(
        buildingName: building,
        remove: oldFloor,
        add: newFloor,
      ).catchError((_) {}));
    } catch (_) {
      await loadMaps();
      return false;
    }

    // 3. Outdoor connections pointing at the old floor number.
    await _migrateConnections(prefs, remoteOps,
        building: building, oldFloor: oldFloor, newFloor: newFloor);

    await Future.wait(remoteOps);
    await loadMaps();
    return true;
  }

  /// Replaces a building's GPS fix (local cache, every floor payload and
  /// Firestore). Works for buildings that never had a fix (GPS pending).
  Future<void> updateBuildingLocation(
      String building, BuildingLocation location) async {
    final trimmed = building.trim();
    if (trimmed.isEmpty) return;

    state = state.copyWith(
      buildingLocations: Map<String, BuildingLocation>.from(
          state.buildingLocations)
        ..[trimmed] = location,
      buildingPlaceNames: Map<String, String>.from(state.buildingPlaceNames)
        ..remove(trimmed),
      isSyncing: true,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'building_gps_$trimmed', jsonEncode(location.toJson()));
    // Drop the stale place lookup; loadMaps + refresh will re-resolve it.
    await prefs.remove(GeocodingService.cacheKey(trimmed));
    final remoteOps = <Future>[];
    for (final key in prefs
        .getKeys()
        .where((k) => k.startsWith('map_$trimmed#'))) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        data['latitude'] = location.latitude;
        data['longitude'] = location.longitude;
        data['accuracy'] = location.accuracy;
        data['timestamp'] = location.timestamp.toIso8601String();
        await prefs.setString(key, jsonEncode(data));
        remoteOps.add(_firestore.saveMap(
          mapKey: key,
          buildingName: trimmed,
          floor: (data['floor'] as int?) ?? 0,
          mapData: data,
          location: location,
        ).catchError((_) {}));
      } catch (_) {}
    }
    remoteOps.add(_firestore.saveBuilding(
      buildingName: trimmed,
      location: location,
    ).catchError((_) {}));

    await Future.wait(remoteOps);
    await loadMaps();
  }
}

/// Provider for the dashboard state notifier.
final dashboardProvider = NotifierProvider<DashboardNotifier, DashboardState>(
  DashboardNotifier.new,
);
