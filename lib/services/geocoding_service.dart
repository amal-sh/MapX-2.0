import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// OSM place name resolved via Nominatim reverse geocoding.
class PlaceName {
  final String short;
  final String full;

  const PlaceName({required this.short, required this.full});
}

/// Reverse-geocodes building GPS coordinates into human-readable place
/// names using Nominatim (OpenStreetMap data, no API key).
///
/// Fair-use rules: single request at a time, ≥1s between calls, persistent
/// cache. All failures return null so callers keep their existing subtitle.
class GeocodingService {
  static final GeocodingService instance = GeocodingService._();
  GeocodingService._();

  static const _base = 'https://nominatim.openstreetmap.org/reverse';
  static const _userAgent = 'MapX2 indoor navigation (student project)';
  static const _minInterval = Duration(milliseconds: 1100);
  static const _cacheTtl = Duration(days: 30);
  static const _moveThresholdMeters = 100.0;

  static String cacheKey(String building) => 'building_place_$building';

  DateTime? _lastRequest;

  Future<void> _respectRateLimit() async {
    final last = _lastRequest;
    if (last == null) return;
    final wait = _minInterval - DateTime.now().difference(last);
    if (wait > Duration.zero) await Future.delayed(wait);
  }

  /// Returns the OSM place name for [lat]/[lon], or null on any failure.
  Future<PlaceName?> reverseGeocode(
    double lat,
    double lon, {
    http.Client? client,
  }) async {
    await _respectRateLimit();
    final owned = client == null;
    final http.Client httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(
        '$_base?lat=$lat&lon=$lon&format=jsonv2&zoom=18&addressdetails=1',
      );
      final response = await httpClient
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      _lastRequest = DateTime.now();
      if (response.statusCode != 200) {
        debugPrint('GeocodingService: HTTP ${response.statusCode}');
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return parsePlace(json);
    } catch (e) {
      debugPrint('GeocodingService: reverseGeocode error: $e');
      return null;
    } finally {
      if (owned) httpClient.close();
    }
  }

  /// Derives a short display name from a Nominatim reverse response.
  /// Priority: building/amenity + road → suburb/neighbourhood + road →
  /// first two segments of display_name. Returns null when unusable.
  static PlaceName? parsePlace(Map<String, dynamic> json) {
    if (json['error'] != null) return null;
    final full = (json['display_name'] as String?)?.trim() ?? '';
    final address = json['address'] is Map
        ? Map<String, dynamic>.from(json['address'] as Map)
        : <String, dynamic>{};

    String? namedPlace;
    for (final key in const [
      'building',
      'amenity',
      'shop',
      'office',
      'leisure',
      'public_building',
      'house_number',
    ]) {
      final v = (address[key] as String?)?.trim();
      if (v != null && v.isNotEmpty) {
        namedPlace = v;
        break;
      }
    }
    final road = (address['road'] as String?)?.trim();
    final area = (address['suburb'] as String?)?.trim() ??
        (address['neighbourhood'] as String?)?.trim() ??
        (address['quarter'] as String?)?.trim();

    String short;
    if (namedPlace != null && road != null) {
      short = '$namedPlace, $road';
    } else if (namedPlace != null && area != null) {
      short = '$namedPlace, $area';
    } else if (namedPlace != null) {
      short = namedPlace;
    } else if (road != null && area != null) {
      short = '$road, $area';
    } else if (road != null) {
      short = road;
    } else if (area != null) {
      short = area;
    } else if (full.isNotEmpty) {
      short = full.split(',').take(2).join(',').trim();
    } else {
      return null;
    }
    if (short.isEmpty) return null;
    return PlaceName(short: short, full: full.isEmpty ? short : full);
  }

  /// Reads the cached place name for [building], or null when absent.
  Future<({PlaceName place, double lat, double lon, DateTime fetchedAt})?>
      readCached(String building) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey(building));
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final short = (data['short'] as String?)?.trim();
      if (short == null || short.isEmpty) return null;
      return (
        place: PlaceName(
          short: short,
          full: (data['full'] as String?) ?? short,
        ),
        lat: (data['lat'] as num).toDouble(),
        lon: (data['lon'] as num).toDouble(),
        fetchedAt: DateTime.tryParse(data['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCached(
    String building,
    double lat,
    double lon,
    PlaceName place,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        cacheKey(building),
        jsonEncode({
          'short': place.short,
          'full': place.full,
          'lat': lat,
          'lon': lon,
          'fetchedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      debugPrint('GeocodingService: cache write error: $e');
    }
  }

  static const userLocationCacheKey = 'user_current_place_cache';

  /// Reads the cached place name for the user's location, or null when absent.
  Future<({PlaceName place, double lat, double lon, DateTime fetchedAt})?>
      readUserPlace() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(userLocationCacheKey);
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final short = (data['short'] as String?)?.trim();
      if (short == null || short.isEmpty) return null;
      return (
        place: PlaceName(
          short: short,
          full: (data['full'] as String?) ?? short,
        ),
        lat: (data['lat'] as num).toDouble(),
        lon: (data['lon'] as num).toDouble(),
        fetchedAt: DateTime.tryParse(data['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }

  /// Writes the cached place name for the user's location.
  Future<void> writeUserPlace(
    double lat,
    double lon,
    PlaceName place,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        userLocationCacheKey,
        jsonEncode({
          'short': place.short,
          'full': place.full,
          'lat': lat,
          'lon': lon,
          'fetchedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      debugPrint('GeocodingService: writeUserPlace error: $e');
    }
  }

  /// Resolves the user's place name for [lat]/[lon].
  /// Uses cached result if fresh (<100m moved and <30 days old),
  /// otherwise reverse-geocodes with Nominatim and updates cache.
  Future<String?> resolveUserPlace(
    double lat,
    double lon, {
    http.Client? client,
  }) async {
    final cached = await readUserPlace();
    if (cached != null &&
        !isStale(
          cachedLat: cached.lat,
          cachedLon: cached.lon,
          currentLat: lat,
          currentLon: lon,
          fetchedAt: cached.fetchedAt,
        )) {
      return cached.place.short;
    }
    final fresh = await reverseGeocode(lat, lon, client: client);
    if (fresh != null) {
      await writeUserPlace(lat, lon, fresh);
      return fresh.short;
    }
    return cached?.place.short;
  }


  /// True when the cached fix is older than 30 days or the building moved
  /// more than ~100m since the lookup.
  static bool isStale({
    required double cachedLat,
    required double cachedLon,
    required double currentLat,
    required double currentLon,
    required DateTime fetchedAt,
  }) {
    if (DateTime.now().difference(fetchedAt) > _cacheTtl) return true;
    return _haversineMeters(cachedLat, cachedLon, currentLat, currentLon) >
        _moveThresholdMeters;
  }

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earth = 6371000.0;
    double rad(double d) => d * pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLon = rad(lon2 - lon1);
    final h = pow(sin(dLat / 2), 2) +
        cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
    return 2 * earth * asin(min(1.0, sqrt(h)));
  }
}
