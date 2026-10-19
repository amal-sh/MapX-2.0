import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BuildingLocation {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;

  const BuildingLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'timestamp': timestamp.toIso8601String(),
      };

  factory BuildingLocation.fromJson(Map<String, dynamic> json) => BuildingLocation(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0.0,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      );

  @override
  String toString() =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)} (±${accuracy.toStringAsFixed(1)}m)';
}

class LocationService {
  static final LocationService instance = LocationService._();
  LocationService._();

  static const _cachedLocationKey = 'last_known_gps_location';

  BuildingLocation? _cachedLocation;

  /// Returns the most recently fetched GPS fix, if available.
  BuildingLocation? get cachedLocation => _cachedLocation;
  BuildingLocation? get lastLocation => _cachedLocation;

  /// Sets or clears the cached location (useful for tests and manual resets).
  void setCachedLocation(BuildingLocation? loc) {
    _cachedLocation = loc;
    if (loc != null) {
      _persistLocation(loc);
    }
  }

  Future<void> _persistLocation(BuildingLocation loc) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cachedLocationKey, jsonEncode(loc.toJson()));
    } catch (_) {}
  }

  /// Returns the cached location in memory, or restores from SharedPreferences /
  /// last known OS position without waiting for a new GPS fix.
  Future<BuildingLocation?> getLastKnownOrCachedLocation() async {
    if (_cachedLocation != null) return _cachedLocation;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_cachedLocationKey);
      if (saved != null) {
        final loc = BuildingLocation.fromJson(jsonDecode(saved) as Map<String, dynamic>);
        _cachedLocation = loc;
        return loc;
      }
    } catch (_) {}
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        final loc = BuildingLocation(
          latitude: lastKnown.latitude,
          longitude: lastKnown.longitude,
          accuracy: lastKnown.accuracy,
          timestamp: lastKnown.timestamp,
        );
        _cachedLocation = loc;
        _persistLocation(loc);
        return loc;
      }
    } catch (_) {}
    return null;
  }

  /// Prompts the user for location permission if not already granted.
  Future<bool> requestPermission() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('Location services are disabled.');
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (e) {
      debugPrint('LocationService: requestPermission error: $e');
      return false;
    }
  }

  /// Opens the system location settings page.
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  /// Requests permissions and retrieves the device's current GPS position.
  /// Attempts high accuracy first, falls back to balanced/medium accuracy
  /// if high-accuracy GPS times out, and falls back to last known position.
  Future<BuildingLocation?> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('Location services are disabled.');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('Location permissions are denied');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('Location permissions are permanently denied.');
        return null;
      }

      Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
      } catch (highAccuracyError) {
        debugPrint('High accuracy location timed out/failed ($highAccuracyError), falling back to medium accuracy...');
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 5),
          ),
        );
      }

      final loc = BuildingLocation(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        timestamp: position.timestamp,
      );
      _cachedLocation = loc;
      _persistLocation(loc);
      return loc;
    } catch (e) {
      debugPrint('Error getting GPS location: $e');
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          final loc = BuildingLocation(
            latitude: lastKnown.latitude,
            longitude: lastKnown.longitude,
            accuracy: lastKnown.accuracy,
            timestamp: lastKnown.timestamp,
          );
          _cachedLocation = loc;
          _persistLocation(loc);
          return loc;
        }
      } catch (_) {}
      return _cachedLocation;
    }
  }

  /// Provides a stream of live location updates.
  /// Automatically updates [_cachedLocation] and persists it.
  /// Handles permission checks and platform errors gracefully.
  Stream<BuildingLocation> getPositionStream({
    LocationAccuracy accuracy = LocationAccuracy.high,
    int distanceFilter = 2,
  }) async* {
    try {
      final hasPermission = await requestPermission();
      if (!hasPermission) return;

      final locationSettings = LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      );

      yield* Geolocator.getPositionStream(locationSettings: locationSettings)
          .handleError((error) {
        debugPrint('LocationService: stream error: $error');
      }).map((pos) {
        final loc = BuildingLocation(
          latitude: pos.latitude,
          longitude: pos.longitude,
          accuracy: pos.accuracy,
          timestamp: pos.timestamp,
        );
        _cachedLocation = loc;
        _persistLocation(loc);
        return loc;
      });
    } catch (e) {
      debugPrint('LocationService: getPositionStream init error: $e');
    }
  }
}
