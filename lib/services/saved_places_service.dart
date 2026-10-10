import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_place.dart';

/// Offline store for user-saved buildings, floors/blocks and rooms/places.
///
/// Everything lives in SharedPreferences under a single JSON list.
/// Nothing is pushed to Firebase: there is no user auth in the system.
class SavedPlacesService {
  static final SavedPlacesService instance = SavedPlacesService._();
  SavedPlacesService._();

  static const storageKey = 'mapx_saved_places_v1';

  Future<List<SavedPlace>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List;
      final places = <SavedPlace>[];
      for (final entry in list) {
        try {
          final place = SavedPlace.fromJson(
              Map<String, dynamic>.from(entry as Map));
          if (place.id.isNotEmpty && place.building.isNotEmpty) {
            places.add(place);
          }
        } catch (_) {}
      }
      // Newest first.
      places.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return places;
    } catch (e) {
      debugPrint('SavedPlacesService.load error: $e');
      return const [];
    }
  }

  Future<void> _write(List<SavedPlace> places) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          storageKey, jsonEncode([for (final p in places) p.toJson()]));
    } catch (e) {
      debugPrint('SavedPlacesService._write error: $e');
    }
  }

  Future<bool> isSaved(String id) async {
    final places = await load();
    return places.any((p) => p.id == id);
  }

  /// Inserts or refreshes [place], keeping newest first. No duplicates.
  Future<void> save(SavedPlace place) async {
    final places = List<SavedPlace>.of(await load());
    places.removeWhere((p) => p.id == place.id);
    places.insert(0, place);
    await _write(places);
  }

  Future<void> remove(String id) async {
    final places = List<SavedPlace>.of(await load());
    places.removeWhere((p) => p.id == id);
    await _write(places);
  }

  /// Toggles the saved state of [place]. Returns true when it is saved
  /// afterwards, false when it was removed.
  Future<bool> toggle(SavedPlace place) async {
    if (await isSaved(place.id)) {
      await remove(place.id);
      return false;
    }
    await save(place);
    return true;
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (e) {
      debugPrint('SavedPlacesService.clear error: $e');
    }
  }
}
