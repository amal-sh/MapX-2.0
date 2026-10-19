import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocationService.instance.setCachedLocation(null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, null);
  });

  group('LocationService tests', () {
    test('BuildingLocation serialization and deserialization', () {
      final now = DateTime.now();
      final loc = BuildingLocation(
        latitude: 12.971598,
        longitude: 77.594562,
        accuracy: 4.5,
        timestamp: now,
      );

      final json = loc.toJson();
      expect(json['latitude'], 12.971598);
      expect(json['longitude'], 77.594562);
      expect(json['accuracy'], 4.5);

      final parsed = BuildingLocation.fromJson(json);
      expect(parsed.latitude, 12.971598);
      expect(parsed.longitude, 77.594562);
      expect(parsed.accuracy, 4.5);
      expect(parsed.toString(), contains('12.971598, 77.594562'));
    });

    test('caches and persists user location', () async {
      final loc = BuildingLocation(
        latitude: 37.7749,
        longitude: -122.4194,
        accuracy: 10.0,
        timestamp: DateTime.now(),
      );

      LocationService.instance.setCachedLocation(loc);
      expect(LocationService.instance.cachedLocation?.latitude, 37.7749);

      // Verify restore from cache
      final restored = await LocationService.instance.getLastKnownOrCachedLocation();
      expect(restored?.latitude, 37.7749);
      expect(restored?.longitude, -122.4194);
    });

    test('returns null when location service is disabled', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocatorChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'isLocationServiceEnabled') {
          return false;
        }
        return null;
      });

      final permissionGranted = await LocationService.instance.requestPermission();
      expect(permissionGranted, isFalse);

      final loc = await LocationService.instance.getCurrentLocation();
      expect(loc, isNull);
    });

    test('fetches current location when services and permissions are granted', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocatorChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'isLocationServiceEnabled') {
          return true;
        }
        if (methodCall.method == 'checkPermission') {
          return 3; // LocationPermission.always
        }
        if (methodCall.method == 'getCurrentPosition') {
          return {
            'latitude': 40.7128,
            'longitude': -74.0060,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'altitude': 0.0,
            'accuracy': 3.2,
            'heading': 0.0,
            'speed': 0.0,
            'speed_accuracy': 0.0,
          };
        }
        return null;
      });

      final loc = await LocationService.instance.getCurrentLocation();
      expect(loc, isNotNull);
      expect(loc!.latitude, 40.7128);
      expect(loc.longitude, -74.0060);
      expect(loc.accuracy, 3.2);
      expect(LocationService.instance.cachedLocation?.latitude, 40.7128);
    });

    test('openLocationSettings delegates safely without throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocatorChannel, (MethodCall methodCall) async {
        if (methodCall.method == 'openLocationSettings') {
          return true;
        }
        return null;
      });

      final opened = await LocationService.instance.openLocationSettings();
      expect(opened, isTrue);
    });
  });
}
