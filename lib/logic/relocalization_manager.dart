import 'dart:math';
import '../models/map_models.dart';
import 'spatial_sensor_fusion.dart';
import 'wall_collision_validator.dart';

class RelocalizationEvent {
  final String reason;
  final double correctedProgress;
  final double previousProgress;
  final DateTime timestamp;

  RelocalizationEvent({
    required this.reason,
    required this.correctedProgress,
    required this.previousProgress,
  }) : timestamp = DateTime.now();
}

/// Detects trajectory-map inconsistencies and safely relocalizes the user
/// to known corridor geometry and junction landmarks.
class RelocalizationManager {
  final List<PathNode> route;
  final List<WallSegment> walls;
  final SpatialSensorFusion fusionEngine;

  final void Function(RelocalizationEvent event)? onRelocalized;

  RelocalizationManager({
    required this.route,
    required this.walls,
    required this.fusionEngine,
    this.onRelocalized,
  });

  /// Evaluates current user position and triggers relocalization if an inconsistency is detected.
  void checkAndRelocalize(FusedPosition currentPos) {
    if (!currentPos.isDrifting && currentPos.confidence != TrackingConfidence.low) {
      return;
    }

    // Inhibit relocalization when starting navigation (progress < 2.0m) to preserve starting point anchoring!
    if (currentPos.progressMeters < 2.0) {
      return;
    }

    // 1. Check if user is near a turn / junction node in the route
    final currentProgress = currentPos.progressMeters;
    final nearestJunction = _findNearestJunctionNode(currentProgress);

    if (nearestJunction != null) {
      final delta = (nearestJunction.distanceAlongRoute - currentProgress).abs();
      // If within 2.5 meters of a planned turn and turning/drifting, snap to junction!
      if (delta <= 2.5) {
        fusionEngine.snapToProgress(nearestJunction.distanceAlongRoute);
        onRelocalized?.call(RelocalizationEvent(
          reason: 'Snapped to junction (${nearestJunction.node.index})',
          correctedProgress: nearestJunction.distanceAlongRoute,
          previousProgress: currentProgress,
        ));
        return;
      }
    }

    // 2. Lateral Corridor Projection: ensure position is within corridor boundaries
    final isOutOfBounds = !WallCollisionValidator.isInsideWalkableCorridor(
      pointEast: currentPos.east,
      pointNorth: currentPos.north,
      route: route,
    );

    if (isOutOfBounds || currentPos.isDrifting) {
      // Find closest node on route WITHIN LOCAL NEIGHBORHOOD ONLY (e.g. +/- 3.5 meters)
      // This strictly prevents teleporting to distant segments or halfway across the route!
      var closestIdx = -1;
      var minD = double.infinity;
      double accumDist = 0.0;

      for (var i = 0; i < route.length; i++) {
        if (i > 0) {
          final p = route[i - 1];
          final c = route[i];
          accumDist += sqrt(pow(c.east - p.east, 2) + pow(c.north - p.north, 2));
        }
        // Check if node is within local progress window (+/- 3.5m)
        if ((accumDist - currentProgress).abs() <= 3.5) {
          final d = pow(route[i].east - currentPos.east, 2) +
              pow(route[i].north - currentPos.north, 2);
          if (d < minD) {
            minD = d.toDouble();
            closestIdx = i;
          }
        }
      }

      if (closestIdx >= 0) {
        // Compute distance to closest node along route
        double distAlongRoute = 0.0;
        for (var i = 1; i <= closestIdx; i++) {
          final p = route[i - 1];
          final c = route[i];
          distAlongRoute += sqrt(pow(c.east - p.east, 2) + pow(c.north - p.north, 2));
        }

        fusionEngine.snapToProgress(distAlongRoute);
        onRelocalized?.call(RelocalizationEvent(
          reason: currentPos.driftReason.isNotEmpty
              ? currentPos.driftReason
              : 'Boundary correction to centerline',
          correctedProgress: distAlongRoute,
          previousProgress: currentProgress,
        ));
      }
    }
  }

  ({PathNode node, double distanceAlongRoute})? _findNearestJunctionNode(double currentProgress) {
    if (route.length < 3) return null;

    double accumulated = 0.0;
    for (var i = 1; i < route.length - 1; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final next = route[i + 1];

      accumulated += sqrt(pow(cur.east - prev.east, 2) + pow(cur.north - prev.north, 2));

      // Significant heading change indicates a junction / corner
      var headingDiff = (next.heading - cur.heading).abs() % 360;
      if (headingDiff > 180) headingDiff = 360 - headingDiff;

      if (headingDiff >= 35.0) {
        // This is a junction/turn node
        if ((accumulated - currentProgress).abs() <= 3.0) {
          return (node: cur, distanceAlongRoute: accumulated);
        }
      }
    }
    return null;
  }
}
