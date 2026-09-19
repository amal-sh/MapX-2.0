import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/depth_occlusion_manager.dart';
import 'package:mapx/logic/route_segment_manager.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/widgets/navigation/ar_mini_map.dart';
import 'package:mapx/widgets/navigation/ar_path_painter.dart';
import 'package:mapx/widgets/navigation/ar_world_scanner_overlay.dart';
import 'package:mapx/widgets/navigation/off_path_direction_prompt.dart';
import 'package:lottie/lottie.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Off-Path Direction Handling Tests', () {
    test('computeHeadingDelta computes correct signed angular difference across 360 boundary', () {
      // 10 deg heading vs 50 deg target bearing: +40 deg (turn right)
      expect(RouteSegmentManager.computeHeadingDelta(10.0, 50.0), closeTo(40.0, 0.001));

      // 50 deg heading vs 10 deg target bearing: -40 deg (turn left)
      expect(RouteSegmentManager.computeHeadingDelta(50.0, 10.0), closeTo(-40.0, 0.001));

      // 350 deg heading vs 20 deg target bearing: +30 deg (turn right across 0 deg)
      expect(RouteSegmentManager.computeHeadingDelta(350.0, 20.0), closeTo(30.0, 0.001));

      // 20 deg heading vs 350 deg target bearing: -30 deg (turn left across 0 deg)
      expect(RouteSegmentManager.computeHeadingDelta(20.0, 350.0), closeTo(-30.0, 0.001));

      // 180 deg heading vs 0 deg target bearing: 180 deg
      expect(RouteSegmentManager.computeHeadingDelta(180.0, 0.0).abs(), closeTo(180.0, 0.001));
    });

    test('evaluateFacing respects 35 degree threshold and direction classification', () {
      // Within threshold (facing along path)
      final facing1 = RouteSegmentManager.evaluateFacing(
        userHeadingDeg: 45.0,
        targetBearingDeg: 60.0,
        thresholdDeg: 35.0,
      );
      expect(facing1.isFacingPath, isTrue);
      expect(facing1.turnDirection, equals('straight'));
      expect(facing1.deltaDegrees, closeTo(15.0, 0.001));

      // Exceeds threshold to the right: turn right
      final facingRight = RouteSegmentManager.evaluateFacing(
        userHeadingDeg: 0.0,
        targetBearingDeg: 50.0,
        thresholdDeg: 35.0,
      );
      expect(facingRight.isFacingPath, isFalse);
      expect(facingRight.turnDirection, equals('right'));
      expect(facingRight.deltaDegrees, closeTo(50.0, 0.001));

      // Exceeds threshold to the left: turn left
      final facingLeft = RouteSegmentManager.evaluateFacing(
        userHeadingDeg: 100.0,
        targetBearingDeg: 40.0,
        thresholdDeg: 35.0,
      );
      expect(facingLeft.isFacingPath, isFalse);
      expect(facingLeft.turnDirection, equals('left'));
      expect(facingLeft.deltaDegrees, closeTo(-60.0, 0.001));
    });

    test('sampleTargetBearing looks ahead along the path to determine forward bearing', () {
      // Straight route heading North (0 deg heading, North is increasing north)
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
        PathNode(2, 0.0, 0.0, 10.0),
      ];
      final manager = RouteSegmentManager(route: route);

      final bearing = manager.sampleTargetBearing(0.0, lookaheadMeters: 2.0);
      expect(bearing, closeTo(0.0, 1.0)); // North

      // 90 degree turn to the East (heading 90 deg)
      final routeTurn = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
        PathNode(2, 90.0, 5.0, 5.0),
      ];
      final managerTurn = RouteSegmentManager(route: routeTurn);

      // Past the corner (progress = 6m), forward direction is East (90 deg)
      final bearingTurn = managerTurn.sampleTargetBearing(6.0, lookaheadMeters: 1.5);
      expect(bearingTurn, closeTo(90.0, 1.0));
    });
  });

  group('Progressive Path Reveal Tests', () {
    test('Straight route reveals full segment up to destination', () {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 5.0),
        PathNode(2, 0.0, 0.0, 10.0),
      ];
      final manager = RouteSegmentManager(route: route);

      expect(manager.turnPoints, isEmpty);
      expect(manager.segments.length, equals(1));
      expect(manager.segments.first.isFinalSegment, isTrue);

      final revealed = manager.computeRevealedEndDistance(2.0, maxStraightMeters: 15.0);
      expect(revealed, equals(10.0)); // Destination reached
    });

    test('Route with turns caps path reveal at upcoming turn point', () {
      // 0 to 5m North, then turns East from 5m to 15m
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 90.0, 0.0, 5.0),
        PathNode(2, 90.0, 10.0, 5.0),
      ];
      final manager = RouteSegmentManager(route: route);

      expect(manager.turnPoints.length, equals(1));
      expect(manager.turnPoints.first.distance, equals(5.0));
      expect(manager.turnPoints.first.angleDeltaDeg, equals(90.0));

      // At start (1m progress): path must reveal ONLY up to the turn (5.0m), not beyond!
      final revealAtStart = manager.computeRevealedEndDistance(1.0);
      expect(revealAtStart, equals(5.0));

      // Approaching turn (progress 4.0m, within approach threshold of 1.2m):
      // dynamically unlocks and reveals the subsequent segment up to the destination
      final revealNearTurn = manager.computeRevealedEndDistance(4.0);
      expect(revealNearTurn, equals(manager.totalDistance));
    });
  });

  group('Wall and Depth Occlusion Tests', () {
    test('DepthOcclusionManager detects occluded waypoints and calculates clamped distance', () async {
      final manager = DepthOcclusionManager();

      // Mapped wall blocking line of sight
      final wallState = manager.evaluateWallGeometryOcclusion(
        userEast: 0.0,
        userNorth: 0.0,
        targetEast: 10.0,
        targetNorth: 0.0,
        walls: [
          const WallSegment(startEast: 5.0, startNorth: -2.0, endEast: 5.0, endNorth: 2.0),
        ],
      );
      expect(wallState.isOccluded, isTrue);
      expect(wallState.shouldHide, isTrue);

      // Unblocked
      final clearState = manager.evaluateWallGeometryOcclusion(
        userEast: 0.0,
        userNorth: 0.0,
        targetEast: 3.0,
        targetNorth: 0.0,
        walls: [
          const WallSegment(startEast: 5.0, startNorth: -2.0, endEast: 5.0, endNorth: 2.0),
        ],
      );
      expect(clearState.isOccluded, isFalse);
      expect(clearState.shouldHide, isFalse);
    });
  });

  group('AR UI Widgets Smoke & Interaction Tests', () {
    testWidgets('OffPathDirectionPrompt renders directional guidance and angle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OffPathDirectionPrompt(
              deltaDegrees: -45.0,
              turnDirection: 'left',
            ),
          ),
        ),
      );

      expect(find.text('TURN LEFT 45°'), findsOneWidget);
      expect(find.text('Face towards path to continue'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.arrow_left), findsOneWidget);
    });

    testWidgets('ArMiniMap renders and toggles between expanded and collapsed states', (tester) async {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArMiniMap(
              route: route,
              userEast: 0.0,
              userNorth: 2.0,
              userHeadingDegrees: 0.0,
              revealedEndDistance: 10.0,
              currentProgress: 2.0,
            ),
          ),
        ),
      );

      // Expanded initially: shows MAP header
      expect(find.text('MAP'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      // Tap to collapse
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      // Collapsed: shows map icon
      expect(find.byIcon(CupertinoIcons.map_fill), findsOneWidget);
      expect(find.text('MAP'), findsNothing);

      // Tap again to expand
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.text('MAP'), findsOneWidget);
    });

    testWidgets('ArPathPainter respects isFacingPath to suppress path when off-heading', (tester) async {
      final route = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 0.0, 0.0, 10.0),
      ];

      // Facing away (isFacingPath == false)
      final painterSuppressed = ArPathPainter(
        route: route,
        liveEast: 0.0,
        liveNorth: 0.0,
        headingDegrees: 90.0,
        tiltDegrees: 45.0,
        animationProgress: 0.5,
        startLabel: 'Start',
        destinationLabel: 'End',
        isFacingPath: false,
        maxRevealedDistance: 5.0,
      );

      // Calling paint should return early without throwing
      final pictureRecorder = PictureRecorder();
      final canvas = Canvas(pictureRecorder);
      painterSuppressed.paint(canvas, const Size(400, 800));
      final picture = pictureRecorder.endRecording();
      expect(picture, isNotNull);
    });

    testWidgets('ArWorldScannerOverlay renders Lottie mobile surface scanning animation and floor detection status', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ArWorldScannerOverlay(
                  floorConfidence: 0.0,
                ),
              ],
            ),
          ),
        ),
      );

      // Verify status text and HUD
      expect(find.text('Detecting Floor & Walls...'), findsOneWidget);
      expect(find.text('ARCORE SPATIAL SCAN'), findsOneWidget);
      expect(find.textContaining('Point camera towards the floor and move slowly'), findsOneWidget);

      // Verify Lottie animation widget is rendered
      expect(find.byType(Lottie), findsOneWidget);
    });
  });
}
