import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/coordinate_transform.dart';
import 'package:mapx/logic/floor_transition_manager.dart';
import 'package:mapx/logic/spatial_sensor_fusion.dart';
import 'package:mapx/logic/wall_collision_validator.dart';
import 'package:mapx/models/map_models.dart';

void main() {
  group('WallCollisionValidator Tests', () {
    test('segmentsIntersect correctly detects crossing line segments', () {
      // Horizontal segment (0, 5) to (10, 5)
      // Vertical segment (5, 0) to (5, 10)
      final intersects = WallCollisionValidator.segmentsIntersect(
        ax: 0, ay: 5, bx: 10, by: 5,
        cx: 5, cy: 0, dx: 5, dy: 10,
      );
      expect(intersects, isTrue);

      // Parallel non-intersecting segments
      final parallel = WallCollisionValidator.segmentsIntersect(
        ax: 0, ay: 0, bx: 10, by: 0,
        cx: 0, cy: 5, dx: 10, dy: 5,
      );
      expect(parallel, isFalse);

      // Non-intersecting disjoint segments
      final disjoint = WallCollisionValidator.segmentsIntersect(
        ax: 0, ay: 0, bx: 2, by: 2,
        cx: 3, cy: 3, dx: 5, dy: 5,
      );
      expect(disjoint, isFalse);
    });

    test('isLineOfSightBlocked detects when wall intersects path to waypoint', () {
      final walls = [
        const WallSegment(startEast: 4.0, startNorth: 0.0, endEast: 4.0, endNorth: 10.0),
      ];

      // Path from (0, 5) to (8, 5) crosses wall at (4, 5)
      final blocked = WallCollisionValidator.isLineOfSightBlocked(
        startEast: 0.0,
        startNorth: 5.0,
        targetEast: 8.0,
        targetNorth: 5.0,
        walls: walls,
      );
      expect(blocked, isTrue);

      // Path from (0, 5) to (2, 5) is before the wall
      final unblocked = WallCollisionValidator.isLineOfSightBlocked(
        startEast: 0.0,
        startNorth: 5.0,
        targetEast: 2.0,
        targetNorth: 5.0,
        walls: walls,
      );
      expect(unblocked, isFalse);
    });

    test('isInsideWalkableCorridor validates distance against corridor centerline', () {
      final route = [
        PathNode(0, 0, 0.0, 0.0),
        PathNode(1, 0, 0.0, 10.0),
      ];

      // 0.5m lateral offset from straight route: inside corridor
      final inside = WallCollisionValidator.isInsideWalkableCorridor(
        pointEast: 0.5,
        pointNorth: 5.0,
        route: route,
        corridorHalfWidth: 1.2,
      );
      expect(inside, isTrue);

      // 2.5m lateral offset from straight route: outside corridor
      final outside = WallCollisionValidator.isInsideWalkableCorridor(
        pointEast: 2.5,
        pointNorth: 5.0,
        route: route,
        corridorHalfWidth: 1.2,
      );
      expect(outside, isFalse);
    });

    test('validateWaypoint prevents waypoint inside or through walls', () {
      final route = [
        PathNode(0, 0, 0.0, 0.0),
        PathNode(1, 0, 0.0, 10.0),
      ];
      final walls = [
        const WallSegment(startEast: -1.0, startNorth: 5.0, endEast: 1.0, endNorth: 5.0),
      ];

      final result = WallCollisionValidator.validateWaypoint(
        userEast: 0.0,
        userNorth: 2.0,
        wpEast: 0.0,
        wpNorth: 8.0,
        walls: walls,
        route: route,
      );

      expect(result.isValid, isFalse);
      expect(result.isWallBlocked, isTrue);
    });
  });

  group('CoordinateTransform Tests', () {
    test('Transforms map coordinates into ARCore world coordinates', () {
      final transform = CoordinateTransform();
      transform.calibrate(
        startEast: 0.0,
        startNorth: 0.0,
        startHeadingDeg: 0.0,
        camX: 0.0,
        camY: 1.4,
        camZ: 0.0,
        camYawDeg: 0.0,
        floorHeight: 1.4,
      );

      expect(transform.isCalibrated, isTrue);

      final worldPoint = transform.mapToWorld(0.0, 5.0, 0.006);
      expect(worldPoint.y, closeTo(0.006, 0.001));
      expect(worldPoint.z, closeTo(5.0, 0.001));

      final mapPoint = transform.worldToMap(worldPoint.x, worldPoint.z);
      expect(mapPoint.east, closeTo(0.0, 0.001));
      expect(mapPoint.north, closeTo(5.0, 0.001));
    });
  });

  group('FloorTransitionManager Tests', () {
    test('Detects stairwell transition proximity and performs manual confirmation handoff', () {
      final transitions = [
        const FloorTransition(
          id: 'stairs_1_to_2',
          type: TransitionType.stairs,
          fromFloor: 1,
          toFloor: 2,
          entryStepIndex: 5,
          exitStepIndex: 6,
          label: 'East Stairs',
        ),
      ];

      final routeNodes = [
        PathNode(0, 0, 0.0, 0.0, floor: 1),
        PathNode(1, 0, 0.0, 2.0, floor: 1),
        PathNode(2, 0, 0.0, 4.0, floor: 1),
        PathNode(3, 0, 0.0, 6.0, floor: 1),
        PathNode(4, 0, 0.0, 8.0, floor: 1),
        PathNode(5, 0, 0.0, 10.0, floor: 1), // Transition node
        PathNode(6, 0, 0.0, 10.0, floor: 2),
      ];

      final manager = FloorTransitionManager(
        currentFloor: 1,
        transitions: transitions,
      );

      // User far from transition (at North = 2.0, stairs at 10.0)
      final farCheck = manager.checkTransitionProximity(
        userEast: 0.0,
        userNorth: 2.0,
        routeNodes: routeNodes,
      );
      expect(farCheck.isNearTransition, isFalse);

      // User near transition (at North = 9.0, stairs at 10.0, dist = 1.0m <= 2.5m)
      final nearCheck = manager.checkTransitionProximity(
        userEast: 0.0,
        userNorth: 9.0,
        routeNodes: routeNodes,
      );
      expect(nearCheck.isNearTransition, isTrue);
      expect(nearCheck.transition?.toFloor, equals(2));

      // User taps button confirming arrival at Floor 2
      manager.confirmArrivalAtTargetFloor(2);
      expect(manager.currentFloor, equals(2));
      expect(manager.state, equals(FloorTransitionState.completed));
    });

    test('Filters waypoints to only show active floor', () {
      final manager = FloorTransitionManager(currentFloor: 1);
      final waypoints = [
        Waypoint(1, 'Room 101', floor: 1),
        Waypoint(2, 'Room 102', floor: 1),
        Waypoint(3, 'Room 201', floor: 2),
      ];

      final floor1Waypoints = manager.filterWaypointsForActiveFloor(waypoints);
      expect(floor1Waypoints.length, equals(2));
      expect(floor1Waypoints.every((w) => w.floor == 1), isTrue);

      manager.currentFloor = 2;
      final floor2Waypoints = manager.filterWaypointsForActiveFloor(waypoints);
      expect(floor2Waypoints.length, equals(1));
      expect(floor2Waypoints.first.label, equals('Room 201'));
    });
  });

  group('Destination Arrival & Drift Safety Tests', () {
    test('Calculates Euclidean spatial proximity correctly rather than blind 1D distance', () {
      final dest = PathNode(10, 0, 10.0, 20.0);
      final userAtDestination = PathNode(10, 0, 10.3, 19.8);
      final userFarAway = PathNode(5, 0, 2.0, 5.0);

      double spatialDistance(PathNode u, PathNode d) =>
          sqrt(pow(d.east - u.east, 2) + pow(d.north - u.north, 2));

      final nearDist = spatialDistance(userAtDestination, dest);
      final farDist = spatialDistance(userFarAway, dest);

      expect(nearDist, lessThan(0.5));
      expect(farDist, greaterThan(15.0));
    });
  });

  group('Tracking Persistence & Outage Recovery Tests', () {
    test('Persists tracking across ARCore tracking outages using PDR dead-reckoning', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 12.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // 1. Initial lock and tracking
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 90.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // 2. Establish active gait cadence, then walk 8 meters forward with active tracking
      for (var s = 0; s < 2; s++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': 0.0,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 2.5,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      for (var i = 1; i <= 8; i++) {
        nano += 500000000; // 0.5s intervals
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -1.0 * i, // Move 1m per interval forward in camera space
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 2.5, // Active walking motion
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // User reached 8m
      expect(fusion.currentProgress, closeTo(8.0, 0.5));

      // 3. At 8 meters, ARCore loses tracking! (e.g. PAUSED)
      // User walks 3 steps while tracking is lost (from 8m to ~10m)
      for (var s = 1; s <= 3; s++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -8.0, // Camera pose frozen
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 3.0, // Step motion detected by accelerometer!
          'floorDetected': false,
          'floorHeight': 1.4,
          'floorConfidence': 0.0,
          'cameraFovY': 60.0,
          'arTrackingState': 'PAUSED', // ARCore is NOT tracking!
        });
      }

      // Progress MUST have advanced beyond 8.0m via PDR dead-reckoning fallback!
      // Previously, this stayed frozen at 8.0m. Now it should be around 9.5m - 10.0m!
      expect(fusion.currentProgress, greaterThan(9.3));

      // 4. ARCore recovers tracking!
      nano += 500000000;
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': -10.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 90.0,
        'motion': 0.5,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING', // Back to tracking!
      });

      // User progress should remain persistent at ~9.5m - 10.0m, meaning remaining distance is ~2.0m to 2.5m, NOT 4.0m!
      final remaining = 12.0 - fusion.currentProgress;
      expect(remaining, lessThan(2.7));
      expect(remaining, greaterThan(1.0));
    });
  });
}
