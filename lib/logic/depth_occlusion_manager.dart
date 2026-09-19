import 'dart:async';
import 'package:flutter/services.dart';
import '../models/map_models.dart';
import 'wall_collision_validator.dart';

/// Represents the physical obstruction / occlusion status of a candidate waypoint.
class WaypointOcclusionState {
  final bool isOccluded;
  final bool shouldHide;
  final double? measuredObstacleDistance;
  final double? clampedDistance;
  final String reason;

  const WaypointOcclusionState({
    required this.isOccluded,
    this.shouldHide = false,
    this.measuredObstacleDistance,
    this.clampedDistance,
    this.reason = '',
  });

  static const clear = WaypointOcclusionState(
    isOccluded: false,
    shouldHide: false,
  );
}

/// Candidate waypoint projection for native ARCore depth query.
class WaypointDepthQuery {
  final int id;
  final double screenX; // 0.0 to 1.0 (normalized)
  final double screenY; // 0.0 to 1.0 (normalized)
  final double expectedDistance; // camera-space depth in meters
  final double east;
  final double north;

  const WaypointDepthQuery({
    required this.id,
    required this.screenX,
    required this.screenY,
    required this.expectedDistance,
    required this.east,
    required this.north,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'screenX': screenX,
    'screenY': screenY,
    'expectedDistance': expectedDistance,
  };
}

/// Orchestrates ARCore Depth API occlusion tests and combines them with
/// mapped wall boundaries to clamp or hide occluded waypoints and path nodes.
class DepthOcclusionManager {
  static const MethodChannel _channel = MethodChannel('mapx/arcore');

  final Map<int, WaypointOcclusionState> _occlusionStates = {};
  Map<int, WaypointOcclusionState> get occlusionStates => Map.unmodifiable(_occlusionStates);

  DateTime _lastQueryTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isQueryInProgress = false;

  /// Minimum interval between depth query platform invocations (ms).
  static const int queryThrottleMs = 250;

  /// Safety clearance margin between obstacle and clamped waypoint (meters).
  static const double obstacleClearanceMeters = 0.30;

  /// Evaluates geometric occlusion against 2D mapped walls and ARCore vertical plane walls.
  WaypointOcclusionState evaluateWallGeometryOcclusion({
    required double userEast,
    required double userNorth,
    required double targetEast,
    required double targetNorth,
    required List<WallSegment> walls,
  }) {
    if (walls.isEmpty) return WaypointOcclusionState.clear;

    final blocked = WallCollisionValidator.isLineOfSightBlocked(
      startEast: userEast,
      startNorth: userNorth,
      targetEast: targetEast,
      targetNorth: targetNorth,
      walls: walls,
    );

    if (blocked) {
      return const WaypointOcclusionState(
        isOccluded: true,
        shouldHide: true,
        reason: 'Blocked by wall segment',
      );
    }

    return WaypointOcclusionState.clear;
  }

  /// Sends projected queries to ARCore Depth API via the platform channel.
  Future<void> queryDepthOcclusions(List<WaypointDepthQuery> queries) async {
    if (queries.isEmpty || _isQueryInProgress) return;

    final now = DateTime.now();
    if (now.difference(_lastQueryTime).inMilliseconds < queryThrottleMs) {
      return;
    }

    _isQueryInProgress = true;
    _lastQueryTime = now;

    try {
      final queryList = queries.map((q) => q.toMap()).toList();
      final result = await _channel.invokeMethod('checkDepthOcclusions', {
        'queries': queryList,
      });

      if (result is List) {
        for (final item in result) {
          if (item is Map) {
            final id = (item['id'] as num).toInt();
            final isBlocked = item['isBlocked'] as bool? ?? false;
            final measuredDist = (item['distance'] as num?)?.toDouble() ?? -1.0;
            final expectedDist = (item['expectedDistance'] as num?)?.toDouble() ?? 5.0;

            if (isBlocked && measuredDist > 0) {
              final clamped = (measuredDist - obstacleClearanceMeters).clamp(0.4, expectedDist);
              final tooCloseToDisplay = clamped < 0.6;

              _occlusionStates[id] = WaypointOcclusionState(
                isOccluded: true,
                shouldHide: tooCloseToDisplay,
                measuredObstacleDistance: measuredDist,
                clampedDistance: clamped,
                reason: 'Physical obstacle detected at ${measuredDist.toStringAsFixed(1)}m',
              );
            } else {
              _occlusionStates[id] = WaypointOcclusionState.clear;
            }
          }
        }
      }
    } on PlatformException {
      // Platform method not implemented or depth unavailable: fallback to clear
    } catch (_) {
      // Ignore transient errors
    } finally {
      _isQueryInProgress = false;
    }
  }

  /// Retrieves the occlusion state for a given waypoint ID.
  WaypointOcclusionState getState(int id) {
    return _occlusionStates[id] ?? WaypointOcclusionState.clear;
  }

  void clear() {
    _occlusionStates.clear();
  }
}
