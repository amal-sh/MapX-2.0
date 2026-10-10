import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/services/geocoding_service.dart';

void main() {
  group('GeocodingService.parsePlace', () {
    test('prefers building + road', () {
      final place = GeocodingService.parsePlace({
        'display_name': 'Block A, Jalan Ampang, Kuala Lumpur',
        'address': {'building': 'Block A', 'road': 'Jalan Ampang'},
      });
      expect(place?.short, equals('Block A, Jalan Ampang'));
    });

    test('falls back to road + suburb', () {
      final place = GeocodingService.parsePlace({
        'display_name': 'Jalan Ampang, KLCC, Kuala Lumpur',
        'address': {'road': 'Jalan Ampang', 'suburb': 'KLCC'},
      });
      expect(place?.short, equals('Jalan Ampang, KLCC'));
    });

    test('falls back to first two display_name segments', () {
      final place = GeocodingService.parsePlace({
        'display_name': 'Foo Hall, Bar Street, Baz City, Country',
        'address': <String, dynamic>{},
      });
      expect(place?.short, equals('Foo Hall, Bar Street'));
    });

    test('returns null on error payload or empty response', () {
      expect(GeocodingService.parsePlace({'error': 'Unable to geocode'}),
          isNull);
      expect(GeocodingService.parsePlace(<String, dynamic>{}), isNull);
    });
  });

  group('GeocodingService.isStale', () {
    test('fresh nearby cache is not stale', () {
      expect(
        GeocodingService.isStale(
          cachedLat: 3.15,
          cachedLon: 101.7,
          currentLat: 3.15001,
          currentLon: 101.70001,
          fetchedAt: DateTime.now(),
        ),
        isFalse,
      );
    });

    test('old or moved cache is stale', () {
      expect(
        GeocodingService.isStale(
          cachedLat: 3.15,
          cachedLon: 101.7,
          currentLat: 3.15,
          currentLon: 101.7,
          fetchedAt: DateTime.now().subtract(const Duration(days: 31)),
        ),
        isTrue,
      );
      expect(
        GeocodingService.isStale(
          cachedLat: 3.15,
          cachedLon: 101.7,
          currentLat: 3.16,
          currentLon: 101.71,
          fetchedAt: DateTime.now(),
        ),
        isTrue,
      );
    });
  });
}
