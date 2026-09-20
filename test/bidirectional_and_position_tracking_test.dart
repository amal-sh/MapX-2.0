import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/relocalization_manager.dart';
import 'package:mapx/logic/route_instructions.dart';
import 'package:mapx/logic/spatial_sensor_fusion.dart';
import 'package:mapx/models/map_models.dart';

void main() {
  group('Bidirectional Route Construction & Geometric Tangent Headings', () {
    // A route going from (0,0) to (0, 10) [heading 0 / North],
    // then to (10, 10) [heading 90 / East].
    final originalNodes = [
      PathNode(0, 0.0, 0.0, 0.0),
      PathNode(1, 0.0, 0.0, 5.0),
      PathNode(2, 0.0, 0.0, 10.0),
      PathNode(3, 90.0, 5.0, 10.0),
      PathNode(4, 90.0, 10.0, 10.0),
    ];

    List<PathNode> buildDirectedRoute(List<PathNode> rawList) {
      final List<PathNode> directedNodes = [];
      for (int i = 0; i < rawList.length; i++) {
        final current = rawList[i];
        double headingDeg;
        if (i < rawList.length - 1) {
          final next = rawList[i + 1];
          final de = next.east - current.east;
          final dn = next.north - current.north;
          if (sqrt(de * de + dn * dn) > 0.001) {
            headingDeg = (atan2(de, dn) * 180.0 / pi + 360.0) % 360.0;
          } else if (directedNodes.isNotEmpty) {
            headingDeg = directedNodes.last.heading;
          } else {
            headingDeg = current.heading;
          }
        } else if (directedNodes.isNotEmpty) {
          headingDeg = directedNodes.last.heading;
        } else {
          headingDeg = current.heading;
        }

        directedNodes.add(PathNode(
          i,
          headingDeg,
          current.east,
          current.north,
          floor: current.floor,
          elevation: current.elevation,
        ));
      }
      return directedNodes;
    }

    test('Forward route has correct forward headings', () {
      final forwardRoute = buildDirectedRoute(originalNodes);
      expect(forwardRoute.length, equals(5));
      expect(forwardRoute.first.heading, closeTo(0.0, 0.01));
      expect(forwardRoute[1].heading, closeTo(0.0, 0.01));
      expect(forwardRoute[2].heading, closeTo(90.0, 0.01));
      expect(forwardRoute[3].heading, closeTo(90.0, 0.01));
      expect(forwardRoute[4].heading, closeTo(90.0, 0.01));
    });

    test('Reverse route (Destination -> Start) has reversed travel headings', () {
      final reversedRaw = originalNodes.reversed.toList();
      final reverseRoute = buildDirectedRoute(reversedRaw);

      expect(reverseRoute.length, equals(5));
      // First node is at (10, 10), heading toward (5, 10) -> West (270°)
      expect(reverseRoute[0].heading, closeTo(270.0, 0.01));
      expect(reverseRoute[1].heading, closeTo(270.0, 0.01));
      // At (0, 10), heading toward (0, 5) -> South (180°)
      expect(reverseRoute[2].heading, closeTo(180.0, 0.01));
      expect(reverseRoute[3].heading, closeTo(180.0, 0.01));
      expect(reverseRoute[4].heading, closeTo(180.0, 0.01));
    });

    test('Turn instructions invert correctly when navigating in reverse', () {
      final forwardRoute = buildDirectedRoute(originalNodes);
      final forwardTurns = computeTurnInstructions(forwardRoute);
      expect(forwardTurns.length, equals(1));
      expect(forwardTurns.first.label, contains('right')); // 0° -> 90° is a right turn

      final reverseRoute = buildDirectedRoute(originalNodes.reversed.toList());
      final reverseTurns = computeTurnInstructions(reverseRoute);
      expect(reverseTurns.length, equals(1));
      expect(reverseTurns.first.label, contains('left')); // 270° -> 180° is a left turn
    });
  });

  group('Reverse Navigation Progress & Walking Continuity', () {
    test('Walking forward along reversed route advances progress correctly', () {
      // Reversed route from (0, 10) to (0, 0), walking South (heading ~180°)
      final route = [
        PathNode(0, 180.0, 0.0, 10.0),
        PathNode(1, 180.0, 0.0, 5.0),
        PathNode(2, 180.0, 0.0, 0.0),
      ];

      final fusion = SpatialSensorFusion(route: route);
      expect(fusion.currentProgress, equals(0.0));

      int nano = 1000000000;
      // Initialize tracking at starting point
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 180.0,
        'renderHeading': 180.0,
        'tilt': 90.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      expect(fusion.currentProgress, equals(0.0));

      // User walks South in a straight line with VIO displacement
      for (var i = 1; i <= 6; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -0.5 * i,
          'heading': 180.0,
          'renderHeading': 180.0,
          'tilt': 90.0,
          'motion': 0.8,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress MUST have advanced along the route (~3.0m)
      expect(fusion.currentProgress, closeTo(3.0, 0.3));
    });

    test('Straight line walking without turning advances continuously without 0.08 damping', () {
      // Route straight North from 0 to 15m
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 15.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
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

      // User walks smoothly holding phone steady (motion = 0.20, below step threshold)
      for (var i = 1; i <= 10; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -0.4 * i, // moves 0.4m per step
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.20, // smooth walking
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Total expected displacement is 4.0m.
      // Previously, with damping=0.08, this would only be ~0.32m!
      // Now it must be close to 4.0m!
      expect(fusion.currentProgress, closeTo(4.0, 0.3));
    });

    test('Stopping holds position steady; resuming walking continues from last position', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 15.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
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

      // Walk to 3.0m
      for (var i = 1; i <= 6; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -0.5 * i,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.8,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }
      final progressAtStop = fusion.currentProgress;
      expect(progressAtStop, closeTo(3.0, 0.2));

      // Stop walking for several frames (stationary jitter only)
      for (var i = 1; i <= 5; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.002, // minor noise < 0.015m
          'y': 0.0,
          'z': -3.003,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.05,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress must remain unchanged
      expect(fusion.currentProgress, closeTo(progressAtStop, 0.05));

      // Resume walking: walk another 2.0m
      for (var i = 1; i <= 4; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -3.0 - (0.5 * i),
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.8,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress resumes smoothly to ~5.0m
      expect(fusion.currentProgress, closeTo(5.0, 0.3));
    });
  });

  group('Starting Point Initialization & Relocalization Bounds', () {
    test('Relocalization does not snap when user is near route start (progress < 2.0m)', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
        PathNode(2, 90.0, 10.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);
      bool relocalized = false;
      final manager = RelocalizationManager(
        route: route,
        walls: [],
        fusionEngine: fusion,
        onRelocalized: (_) => relocalized = true,
      );

      // Fused position at start point with drift flag active
      const posAtStart = FusedPosition(
        east: 0.0,
        north: 0.5,
        headingDegrees: 0.0,
        tiltDegrees: 90.0,
        progressMeters: 0.5,
        totalRouteMeters: 20.0,
        isDrifting: true, // simulated drift trigger
      );

      manager.checkAndRelocalize(posAtStart);
      expect(relocalized, isFalse);
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Relocalization bounds search to local neighborhood (+/- 3.5m) preventing distant snapping', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
        PathNode(2, 0.0, 0.0, 10.0),
        // Path bends back near (0, 4) at node 6 (distance = 25m along route)
        PathNode(3, 90.0, 5.0, 10.0),
        PathNode(4, 180.0, 5.0, 4.0),
        PathNode(5, 270.0, 0.0, 4.0),
      ];

      final fusion = SpatialSensorFusion(route: route, startProgress: 4.5);
      bool relocalized = false;
      final manager = RelocalizationManager(
        route: route,
        walls: [],
        fusionEngine: fusion,
        onRelocalized: (_) => relocalized = true,
      );

      // User at progress 4.5m (near node 1), but spatially close to node 5 as well
      const pos = FusedPosition(
        east: 0.0,
        north: 4.5,
        headingDegrees: 0.0,
        tiltDegrees: 90.0,
        progressMeters: 4.5,
        totalRouteMeters: 25.0,
        isDrifting: true,
      );

      manager.checkAndRelocalize(pos);

      // If relocalized, it must stay around 4.5 - 5.0m, NEVER snapping to node 5 (~25m along route)!
      expect(relocalized, isTrue);
      expect(fusion.currentProgress, lessThan(6.0));
    });
  });
}
