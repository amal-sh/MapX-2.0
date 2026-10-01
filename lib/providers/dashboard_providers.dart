import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firestore_service.dart';
import '../services/location_service.dart';
import 'service_providers.dart';

/// Represents a single saved floor map entry.
class BuildingMapEntry {
  final String key;
  final String name;
  final int? floor;

  const BuildingMapEntry({
    required this.key,
    required this.name,
    this.floor,
  });

  String get title => floor == null ? name : '$name · Floor $floor';
}

/// State for the dashboard screen: maps list, building locations, and sync status.
class DashboardState {
  final List<BuildingMapEntry> entries;
  final Map<String, BuildingLocation> buildingLocations;
  final bool isLoading;
  final bool isSyncing;
  final String? errorMessage;

  const DashboardState({
    this.entries = const [],
    this.buildingLocations = const {},
    this.isLoading = true,
    this.isSyncing = false,
    this.errorMessage,
  });

  DashboardState copyWith({
    List<BuildingMapEntry>? entries,
    Map<String, BuildingLocation>? buildingLocations,
    bool? isLoading,
    bool? isSyncing,
    String? errorMessage,
  }) {
    return DashboardState(
      entries: entries ?? this.entries,
      buildingLocations: buildingLocations ?? this.buildingLocations,
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      errorMessage: errorMessage,
    );
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

  /// Loads saved maps from local storage and syncs with Firestore.
  Future<void> loadMaps() async {
    state = state.copyWith(isSyncing: true);

    // Sync any new maps from Firestore in background
    try {
      await _firestore.syncFromFirestore();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final entries = <BuildingMapEntry>[];
    final locations = <String, BuildingLocation>{};

    for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
      try {
        final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
        final name = data['name'] as String? ?? key.substring(4);
        final floor = data['floor'] as int?;

        entries.add(BuildingMapEntry(
          key: key,
          name: name,
          floor: floor,
        ));

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

    state = state.copyWith(
      entries: entries,
      buildingLocations: locations,
      isLoading: false,
      isSyncing: false,
    );
  }

  /// Deletes a map from local storage and dual-deletes in Firestore.
  Future<void> deleteMap(String key) async {
    final entry = state.entries.cast<BuildingMapEntry?>().firstWhere(
      (e) => e?.key == key,
      orElse: () => null,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);

    if (entry != null) {
      unawaited(_firestore.deleteMap(
        mapKey: key,
        buildingName: entry.name,
        floor: entry.floor ?? 0,
      ));
    }

    await loadMaps();
  }

  /// Checks if a floor in a building already exists.
  bool exists(String name, int floor) {
    return state.entries.any((e) => e.name == name && e.floor == floor);
  }
}

/// Provider for the dashboard state notifier.
final dashboardProvider = NotifierProvider<DashboardNotifier, DashboardState>(
  DashboardNotifier.new,
);
