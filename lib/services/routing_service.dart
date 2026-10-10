import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/geo_math.dart';
import '../models/outdoor_models.dart';

/// A walking route between two GPS points.
class WalkingRoute {
  final double distanceMeters;
  final double durationSeconds;
  final List<GeoPoint> points;
  final String source;

  const WalkingRoute(this.distanceMeters, this.durationSeconds, this.points, this.source);

  /// A straight line, for when no footpath route can be found.
  factory WalkingRoute.straight(GeoPoint from, GeoPoint to) {
    final d = haversineMeters(from, to);
    // Typical walking pace, 1.3 m/s.
    return WalkingRoute(d, d / 1.3, [from, to], 'straight');
  }
}

class RoutingException implements Exception {
  final String message;
  const RoutingException(this.message);
  @override
  String toString() => message;
}

/// Finds walking routes along footpaths using OSRM's foot profile on the
/// FOSSGIS server (routing.openstreetmap.de), which uses OpenStreetMap data
/// and needs no API key. It is a free, fair-use service: the app calls it
/// only when an admin links two buildings, and stores the result.
class RoutingService {
  static const _base = 'https://routing.openstreetmap.de/routed-foot/route/v1/foot';

  final http.Client _client;
  RoutingService([http.Client? client]) : _client = client ?? http.Client();

  Future<WalkingRoute> walkingRoute(GeoPoint from, GeoPoint to) async {
    final uri = Uri.parse('$_base/${from.$2},${from.$1};${to.$2},${to.$1}?overview=full&geometries=geojson');
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'User-Agent': 'MapX2 indoor navigation (student project)'})
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw RoutingException('Could not reach the routing service. Check the internet connection.');
    }
    if (response.statusCode != 200) {
      throw RoutingException('Routing service error (${response.statusCode}).');
    }
    return parseOsrm(jsonDecode(response.body) as Map<String, dynamic>, from, to);
  }

  /// Reads an OSRM route response. The route is padded with the exact
  /// entrance points, since OSRM snaps its ends onto the nearest footpath.
  static WalkingRoute parseOsrm(Map<String, dynamic> json, GeoPoint from, GeoPoint to) {
    if (json['code'] != 'Ok' || (json['routes'] as List?)?.isNotEmpty != true) {
      throw RoutingException('No walking route found between these entrances (${json['code'] ?? 'unknown'}).');
    }
    final route = (json['routes'] as List).first as Map<String, dynamic>;
    final coords = (route['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    final points = <GeoPoint>[
      from,
      // GeoJSON order is [longitude, latitude].
      for (final c in coords) ((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      to,
    ];
    final distance = polylineMeters(points);
    final duration = (route['duration'] as num?)?.toDouble() ?? distance / 1.3;
    return WalkingRoute(distance, duration, points, 'osrm');
  }
}
