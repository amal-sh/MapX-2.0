import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firestore_service.dart';
import '../services/location_service.dart';
import '../services/search_service.dart';

/// Provider for SharedPreferences instance.
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

/// Provider for FirestoreService singleton. Overridable in tests.
final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  return FirestoreService.instance;
});

/// Provider for LocationService singleton. Overridable in tests.
final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService.instance;
});

/// Provider for holding the current user GPS location.
final userLocationProvider = StateProvider<BuildingLocation?>((ref) => null);

/// Provider for SearchService singleton. Overridable in tests.
final searchServiceProvider = Provider<SearchService>((ref) {
  return SearchService.instance;
});

/// Provider for the user's selected basemap preference ('dark', 'light', 'standard').
final basemapPreferenceProvider =
    StateNotifierProvider<BasemapPreferenceNotifier, String>((ref) {
  return BasemapPreferenceNotifier();
});

class BasemapPreferenceNotifier extends StateNotifier<String> {
  BasemapPreferenceNotifier() : super('standard') {
    load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('mapx_prefs_basemap_theme');
      if (saved != null && (saved == 'dark' || saved == 'light' || saved == 'standard')) {
        state = saved;
      }
    } catch (_) {}
  }

  Future<void> setBasemap(String theme) async {
    state = theme;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mapx_prefs_basemap_theme', theme);
    } catch (_) {}
  }
}

