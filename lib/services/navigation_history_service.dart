import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/navigation_trip.dart';

/// Offline store for completed navigations ("Recent Trips").
///
/// Trips live in SharedPreferences under a single JSON list (newest first,
/// capped at [maxEntries]). Nothing is pushed to Firebase: there is no
/// user auth in the system.
class NavigationHistoryService {
  static final NavigationHistoryService instance =
      NavigationHistoryService._();
  NavigationHistoryService._();

  static const storageKey = 'mapx_navigation_history_v1';
  static const maxEntries = 50;

  /// Minimum gap before logging the exact same route again, to avoid
  /// double entries from repeated arrival callbacks.
  static const duplicateWindow = Duration(minutes: 1);

  Future<List<NavigationTrip>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List;
      final trips = <NavigationTrip>[];
      for (final entry in list) {
        try {
          final trip = NavigationTrip.fromJson(
              Map<String, dynamic>.from(entry as Map));
          if (trip.id.isNotEmpty &&
              trip.fromBuilding.isNotEmpty &&
              trip.toBuilding.isNotEmpty) {
            trips.add(trip);
          }
        } catch (_) {}
      }
      trips.sort((a, b) => b.completedAt.compareTo(a.completedAt));
      return trips;
    } catch (e) {
      debugPrint('NavigationHistoryService.load error: $e');
      return const [];
    }
  }

  Future<NavigationTrip?> latest() async {
    final trips = await load();
    return trips.isEmpty ? null : trips.first;
  }

  Future<void> _write(List<NavigationTrip> trips) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          storageKey, jsonEncode([for (final t in trips) t.toJson()]));
    } catch (e) {
      debugPrint('NavigationHistoryService._write error: $e');
    }
  }

  bool _sameRoute(NavigationTrip a, NavigationTrip b) =>
      a.fromBuilding == b.fromBuilding &&
      a.fromFloor == b.fromFloor &&
      a.fromLabel == b.fromLabel &&
      a.toBuilding == b.toBuilding &&
      a.toFloor == b.toFloor &&
      a.toLabel == b.toLabel;

  /// Records a completed navigation. Returns the stored trip, or null when
  /// the same route was just logged inside [duplicateWindow].
  Future<NavigationTrip?> logTrip({
    required String fromBuilding,
    int? fromFloor,
    required String fromLabel,
    required String toBuilding,
    int? toFloor,
    required String toLabel,
    double? distanceMeters,
    DateTime? completedAt,
  }) async {
    final from = fromBuilding.trim();
    final to = toBuilding.trim();
    if (from.isEmpty || to.isEmpty) return null;
    if (fromLabel.trim().isEmpty || toLabel.trim().isEmpty) return null;

    final now = completedAt ?? DateTime.now();
    final trip = NavigationTrip(
      id: now.microsecondsSinceEpoch.toString(),
      fromBuilding: from,
      fromFloor: fromFloor,
      fromLabel: fromLabel.trim(),
      toBuilding: to,
      toFloor: toFloor,
      toLabel: toLabel.trim(),
      distanceMeters: distanceMeters,
      completedAt: now,
    );

    final trips = List<NavigationTrip>.of(await load());
    if (trips.isNotEmpty &&
        _sameRoute(trips.first, trip) &&
        now.difference(trips.first.completedAt).abs() < duplicateWindow) {
      return null;
    }
    trips.insert(0, trip);
    await _write(trips.length > maxEntries
        ? trips.sublist(0, maxEntries)
        : trips);
    return trip;
  }

  Future<void> delete(String id) async {
    final trips = List<NavigationTrip>.of(await load());
    trips.removeWhere((t) => t.id == id);
    await _write(trips);
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (e) {
      debugPrint('NavigationHistoryService.clear error: $e');
    }
  }
}
