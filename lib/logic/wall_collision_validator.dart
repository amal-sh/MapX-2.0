import 'dart:math';
import '../models/map_models.dart';

/// Validates waypoints, paths, and user positions against mapped wall geometry
/// and corridor boundaries to prevent navigation from passing through physical barriers.
class WallCollisionValidator {
  static const double defaultCorridorHalfWidth = 1.35; // meters
  static const double minWallClearance = 0.20; // 20cm clearance

  /// Tests whether line segment AB intersects line segment CD in 2D space.
  static bool segmentsIntersect({
    required double ax,
    required double ay,
    required double bx,
    required double by,
    required double cx,
    required double cy,
    required double dx,
    required double dy,
  }) {
    double ccw(double px, double py, double qx, double qy, double rx, double ry) {
      return (ry - py) * (qx - px) - (qy - py) * (rx - px);
    }

    final ccw1 = ccw(ax, ay, cx, cy, dx, dy);
    final ccw2 = ccw(bx, by, cx, cy, dx, dy);
    final ccw3 = ccw(ax, ay, bx, by, cx, cy);
    final ccw4 = ccw(ax, ay, bx, by, dx, dy);

    if (((ccw1 > 0 && ccw2 < 0) || (ccw1 < 0 && ccw2 > 0)) &&
        ((ccw3 > 0 && ccw4 < 0) || (ccw3 < 0 && ccw4 > 0))) {
      return true;
    }

    // Check collinear overlapping segments
    bool onSegment(double px, double py, double qx, double qy, double rx, double ry) {
      return qx <= max(px, rx) &&
          qx >= min(px, rx) &&
          qy <= max(py, ry) &&
          qy >= min(py, ry);
    }

    if (ccw1.abs() < 1e-7 && onSegment(cx, cy, ax, ay, dx, dy)) return true;
    if (ccw2.abs() < 1e-7 && onSegment(cx, cy, bx, by, dx, dy)) return true;
    if (ccw3.abs() < 1e-7 && onSegment(ax, ay, cx, cy, bx, by)) return true;
    if (ccw4.abs() < 1e-7 && onSegment(ax, ay, dx, dy, bx, by)) return true;

    return false;
  }

  /// Checks if line of sight from [startEast, startNorth] to [targetEast, targetNorth]
  /// is obstructed by any known [WallSegment].
  static bool isLineOfSightBlocked({
    required double startEast,
    required double startNorth,
    required double targetEast,
    required double targetNorth,
    required List<WallSegment> walls,
  }) {
    for (final wall in walls) {
      if (segmentsIntersect(
        ax: startEast,
        ay: startNorth,
        bx: targetEast,
        by: targetNorth,
        cx: wall.startEast,
        cy: wall.startNorth,
        dx: wall.endEast,
        dy: wall.endNorth,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Calculates the shortest perpendicular distance from point (px, py) to segment (ax, ay)-(bx, by).
  static double distanceToSegment({
    required double px,
    required double py,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    final dx = bx - ax;
    final dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared < 1e-6) {
      return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    }

    final t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / lengthSquared));
    final projX = ax + t * dx;
    final projY = ay + t * dy;
    return sqrt((px - projX) * (px - projX) + (py - projY) * (py - projY));
  }

  /// Determines whether [pointEast, pointNorth] is within the walkable corridor bounds.
  static bool isInsideWalkableCorridor({
    required double pointEast,
    required double pointNorth,
    required List<PathNode> route,
    double corridorHalfWidth = defaultCorridorHalfWidth,
  }) {
    if (route.isEmpty) return false;
    double minDistance = double.infinity;

    for (var i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final dist = distanceToSegment(
        px: pointEast,
        py: pointNorth,
        ax: a.east,
        ay: a.north,
        bx: b.east,
        by: b.north,
      );
      if (dist < minDistance) {
        minDistance = dist;
      }
    }

    return minDistance <= corridorHalfWidth;
  }

  /// Validates whether candidate waypoint position is geometrically valid to display.
  static ({bool isValid, bool isWallBlocked, bool isOutOfBounds}) validateWaypoint({
    required double userEast,
    required double userNorth,
    required double wpEast,
    required double wpNorth,
    required List<WallSegment> walls,
    required List<PathNode> route,
    double corridorHalfWidth = defaultCorridorHalfWidth,
  }) {
    final isBlocked = isLineOfSightBlocked(
      startEast: userEast,
      startNorth: userNorth,
      targetEast: wpEast,
      targetNorth: wpNorth,
      walls: walls,
    );

    final isOutOfBounds = !isInsideWalkableCorridor(
      pointEast: wpEast,
      pointNorth: wpNorth,
      route: route,
      corridorHalfWidth: corridorHalfWidth + 0.3,
    );

    return (
      isValid: !isBlocked && !isOutOfBounds,
      isWallBlocked: isBlocked,
      isOutOfBounds: isOutOfBounds,
    );
  }
}
