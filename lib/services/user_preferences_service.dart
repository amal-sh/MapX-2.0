import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Offline user preferences backing the drawer's Preferences sheet.
///
/// Stored in SharedPreferences only; nothing is pushed to Firebase.
class UserPreferencesService {
  static final UserPreferencesService instance = UserPreferencesService._();
  UserPreferencesService._();

  static const unitsKey = 'mapx_prefs_distance_units';
  static const themeKey = 'mapx_prefs_map_theme';

  static const unitsMeters = 'meters';
  static const unitsFeet = 'feet';
  static const themeMonochrome = 'monochrome';
  static const themeSystem = 'system';

  Future<String> loadDistanceUnits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final units = prefs.getString(unitsKey);
      return units == unitsFeet ? unitsFeet : unitsMeters;
    } catch (e) {
      debugPrint('UserPreferencesService.loadDistanceUnits error: $e');
      return unitsMeters;
    }
  }

  Future<void> saveDistanceUnits(String units) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          unitsKey, units == unitsFeet ? unitsFeet : unitsMeters);
    } catch (e) {
      debugPrint('UserPreferencesService.saveDistanceUnits error: $e');
    }
  }

  Future<String> loadMapTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final theme = prefs.getString(themeKey);
      return theme == themeSystem ? themeSystem : themeMonochrome;
    } catch (e) {
      debugPrint('UserPreferencesService.loadMapTheme error: $e');
      return themeMonochrome;
    }
  }

  Future<void> saveMapTheme(String theme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          themeKey, theme == themeSystem ? themeSystem : themeMonochrome);
    } catch (e) {
      debugPrint('UserPreferencesService.saveMapTheme error: $e');
    }
  }

  /// Formats [meters] with the stored unit preference.
  static String formatDistance(double meters, String units) {
    if (units == unitsFeet) {
      return '${(meters * 3.28084).round()} ft';
    }
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.round()} m';
  }
}
