import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/route_segment_manager.dart';
import 'package:mapx/logic/spatial_sensor_fusion.dart';
import 'package:mapx/models/map_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Turn Handling Tolerance (±1 meter) Tests', () {
    // Standard test route:
    // Segment 0: (0, 0) to (0, 10) heading 0 (North). Total distance = 10m.
    // Right Turn at 10m: node 1 changes heading to 90 (East).
    // Segment 1: (0, 10) to (10, 10) heading 90 (East). Total distance = 20m.
    final rightTurnRoute = [
      PathNode(0, 0.0, 0.0, 0.0),
      PathNode(1, 90.0, 0.0, 10.0),
      PathNode(2, 90.0, 10.0, 10.0),
    ];

    test('Turn point detects 10m location and ±1m tolerance zone [9m, 11m]', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);

      expect(manager.turnPoints.length, equals(1));
      final turn = manager.turnPoints.first;
      expect(turn.distance, equals(10.0));
      expect(turn.toleranceMeters, equals(1.0));
      expect(turn.minValidDistance, equals(9.0));
      expect(turn.maxValidDistance, equals(11.0));
      expect(turn.angleDeltaDeg, equals(90.0));
      expect(turn.incomingHeadingDeg, closeTo(0.0, 1.0));
      expect(turn.outgoingHeadingDeg, closeTo(90.0, 1.0));

      // Check isInTurnZone boundary checks
      expect(turn.isInTurnZone(8.9), isFalse);
      expect(turn.isInTurnZone(9.0), isTrue);
      expect(turn.isInTurnZone(9.5), isTrue);
      expect(turn.isInTurnZone(10.0), isTrue);
      expect(turn.isInTurnZone(10.8), isTrue);
      expect(turn.isInTurnZone(11.0), isTrue);
      expect(turn.isInTurnZone(11.1), isFalse);
    });

    test('Example verification: Right turn mapped at 10 m', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);

      // 1. Turning at 9 m (early turn, 1m before) -> valid
      final eval9mTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0, // Turned right to face outgoing corridor
        currentProgress: 9.0,
      );
      expect(eval9mTurn.isFacingPath, isTrue, reason: 'Turning at 9m must be valid');
      expect(eval9mTurn.turnDirection, equals('straight'));

      manager.reset();

      // 2. Turning at 9.5 m -> valid
      final eval9_5mTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0,
        currentProgress: 9.5,
      );
      expect(eval9_5mTurn.isFacingPath, isTrue, reason: 'Turning at 9.5m must be valid');
      expect(eval9_5mTurn.turnDirection, equals('straight'));

      manager.reset();

      // 3. Turning at 10 m (exact mapped turn point) -> valid
      final eval10mTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0,
        currentProgress: 10.0,
      );
      expect(eval10mTurn.isFacingPath, isTrue, reason: 'Turning at 10m must be valid');
      expect(eval10mTurn.turnDirection, equals('straight'));

      manager.reset();

      // 4. Turning at 10.8 m (late turn, within 1m after) -> valid
      final eval10_8mTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0,
        currentProgress: 10.8,
      );
      expect(eval10_8mTurn.isFacingPath, isTrue, reason: 'Turning at 10.8m must be valid');
      expect(eval10_8mTurn.turnDirection, equals('straight'));

      manager.reset();

      // 5. Turning at 11 m (exact boundary of +1m late turn) -> valid
      final eval11mTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0,
        currentProgress: 11.0,
      );
      expect(eval11mTurn.isFacingPath, isTrue, reason: 'Turning at 11m must be valid');
      expect(eval11mTurn.turnDirection, equals('straight'));

      manager.reset();

      // 6. Turning / remaining straight at 11.1 m -> treated as wrong-turn / off-path
      // If user hasn't turned yet and continues straight North at 11.1m (past tolerance zone):
      final eval11_1mStraight = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0, // Still facing North, missed turn
        currentProgress: 11.1,
      );
      expect(eval11_1mStraight.isFacingPath, isFalse, reason: 'Beyond 11m without turn must be off-path');
      expect(eval11_1mStraight.turnDirection, equals('right'));
      expect(eval11_1mStraight.deltaDegrees, closeTo(90.0, 1.0));
    });

    test('Straight approach within tolerance zone [9m, 11m] is not treated as a wrong turn', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);

      // At 9.0m, still walking straight North before turning
      final eval9m = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0,
        currentProgress: 9.0,
      );
      expect(eval9m.isFacingPath, isTrue);

      // At 9.5m, still walking straight North
      final eval9_5m = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0,
        currentProgress: 9.5,
      );
      expect(eval9_5m.isFacingPath, isTrue);

      // At 10.0m, straight
      final eval10m = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0,
        currentProgress: 10.0,
      );
      expect(eval10m.isFacingPath, isTrue);

      // At 10.8m, still walking straight North in late tolerance zone
      final eval10_8m = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0,
        currentProgress: 10.8,
      );
      expect(eval10_8m.isFacingPath, isTrue);

      // At 11.0m, still walking straight North
      final eval11m = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 0.0,
        currentProgress: 11.0,
      );
      expect(eval11m.isFacingPath, isTrue);
    });

    test('Wrong turn direction within tolerance zone is treated as off-path', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);

      // Upcoming turn is RIGHT (+90 deg). User turns LEFT (270 / -90 deg) at 9.5m.
      final evalWrongDir = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 270.0,
        currentProgress: 9.5,
      );
      expect(evalWrongDir.isFacingPath, isFalse);
      expect(evalWrongDir.turnDirection, equals('right'));
    });

    test('Left turn mapped at 10 m has independent ±1 m tolerance', () {
      // Left turn: heading 0 (North) -> 270 (West)
      final leftTurnRoute = [
        PathNode(0, 0.0, 0.0, 0.0),
        PathNode(1, 270.0, 0.0, 10.0),
        PathNode(2, 270.0, -10.0, 10.0),
      ];

      final manager = RouteSegmentManager(route: leftTurnRoute);
      final turn = manager.turnPoints.first;
      expect(turn.angleDeltaDeg, equals(-90.0));
      expect(turn.incomingHeadingDeg, closeTo(0.0, 1.0));
      expect(turn.outgoingHeadingDeg, closeTo(270.0, 1.0));

      // Early left turn at 9.2m -> valid
      final evalEarlyLeft = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 270.0,
        currentProgress: 9.2,
      );
      expect(evalEarlyLeft.isFacingPath, isTrue);
      expect(evalEarlyLeft.turnDirection, equals('straight'));

      manager.reset();

      // Late left turn at 10.8m -> valid
      final evalLateLeft = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 270.0,
        currentProgress: 10.8,
      );
      expect(evalLateLeft.isFacingPath, isTrue);
      expect(evalLateLeft.turnDirection, equals('straight'));

      manager.reset();

      // Turning right (90 deg) when turn is left -> off-path
      final evalWrongTurn = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 90.0,
        currentProgress: 9.5,
      );
      expect(evalWrongTurn.isFacingPath, isFalse);
      expect(evalWrongTurn.turnDirection, equals('left'));
    });

    test('Valid early turn activates next segment and prevents getting stuck at original turn point', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      expect(manager.activeSegmentIndex, equals(0));

      // Before turn, progress at 9.2m
      final segBefore = manager.getSegmentForProgress(9.2);
      expect(segBefore.segmentIndex, equals(0));

      // User executes early turn at 9.2m
      final turn = manager.turnPoints.first;
      manager.registerTurnCompleted(turn);

      expect(manager.isTurnCompleted(0), isTrue);
      expect(manager.activeSegmentIndex, equals(1));

      // After early turn completion, next segment is activated even at 9.2m
      final segAfter = manager.getSegmentForProgress(9.2);
      expect(segAfter.segmentIndex, equals(1));
      expect(segAfter.isFinalSegment, isTrue);
    });

    test('SpatialSensorFusion advances progress across early turn without getting stuck', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final fusion = SpatialSensorFusion(
        route: rightTurnRoute,
        segmentManager: manager,
        startProgress: 9.2,
      );

      // Simulate step event while facing right (90 deg, the outgoing corridor)
      fusion.processPoseEvent({
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 90.0,
        'renderHeading': 90.0,
        'tilt': 0.0,
        'motion': 0.5,
        'timestamp': 1000000000,
        'floorDetected': true,
        'floorConfidence': 0.9,
        'arTrackingState': 'TRACKING',
      });

      // Second step event to confirm gait cadence
      fusion.processPoseEvent({
        'x': 0.5,
        'y': 0.0,
        'z': 0.0,
        'heading': 90.0,
        'renderHeading': 90.0,
        'tilt': 0.0,
        'motion': 0.5,
        'timestamp': 1800000000,
        'floorDetected': true,
        'floorConfidence': 0.9,
        'arTrackingState': 'TRACKING',
      });

      // Turn completed and progress advanced past the turn point (>= 10.0m)
      expect(manager.isTurnCompleted(0), isTrue);
      expect(fusion.currentProgress, greaterThanOrEqualTo(10.0));
      expect(manager.activeSegmentIndex, equals(1));
    });

    test('Early turn (1m early at 9.0m) counts 1.0m extra distance to destination', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final turn = manager.turnPoints.first;

      // User makes early turn at 9.0m (1m before 10.0m turn point)
      manager.registerTurnCompleted(turn, currentProgress: 9.0);

      expect(manager.isTurnCompleted(0), isTrue);
      expect(manager.extraTurnPenaltyDistance, equals(1.0));
      // At progress 10.0m (start of new corridor), remaining distance is (20.0 - 10.0) + 1.0 = 11.0m
      expect(manager.getRemainingDistance(10.0), equals(11.0));
    });

    test('Late turn (1m late at 11.0m) counts 1.0m extra distance to destination', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final turn = manager.turnPoints.first;

      // User makes late turn at 11.0m (1m past 10.0m turn point)
      manager.registerTurnCompleted(turn, currentProgress: 11.0);

      expect(manager.isTurnCompleted(0), isTrue);
      expect(manager.extraTurnPenaltyDistance, equals(1.0));
      // At progress 10.0m (start of new corridor), remaining distance is (20.0 - 10.0) + 1.0 = 11.0m
      expect(manager.getRemainingDistance(10.0), equals(11.0));
    });

    test('Distance tracking continues advancing after turn without freezing at vertex', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final fusion = SpatialSensorFusion(
        route: rightTurnRoute,
        segmentManager: manager,
        startProgress: 9.5, // Starting in turn zone
      );

      // Frame 1: complete the turn facing 90°
      fusion.processPoseEvent({
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 90.0,
        'renderHeading': 90.0,
        'tilt': 0.0,
        'motion': 0.6,
        'timestamp': 1000000000,
        'floorDetected': true,
        'floorConfidence': 0.9,
        'arTrackingState': 'TRACKING',
      });

      expect(manager.isTurnCompleted(0), isTrue);
      expect(fusion.currentProgress, equals(10.0));

      // Frames 2-5: continue walking forward East along new corridor (x increases)
      for (var step = 1; step <= 5; step++) {
        fusion.processPoseEvent({
          'x': step * 0.6,
          'y': 0.0,
          'z': 0.0,
          'heading': 90.0,
          'renderHeading': 90.0,
          'tilt': 0.0,
          'motion': 0.6,
          'timestamp': 1000000000 + (step * 500000000),
          'floorDetected': true,
          'floorConfidence': 0.9,
          'arTrackingState': 'TRACKING',
        });
      }

      // Must have continued advancing along the second corridor!
      expect(fusion.currentProgress, greaterThan(11.5));
      expect(fusion.currentProgress, lessThanOrEqualTo(20.0));
    });

    test('Backward travel tracking: walking in reverse decreases progress', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final fusion = SpatialSensorFusion(
        route: rightTurnRoute,
        segmentManager: manager,
        startProgress: 5.0, // Mid-segment 0 heading North
      );

      // Turn around facing 180° (South, opposite to route heading 0°)
      fusion.processPoseEvent({
        'x': 0.0,
        'y': 0.0,
        'z': 0.0,
        'heading': 180.0,
        'renderHeading': 180.0,
        'tilt': 0.0,
        'motion': 0.6,
        'timestamp': 1000000000,
        'floorDetected': true,
        'floorConfidence': 0.9,
        'arTrackingState': 'TRACKING',
      });

      // Walk backward along corridor
      for (var step = 1; step <= 3; step++) {
        fusion.processPoseEvent({
          'x': 0.0,
          'y': 0.0,
          'z': step * 0.5,
          'heading': 180.0,
          'renderHeading': 180.0,
          'tilt': 0.0,
          'motion': 0.6,
          'timestamp': 1000000000 + (step * 500000000),
          'floorDetected': true,
          'floorConfidence': 0.9,
          'arTrackingState': 'TRACKING',
        });
      }

      // Progress decreased (moved back towards 0m)
      expect(fusion.currentProgress, lessThan(5.0));
    });

    test('Dynamic segment rollback: backtracking across turn resets turn completion', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);
      final turn = manager.turnPoints.first;

      // Complete turn at 10.0m
      manager.registerTurnCompleted(turn, currentProgress: 10.0);
      expect(manager.isTurnCompleted(0), isTrue);
      expect(manager.activeSegmentIndex, equals(1));

      // User backtracks past the turn vertex (progress drops to 9.0m)
      manager.syncProgress(9.0);

      // Segment should roll back to 0 and turn becomes pending again
      expect(manager.activeSegmentIndex, equals(0));
      expect(manager.isTurnCompleted(0), isFalse);
    });

    test('Wrong direction / backward travel awareness detection', () {
      final manager = RouteSegmentManager(route: rightTurnRoute);

      // User heading 180° when target bearing is 0°
      final facingEval = manager.evaluateFacingWithTolerance(
        userHeadingDeg: 180.0,
        currentProgress: 5.0,
      );

      expect(facingEval.isFacingPath, isFalse);
      expect(facingEval.isTravelingBackward, isTrue);
    });
  });
}
