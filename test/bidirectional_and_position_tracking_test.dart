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

  group('Unified Physical Scale & Variable Route Distance Tracking', () {
    test('Controlled 10m Route: Node A -> Node B (5m) -> Node C (5m) has totalDistance = 10.0m', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
        PathNode(2, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);
      expect(fusion.totalRouteDistance, equals(10.0));
    });

    test('Variable route lengths preserve exact graph metric distance (5m, 10m, 25m)', () {
      final route5m = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
      ];
      final fusion5m = SpatialSensorFusion(route: route5m);
      expect(fusion5m.totalRouteDistance, equals(5.0));

      final route25m = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
        PathNode(2, 90.0, 15.0, 10.0),
      ];
      final fusion25m = SpatialSensorFusion(route: route25m);
      expect(fusion25m.totalRouteDistance, equals(25.0));
    });

    test('30 FPS VIO Walking Simulation: Sub-15mm stance phase frames are NOT discarded', () {
      // 10m route North
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // Initialize tracking at origin
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

      // Simulate 10 seconds of walking at 30 FPS (300 frames, ~33.3ms each) to cover 10.0m.
      // Human walking speed varies sinusoidally between 0.35 m/s (stance) and 1.35 m/s (swing).
      // During stance frames (velocity = 0.35 m/s), deltaDist = 0.0116m < 0.015m!
      // Previously, all these stance frames were completely erased, causing a 30% undercount!
      // With sub-frame accumulation, 100% of distance must be preserved!
      double currentZ = 0.0;
      for (var f = 1; f <= 300; f++) {
        nano += 33333333; // 33.33ms
        // Sinusoidal velocity profile (1.7 Hz step cadence = ~17.6 frames per step)
        final cycle = sin(f * 2 * pi / 17.6);
        final speed = 0.85 + 0.50 * cycle; // oscillates between 0.35 m/s and 1.35 m/s, avg = 0.85 m/s
        final frameDelta = speed * 0.03333333;
        currentZ -= frameDelta;

        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': currentZ,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.35 + 0.25 * cycle.abs(), // walking motion
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      final expectedDistance = currentZ.abs();
      // Total physical simulated distance is ~8.5m.
      // The tracked progress must match expected distance within 0.1m, proving ZERO stance-phase loss!
      expect(fusion.currentProgress, closeTo(expectedDistance, 0.15));
    });

    test('Variable walking speed tracking: Cautious walking (0.6 m/s) retains full distance', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
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

      // At 0.6 m/s, delta per 33ms frame is only 0.020m, frequently dipping below 0.012m.
      // Walk for 5.0m (250 frames).
      double currentZ = 0.0;
      for (var f = 1; f <= 250; f++) {
        nano += 33333333;
        final speed = 0.60 + 0.35 * sin(f * 2 * pi / 20.0); // 0.25 to 0.95 m/s
        final frameDelta = speed * 0.03333333;
        currentZ -= frameDelta;

        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': currentZ,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.30,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      expect(fusion.currentProgress, closeTo(currentZ.abs(), 0.15));
    });

    test('PDR Fallback across variable distances uses calibrated 0.72m adult step length', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 30.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // In PDR fallback mode (arTrackingState != TRACKING)
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 90.0,
        'motion': 0.1,
        'floorDetected': false,
        'arTrackingState': 'SEARCHING',
      });

      // 14 steps taken at 0.65s intervals
      for (var s = 1; s <= 14; s++) {
        nano += 650000000; // 0.65s
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': 0.0,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.8, // step motion peak
          'floorDetected': false,
          'arTrackingState': 'SEARCHING',
        });
      }

      // 14 steps * 0.72m = 10.08m (previously with 0.50m it would only be 7.0m!)
      // First 2 peaks establish gait cadence, so 13 step increments occur
      expect(fusion.currentProgress, closeTo(13 * 0.72, 0.1));
    });

    test('resetSession completely clears tracking baselines and accumulators', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 20.0),
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

      // Advance by 6.0m
      for (var i = 1; i <= 6; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -1.0 * i,
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

      expect(fusion.currentProgress, closeTo(6.0, 0.2));

      // Reset session for a new navigation run
      fusion.resetSession();
      expect(fusion.currentProgress, equals(0.0));
      expect(fusion.coordinateTransform.isCalibrated, isFalse);
    });

    test('Stationary jitter deadband does not accumulate distance while resting', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
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
        'motion': 0.05,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // 60 frames of micro-jitter (< 0.005m, motion = 0.04)
      for (var f = 1; f <= 60; f++) {
        nano += 33333333;
        final noise = 0.003 * sin(f.toDouble());
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': noise,
          'y': 0.0,
          'z': noise,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.04, // resting still
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress must remain strictly 0.0
      expect(fusion.currentProgress, equals(0.0));
    });
  });

  group('In-Place Rotation, Heading Alignment & Intermediate Starting Point Tracking', () {
    test('User standing at starting point rotating 360 degrees accumulates 0.00m distance', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // Initialize tracking at starting point facing North
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

      expect(fusion.currentProgress, equals(0.0));

      // User rotates 360 degrees in place over 60 frames (~2 seconds, 180 deg/s)
      // Phone is held at arm's length (R = 0.35m) swinging in a circular arc
      const radius = 0.35;
      for (var f = 1; f <= 72; f++) {
        nano += 33333333; // ~30fps
        final angleDeg = (f * 5.0) % 360.0;
        final angleRad = angleDeg * pi / 180.0;
        final arcX = radius * sin(angleRad);
        final arcZ = -radius * cos(angleRad);

        // Calculate quaternion for horizontal camera rotation
        final halfAngle = angleRad / 2.0;
        final qy = sin(halfAngle);
        final qw = cos(halfAngle);

        fusion.processPoseEvent({
          'timestamp': nano,
          'x': arcX,
          'y': 0.0,
          'z': arcZ,
          'qx': 0.0,
          'qy': qy,
          'qz': 0.0,
          'qw': qw,
          'heading': angleDeg,
          'renderHeading': angleDeg,
          'tilt': 90.0,
          'motion': 0.25, // Motion from holding and turning phone
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress MUST remain exactly 0.0 - user has NOT physically walked forward!
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Foot shuffling while pivoting in place does not trigger PDR stride injection', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
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

      // User shuffles feet while rotating in place (motion = 0.55, step-like peaks)
      for (var f = 1; f <= 30; f++) {
        nano += 66666666; // 15 Hz shuffle
        final angleDeg = (f * 10.0) % 360.0;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.05 * sin(angleDeg * pi / 180.0),
          'y': 0.0,
          'z': -0.05 * cos(angleDeg * pi / 180.0),
          'heading': angleDeg,
          'renderHeading': angleDeg,
          'tilt': 90.0,
          'motion': 0.55, // Shuffling foot acceleration
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Must NOT have injected 0.72m PDR strides during turning!
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Facing wall (> 45 deg) suppresses progress even with lateral phone movement', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0), // Route is North (0°)
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 90.0, // Facing East (directly into a wall)
        'renderHeading': 90.0,
        'tilt': 90.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // User moves sideways along the wall facing the wall (0.5m)
      for (var i = 1; i <= 5; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.1 * i,
          'y': 0.0,
          'z': 0.0,
          'heading': 90.0,
          'renderHeading': 90.0,
          'tilt': 90.0,
          'motion': 0.4,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Corridor projection factor is 0.0 for angleDiff = 90° (wall)
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Resuming forward walking along route after turning advances cleanly', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // 1. Initial pose: facing West (270°), wrong direction
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 270.0,
        'renderHeading': 270.0,
        'tilt': 90.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // 2. Rotate to face North (0°)
      for (var deg = 270; deg <= 360; deg += 15) {
        nano += 50000000;
        final h = (deg % 360).toDouble();
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': 0.0,
          'heading': h,
          'renderHeading': h,
          'tilt': 90.0,
          'motion': 0.2,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      expect(fusion.currentProgress, equals(0.0));

      // 3. User settles facing North (heading = 0.0)
      nano += 500000000;
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
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

      // 4. Now walk forward North 4 steps (total 2.0m)
      for (var i = 1; i <= 4; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.0,
          'z': -0.5 * i,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.6,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress must advance cleanly to ~2.0m
      expect(fusion.currentProgress, closeTo(2.0, 0.2));
    });

    test('Intermediate waypoint route construction computes correct directional headings', () {
      // 5-node route from (0,0) to (20, 0) East
      final nodes = [
        PathNode(0, 90.0, 0.0, 0.0),
        PathNode(1, 90.0, 5.0, 0.0),
        PathNode(2, 90.0, 10.0, 0.0), // Intermediate Waypoint "Room 102"
        PathNode(3, 90.0, 15.0, 0.0),
        PathNode(4, 90.0, 20.0, 0.0), // Final "Exit"
      ];

      // Sub-route starting from node 2 to node 4
      final rawSublist = nodes.sublist(2, 5);
      final List<PathNode> directedNodes = [];
      for (int i = 0; i < rawSublist.length; i++) {
        final current = rawSublist[i];
        double headingDeg;
        if (i < rawSublist.length - 1) {
          double? foundHeading;
          for (int j = i + 1; j < rawSublist.length; j++) {
            final fNext = rawSublist[j];
            final fde = fNext.east - current.east;
            final fdn = fNext.north - current.north;
            if (sqrt(fde * fde + fdn * fdn) > 0.001) {
              foundHeading = (atan2(fde, fdn) * 180.0 / pi + 360.0) % 360.0;
              break;
            }
          }
          headingDeg = foundHeading ?? (directedNodes.isNotEmpty ? directedNodes.last.heading : current.heading);
        } else if (directedNodes.isNotEmpty) {
          headingDeg = directedNodes.last.heading;
        } else {
          headingDeg = current.heading;
        }
        directedNodes.add(PathNode(i, headingDeg, current.east, current.north));
      }

      expect(directedNodes.length, equals(3));
      // First node (Room 102) has valid East heading 90°
      expect(directedNodes[0].heading, closeTo(90.0, 0.01));
      expect(directedNodes[1].heading, closeTo(90.0, 0.01));
      expect(directedNodes[2].heading, closeTo(90.0, 0.01));
    });
  });

  group('Phone Level & Tilt Handling (In-Place Reorientation & Height Shift)', () {
    test('Tilting phone upright (e.g. 170 deg to 180 deg) while stationary accumulates 0.00m distance', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // 1. Initial pose: held at 170 deg tilt, stationary
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 170.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // 2. User moves phone from 170 deg to 180 deg upright over 10 frames (~300ms)
      // Moving phone generates hand accelerometer motion (0.45) and slight arm translation (2-3cm)
      for (var i = 1; i <= 10; i++) {
        nano += 33333333; // 33.3ms per frame
        final currentTilt = 170.0 + (1.0 * i);
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.002 * i,
          'y': 0.01 * i,
          'z': -0.005 * i, // arm swings slightly forward 5cm while tilting upright
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': currentTilt,
          'motion': 0.45, // accelerometer activity from arm movement
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress must strictly remain 0.00m
      expect(fusion.currentProgress, equals(0.0));

      // Settle at 180 deg for several frames
      for (var i = 1; i <= 5; i++) {
        nano += 100000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.02,
          'y': 0.10,
          'z': -0.05,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 180.0,
          'motion': 0.05,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      expect(fusion.currentProgress, equals(0.0));
    });

    test('Changing vertical phone level (raising/lowering phone in hand) accumulates 0.00m distance', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
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

      // User raises phone from chest to eye level: delta Y = +0.35m over 15 frames
      for (var i = 1; i <= 15; i++) {
        nano += 66666666;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.001 * i,
          'y': 0.023 * i, // raises phone up
          'z': -0.002 * i,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 90.0,
          'motion': 0.40, // hand acceleration
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Height level change must NOT be counted as walking forward!
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Multiple phone tilt adjustments do NOT trigger false 2-3m PDR stride injections', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
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
        'tilt': 160.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // Simulate 3 separate tilt adjustments (160 -> 180, 180 -> 165, 165 -> 180)
      // Previously, each adjustment triggered consecutive gait peaks and injected 0.72m strides (total > 2.1m)
      final tiltTransitions = [
        (160.0, 180.0),
        (180.0, 165.0),
        (165.0, 180.0),
      ];

      for (final (startT, endT) in tiltTransitions) {
        nano += 600000000; // gap between adjustments
        for (var step = 1; step <= 8; step++) {
          nano += 40000000;
          final t = startT + (endT - startT) * (step / 8.0);
          fusion.processPoseEvent({
            'timestamp': nano,
            'x': 0.005 * step,
            'y': 0.01 * step,
            'z': -0.008 * step,
            'heading': 0.0,
            'renderHeading': 0.0,
            'tilt': t,
            'motion': 0.50, // hand movement peak
            'floorDetected': true,
            'floorHeight': 1.4,
            'floorConfidence': 0.8,
            'cameraFovY': 60.0,
            'arTrackingState': 'TRACKING',
          });
        }
      }

      // Zero false distance accumulated despite multiple hand tilt adjustments!
      expect(fusion.currentProgress, equals(0.0));
    });

    test('Forward walking after phone tilt adjustment advances cleanly with accurate metric distance', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];
      final fusion = SpatialSensorFusion(route: route);

      int nano = 1000000000;
      // 1. Initial pose at 170 deg tilt
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 170.0,
        'motion': 0.1,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });

      // 2. Tilt phone to 180 deg
      for (var i = 1; i <= 6; i++) {
        nano += 50000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.05,
          'z': 0.0,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 170.0 + (i * 1.66),
          'motion': 0.45,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }
      expect(fusion.currentProgress, equals(0.0));

      // Settle at 180 deg
      nano += 600000000; // 600ms cooldown
      fusion.processPoseEvent({
        'timestamp': nano,
        'x': 0.0,
        'y': 0.05,
        'z': 0.0,
        'heading': 0.0,
        'renderHeading': 0.0,
        'tilt': 180.0,
        'motion': 0.05,
        'floorDetected': true,
        'floorHeight': 1.4,
        'floorConfidence': 0.8,
        'cameraFovY': 60.0,
        'arTrackingState': 'TRACKING',
      });
      expect(fusion.currentProgress, equals(0.0));

      // 3. User physically walks forward 2.0m (4 steps of 0.5m)
      for (var i = 1; i <= 4; i++) {
        nano += 500000000;
        fusion.processPoseEvent({
          'timestamp': nano,
          'x': 0.0,
          'y': 0.05,
          'z': -0.5 * i,
          'heading': 0.0,
          'renderHeading': 0.0,
          'tilt': 180.0,
          'motion': 0.6,
          'floorDetected': true,
          'floorHeight': 1.4,
          'floorConfidence': 0.8,
          'cameraFovY': 60.0,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress advances cleanly to ~2.0m!
      expect(fusion.currentProgress, closeTo(2.0, 0.2));
    });
  });
}
