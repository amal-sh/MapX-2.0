import 'dart:math';

import '../models/campus_models.dart';

const double _earthRadiusMeters = 6371000;

double _rad(double deg) => deg * pi / 180;

/// Great-circle distance in metres between two GPS points.
double haversineMeters(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.$1 - a.$1);
  final dLng = _rad(b.$2 - a.$2);
  final h = pow(sin(dLat / 2), 2) + cos(_rad(a.$1)) * cos(_rad(b.$1)) * pow(sin(dLng / 2), 2);
  return 2 * _earthRadiusMeters * asin(min(1.0, sqrt(h)));
}

/// Total length in metres of a route.
double polylineMeters(List<GeoPoint> points) {
  var d = 0.0;
  for (var i = 1; i < points.length; i++) {
    d += haversineMeters(points[i - 1], points[i]);
  }
  return d;
}

/// Compass bearing in degrees (0 = north, clockwise) from [a] towards [b].
double bearingDegrees(GeoPoint a, GeoPoint b) {
  final y = sin(_rad(b.$2 - a.$2)) * cos(_rad(b.$1));
  final x = cos(_rad(a.$1)) * sin(_rad(b.$1)) - sin(_rad(a.$1)) * cos(_rad(b.$1)) * cos(_rad(b.$2 - a.$2));
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

/// Where [here] is relative to a walking [route]: the closest point on it,
/// how far off the route that is, and how much of the route is left from
/// there to its end.
///
/// Uses a flat local projection, which is accurate over the few hundred
/// metres between buildings.
({GeoPoint closest, double offRouteMeters, double remainingMeters, int segment}) progressAlongRoute(
    List<GeoPoint> route, GeoPoint here) {
  if (route.length < 2) {
    final only = route.isEmpty ? here : route.first;
    return (closest: only, offRouteMeters: haversineMeters(here, only), remainingMeters: 0, segment: 0);
  }
  // Metres per degree around [here].
  final mLat = _earthRadiusMeters * pi / 180;
  final mLng = mLat * cos(_rad(here.$1));
  (double, double) toXY(GeoPoint p) => ((p.$2 - here.$2) * mLng, (p.$1 - here.$1) * mLat);

  var best = double.infinity;
  var bestSeg = 0;
  var bestT = 0.0;
  for (var i = 0; i < route.length - 1; i++) {
    final (ax, ay) = toXY(route[i]);
    final (bx, by) = toXY(route[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
    final px = ax + dx * t, py = ay + dy * t;
    final d = sqrt(px * px + py * py);
    if (d < best) {
      best = d;
      bestSeg = i;
      bestT = t;
    }
  }
  final a = route[bestSeg], b = route[bestSeg + 1];
  final closest = (a.$1 + (b.$1 - a.$1) * bestT, a.$2 + (b.$2 - a.$2) * bestT);
  var remaining = haversineMeters(closest, b);
  for (var i = bestSeg + 1; i < route.length - 1; i++) {
    remaining += haversineMeters(route[i], route[i + 1]);
  }
  return (closest: closest, offRouteMeters: best, remainingMeters: remaining, segment: bestSeg);
}
