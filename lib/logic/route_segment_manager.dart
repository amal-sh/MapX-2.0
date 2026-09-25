import 'dart:math';
import '../models/map_models.dart';

/// Represents a distinct route decision point / turn along the path.
class RouteTurnPoint {
  static const double defaultToleranceMeters = 1.0;

  final int nodeIndex;
  final double distance;
  final double angleDeltaDeg;
  final String label;
  final double incomingHeadingDeg;
  final double outgoingHeadingDeg;
  final double toleranceMeters;

  const RouteTurnPoint({
    required this.nodeIndex,
    required this.distance,
    required this.angleDeltaDeg,
    required this.label,
    this.incomingHeadingDeg = 0.0,
    this.outgoingHeadingDeg = 0.0,
    this.toleranceMeters = defaultToleranceMeters,
  });

  /// The start of the valid turn tolerance zone (1 meter before the turn).
  double get minValidDistance => (distance - toleranceMeters).clamp(0.0, double.infinity);

  /// The end of the valid turn tolerance zone (1 meter after the turn).
  double get maxValidDistance => distance + toleranceMeters;

  /// Checks if [progress] is within the +/- 1 meter valid turn tolerance zone.
  bool isInTurnZone(double progress) =>
      progress >= minValidDistance && progress <= maxValidDistance;
}

/// Represents a linear sub-path segment between decision points (turns) or endpoints.
class RouteDecisionSegment {
  final int segmentIndex;
  final double startDistance;
  final double endDistance;
  final RouteTurnPoint? upcomingTurn; // null if leading directly to destination
  final bool isFinalSegment;

  const RouteDecisionSegment({
    required this.segmentIndex,
    required this.startDistance,
    required this.endDistance,
    this.upcomingTurn,
    this.isFinalSegment = false,
  });

  double get lengthMeters => (endDistance - startDistance).clamp(0.0, double.infinity);
}

/// Manages progressive route segmentation, turn points, and "reveal-as-you-go" logic.
///
/// Ensures the AR path only renders up to the upcoming decision point,
/// revealing subsequent segments only when the user approaches or passes each turn.
class RouteSegmentManager {
  final List<PathNode> route;
  late final List<double> _cumulativeDistances;
  late final List<RouteTurnPoint> _turnPoints;
  late final List<RouteDecisionSegment> _segments;
  late final double _totalDistance;

  List<double> get cumulativeDistances => _cumulativeDistances;
  List<RouteTurnPoint> get turnPoints => _turnPoints;
  List<RouteDecisionSegment> get segments => _segments;
  double get totalDistance => _totalDistance;

  /// Lookahead distance when determining tangent bearing along the path.
  static const double defaultLookaheadMeters = 1.5;

  /// Facing angle deviation threshold (degrees). If heading error exceeds this,
  /// user is considered "off-path" / facing away.
  static const double defaultFacingThresholdDeg = 35.0;

  /// Distance threshold before a turn to trigger progressive reveal of the next segment.
  static const double turnApproachThresholdMeters = 1.2;

  /// Valid turn tolerance distance (meters) before or after the exact mapped turn point.
  static const double turnToleranceMeters = 1.0;

  int _activeSegmentIndex = 0;
  int get activeSegmentIndex => _activeSegmentIndex;

  final Set<int> _completedTurnIndices = <int>{};
  bool isTurnCompleted(int turnIndex) => _completedTurnIndices.contains(turnIndex);

  /// Stores distance offsets (|progress - turnDistance|) for completed turns.
  final Map<int, double> _turnOffsets = <int, double>{};

  /// Total extra penalty distance accumulated by early or late turns (meters).
  double get extraTurnPenaltyDistance => _turnOffsets.values.fold(0.0, (sum, val) => sum + val);

  void registerTurnCompleted(RouteTurnPoint turn, {double? currentProgress}) {
    final idx = _turnPoints.indexOf(turn);
    if (idx != -1) {
      _completedTurnIndices.add(idx);
      _activeSegmentIndex = max(_activeSegmentIndex, idx + 1);
      if (currentProgress != null) {
        final offset = (currentProgress - turn.distance).abs().clamp(0.0, turn.toleranceMeters);
        _turnOffsets[idx] = offset;
      }
    }
  }

  void registerTurnCompletedByIndex(int turnIndex, {double? currentProgress}) {
    if (turnIndex >= 0 && turnIndex < _turnPoints.length) {
      _completedTurnIndices.add(turnIndex);
      _activeSegmentIndex = max(_activeSegmentIndex, turnIndex + 1);
      if (currentProgress != null) {
        final turn = _turnPoints[turnIndex];
        final offset = (currentProgress - turn.distance).abs().clamp(0.0, turn.toleranceMeters);
        _turnOffsets[turnIndex] = offset;
      }
    }
  }

  /// Synchronizes active segment index and completed turns when user travels backward.
  void syncProgress(double currentProgress) {
    while (_activeSegmentIndex > 0 &&
        currentProgress < _segments[_activeSegmentIndex].startDistance - 0.3) {
      _activeSegmentIndex--;
      final rolledTurnIdx = _activeSegmentIndex;
      _completedTurnIndices.remove(rolledTurnIdx);
      _turnOffsets.remove(rolledTurnIdx);
    }
  }

  /// True remaining distance to destination, accounting for any extra distance
  /// from making early or late turns.
  double getRemainingDistance(double currentProgress) {
    final baseRemaining = (_totalDistance - currentProgress).clamp(0.0, double.infinity);
    return baseRemaining + extraTurnPenaltyDistance;
  }

  void reset() {
    _activeSegmentIndex = 0;
    _completedTurnIndices.clear();
    _turnOffsets.clear();
  }

  RouteSegmentManager({required this.route}) {
    _computeCumulativeDistances();
    _computeTurnPoints();
    _computeSegments();
  }

  void _computeCumulativeDistances() {
    _cumulativeDistances = [0.0];
    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = sqrt(pow(cur.east - prev.east, 2) + pow(cur.north - prev.north, 2));
      _cumulativeDistances.add(_cumulativeDistances.last + d);
    }
    _totalDistance = _cumulativeDistances.isEmpty ? 0.0 : _cumulativeDistances.last;
  }

  void _computeTurnPoints() {
    _turnPoints = [];
    if (route.length < 3) return;

    for (var i = 1; i < route.length - 1; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      var delta = cur.heading - prev.heading;
      delta = ((delta + 180) % 360 + 360) % 360 - 180; // normalize to [-180, 180)

      if (delta.abs() > 15.0) {
        final dist = _cumulativeDistances[i];
        final label = _classifyTurn(delta);

        // Incoming segment heading
        final deIn = cur.east - prev.east;
        final dnIn = cur.north - prev.north;
        final inHeading = (sqrt(deIn * deIn + dnIn * dnIn) > 0.001)
            ? (atan2(deIn, dnIn) * 180.0 / pi + 360.0) % 360.0
            : prev.heading;

        // Outgoing segment heading
        final next = route[i + 1];
        final deOut = next.east - cur.east;
        final dnOut = next.north - cur.north;
        final outHeading = (sqrt(deOut * deOut + dnOut * dnOut) > 0.001)
            ? (atan2(deOut, dnOut) * 180.0 / pi + 360.0) % 360.0
            : cur.heading;

        _turnPoints.add(RouteTurnPoint(
          nodeIndex: i,
          distance: dist,
          angleDeltaDeg: delta,
          label: label,
          incomingHeadingDeg: inHeading,
          outgoingHeadingDeg: outHeading,
          toleranceMeters: turnToleranceMeters,
        ));
      }
    }
  }

  void _computeSegments() {
    _segments = [];
    if (route.isEmpty) return;

    if (_turnPoints.isEmpty) {
      // Single straight stretch all the way to destination
      _segments.add(RouteDecisionSegment(
        segmentIndex: 0,
        startDistance: 0.0,
        endDistance: _totalDistance,
        upcomingTurn: null,
        isFinalSegment: true,
      ));
      return;
    }

    double currentStart = 0.0;
    for (var i = 0; i < _turnPoints.length; i++) {
      final turn = _turnPoints[i];
      _segments.add(RouteDecisionSegment(
        segmentIndex: i,
        startDistance: currentStart,
        endDistance: turn.distance,
        upcomingTurn: turn,
        isFinalSegment: false,
      ));
      currentStart = turn.distance;
    }

    // Final segment from last turn to destination
    _segments.add(RouteDecisionSegment(
      segmentIndex: _turnPoints.length,
      startDistance: currentStart,
      endDistance: _totalDistance,
      upcomingTurn: null,
      isFinalSegment: true,
    ));
  }

  String _classifyTurn(double delta) {
    final mag = delta.abs();
    final dir = delta > 0 ? 'right' : 'left';
    if (mag > 150) return 'Make a U-turn';
    if (mag > 100) return 'Sharp turn $dir';
    if (mag > 45) return 'Turn $dir';
    return 'Bear $dir';
  }

  /// Evaluates which decision segment the user is currently on, taking into account
  /// turn completions and turn tolerance.
  RouteDecisionSegment getSegmentForProgress(double currentProgress) {
    final s = currentProgress.clamp(0.0, _totalDistance);

    // If an active segment is tracked:
    if (_activeSegmentIndex < _segments.length) {
      final activeSeg = _segments[_activeSegmentIndex];
      final upcomingTurn = activeSeg.upcomingTurn;
      final prevTurn = _activeSegmentIndex > 0 ? _turnPoints[_activeSegmentIndex - 1] : null;

      final minAllowed = (prevTurn != null && _completedTurnIndices.contains(_activeSegmentIndex - 1))
          ? prevTurn.minValidDistance
          : activeSeg.startDistance;

      final maxAllowed = (upcomingTurn != null && !_completedTurnIndices.contains(_activeSegmentIndex))
          ? upcomingTurn.maxValidDistance
          : activeSeg.endDistance;

      if (s >= minAllowed && s <= maxAllowed) {
        return activeSeg;
      }
    }

    // Check all segments respecting uncompleted turn late tolerance and completed turn early tolerance
    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final upcomingTurn = seg.upcomingTurn;
      final prevTurn = i > 0 ? _turnPoints[i - 1] : null;

      final minAllowed = (prevTurn != null && _completedTurnIndices.contains(i - 1))
          ? prevTurn.minValidDistance
          : seg.startDistance;

      final maxAllowed = (upcomingTurn != null && !_completedTurnIndices.contains(i))
          ? upcomingTurn.maxValidDistance
          : seg.endDistance;

      if (s >= minAllowed && s <= maxAllowed) {
        return seg;
      }
    }

    return _segments.isNotEmpty ? _segments.last : const RouteDecisionSegment(
      segmentIndex: 0,
      startDistance: 0.0,
      endDistance: 0.0,
      isFinalSegment: true,
    );
  }

  /// Computes the progressive reveal end distance along the route.
  ///
  /// - If the current segment has an upcoming turn:
  ///   renders only up to that turn point.
  /// - As the user nears the turn (within [turnApproachThresholdMeters]),
  ///   it unlocks and reveals the subsequent segment up to the following turn.
  /// - On straight stretch / final segment: renders up to the destination
  ///   (or straight render cap).
  double computeRevealedEndDistance(double currentProgress, {double maxStraightMeters = 15.0}) {
    final s = currentProgress.clamp(0.0, _totalDistance);
    if (_segments.isEmpty) return s;

    final currentSeg = getSegmentForProgress(s);
    final upcomingTurn = currentSeg.upcomingTurn;

    if (upcomingTurn != null) {
      final distToTurn = upcomingTurn.distance - s;
      // If still approaching the turn, cap rendering strictly at the turn point
      if (distToTurn > turnApproachThresholdMeters) {
        return upcomingTurn.distance;
      } else {
        // User is at or very close to the turn: reveal into the next segment
        final nextSegIdx = currentSeg.segmentIndex + 1;
        if (nextSegIdx < _segments.length) {
          final nextSeg = _segments[nextSegIdx];
          final nextCutoff = nextSeg.upcomingTurn?.distance ?? nextSeg.endDistance;
          // Smoothly interpolate reveal into next segment
          return min(_totalDistance, nextCutoff);
        }
        return upcomingTurn.distance;
      }
    }

    // Final segment straight stretch to destination
    return min(_totalDistance, s + maxStraightMeters);
  }

  /// Samples East, North coordinates along the path at given distance [dist].
  ({double east, double north, double headingDeg}) samplePositionAt(double dist) {
    if (route.isEmpty) return (east: 0.0, north: 0.0, headingDeg: 0.0);
    final clamped = dist.clamp(0.0, _totalDistance);

    for (var i = 0; i < route.length - 1; i++) {
      final isLast = (i == route.length - 2);
      final inSegment = isLast
          ? (clamped >= _cumulativeDistances[i] && clamped <= _cumulativeDistances[i + 1])
          : (clamped >= _cumulativeDistances[i] && clamped < _cumulativeDistances[i + 1]);
      if (inSegment) {
        final span = _cumulativeDistances[i + 1] - _cumulativeDistances[i];
        final u = span > 0.0001 ? (clamped - _cumulativeDistances[i]) / span : 0.0;
        final a = route[i];
        final b = route[i + 1];
        final de = b.east - a.east;
        final dn = b.north - a.north;
        final segHeading = (sqrt(de * de + dn * dn) > 0.001)
            ? (atan2(de, dn) * 180.0 / pi + 360.0) % 360.0
            : b.heading;
        return (
          east: a.east + de * u,
          north: a.north + dn * u,
          headingDeg: segHeading,
        );
      }
    }
    final last = route.last;
    double lastHeading = last.heading;
    if (route.length >= 2) {
      final prev = route[route.length - 2];
      final de = last.east - prev.east;
      final dn = last.north - prev.north;
      if (sqrt(de * de + dn * dn) > 0.001) {
        lastHeading = (atan2(de, dn) * 180.0 / pi + 360.0) % 360.0;
      }
    }
    return (east: last.east, north: last.north, headingDeg: lastHeading);
  }

  /// Calculates the forward path bearing (degrees, 0 = North, clockwise)
  /// looking ahead from [currentProgress] by [lookaheadMeters].
  double sampleTargetBearing(
    double currentProgress, {
    double lookaheadMeters = defaultLookaheadMeters,
    double? userHeadingDeg,
    double? userEast,
    double? userNorth,
  }) {
    final sCurrent = currentProgress.clamp(0.0, _totalDistance);

    // Lookahead clamping: when approaching an upcoming turn,
    // strictly track current corridor up to the turn zone (+/- 1m tolerance).
    // Within the tolerance zone or after turn completion, look ahead into the new corridor.
    final currentSeg = getSegmentForProgress(sCurrent);
    final upcomingTurn = currentSeg.upcomingTurn;

    double sAhead;
    if (upcomingTurn != null) {
      final distToTurn = upcomingTurn.distance - sCurrent;
      final inTurnZone = upcomingTurn.isInTurnZone(sCurrent);

      if (inTurnZone) {
        // Within +/- 1m tolerance zone:
        // If user is already facing the new corridor or turning, look into new corridor
        if (userHeadingDeg != null) {
          final deltaOut = computeHeadingDelta(userHeadingDeg, upcomingTurn.outgoingHeadingDeg).abs();
          if (deltaOut <= defaultFacingThresholdDeg + 10.0) {
            sAhead = min(_totalDistance, upcomingTurn.distance + max(1.0, lookaheadMeters));
          } else {
            // Still facing straight into turn zone
            sAhead = min(upcomingTurn.distance, sCurrent + lookaheadMeters);
          }
        } else {
          sAhead = min(_totalDistance, upcomingTurn.distance + max(1.0, lookaheadMeters));
        }
      } else if (distToTurn > turnToleranceMeters) {
        // Approaching turn before tolerance zone: keep locked to current corridor
        sAhead = min(upcomingTurn.distance, sCurrent + lookaheadMeters);
      } else {
        // Past the turn tolerance zone: look ahead along next corridor
        sAhead = min(_totalDistance, upcomingTurn.distance + max(1.0, lookaheadMeters));
      }
    } else {
      sAhead = min(_totalDistance, sCurrent + lookaheadMeters);
    }

    final double curEast;
    final double curNorth;
    if (userEast != null && userNorth != null) {
      curEast = userEast;
      curNorth = userNorth;
    } else {
      final sample = samplePositionAt(sCurrent);
      curEast = sample.east;
      curNorth = sample.north;
    }
    final posAhead = samplePositionAt(sAhead);

    final de = posAhead.east - curEast;
    final dn = posAhead.north - curNorth;

    if (sqrt(de * de + dn * dn) < 0.05) {
      // Very close to destination or stationary; use segment heading
      return samplePositionAt(sCurrent).headingDeg;
    }

    final bearingRad = atan2(de, dn);
    return (bearingRad * 180.0 / pi + 360.0) % 360.0;
  }

  /// Evaluates whether the user's device is facing toward the intended path,
  /// honoring the +/- 1 meter turn tolerance zone.
  ///
  /// In the [turn - 1m, turn + 1m] zone:
  /// - Turning early or late into the turn direction is VALID.
  /// - Continuing straight along the incoming corridor is VALID.
  /// - Facing away from both is treated as off-path / wrong turn.
  ({
    bool isFacingPath,
    bool isTravelingBackward,
    double deltaDegrees,
    String turnDirection, // 'left', 'right', or 'straight'
  }) evaluateFacingWithTolerance({
    required double userHeadingDeg,
    required double currentProgress,
    double? targetBearingDeg,
    double thresholdDeg = defaultFacingThresholdDeg,
  }) {
    final s = currentProgress.clamp(0.0, _totalDistance);
    final currentSeg = getSegmentForProgress(s);
    final upcomingTurn = currentSeg.upcomingTurn;

    if (upcomingTurn != null && upcomingTurn.isInTurnZone(s)) {
      // User is within the +/- 1 meter turn tolerance zone:
      // 1. Check if user turned towards outgoing corridor (valid early/on-time/late turn!)
      final deltaOut = computeHeadingDelta(userHeadingDeg, upcomingTurn.outgoingHeadingDeg);
      if (deltaOut.abs() <= thresholdDeg + 10.0) {
        registerTurnCompleted(upcomingTurn, currentProgress: s);
        return (
          isFacingPath: true,
          isTravelingBackward: false,
          deltaDegrees: deltaOut,
          turnDirection: 'straight',
        );
      }

      // 2. Check if user is still walking straight along incoming corridor (has not turned yet)
      final deltaIn = computeHeadingDelta(userHeadingDeg, upcomingTurn.incomingHeadingDeg);
      if (deltaIn.abs() <= thresholdDeg + 10.0) {
        return (
          isFacingPath: true,
          isTravelingBackward: false,
          deltaDegrees: deltaIn,
          turnDirection: 'straight',
        );
      }

      // 3. User is facing neither incoming nor outgoing corridor in the turn zone
      final turnDir = upcomingTurn.angleDeltaDeg > 0 ? 'right' : 'left';
      final isBackward = (deltaOut.abs() - 180.0).abs() <= 45.0 || (deltaIn.abs() - 180.0).abs() <= 45.0;
      return (
        isFacingPath: false,
        isTravelingBackward: isBackward,
        deltaDegrees: deltaOut,
        turnDirection: turnDir,
      );
    }

    // Outside of turn tolerance zone: standard target bearing evaluation
    final target = targetBearingDeg ?? sampleTargetBearing(s, userHeadingDeg: userHeadingDeg);
    final delta = computeHeadingDelta(userHeadingDeg, target);
    final isFacing = delta.abs() <= thresholdDeg;
    final isBackward = (delta.abs() - 180.0).abs() <= 45.0;
    final turnDir = isFacing
        ? 'straight'
        : (delta > 0 ? 'right' : 'left');

    return (
      isFacingPath: isFacing,
      isTravelingBackward: isBackward,
      deltaDegrees: delta,
      turnDirection: turnDir,
    );
  }

  /// Computes signed angle delta (degrees) between target bearing and user heading:
  /// Positive = target is to the user's right (turn right).
  /// Negative = target is to the user's left (turn left).
  static double computeHeadingDelta(double userHeadingDeg, double targetBearingDeg) {
    var delta = (targetBearingDeg - userHeadingDeg) % 360.0;
    if (delta > 180.0) delta -= 360.0;
    if (delta < -180.0) delta += 360.0;
    return delta;
  }

  /// Evaluates whether the user's device is facing toward the intended path.
  static ({
    bool isFacingPath,
    bool isTravelingBackward,
    double deltaDegrees,
    String turnDirection, // 'left', 'right', or 'straight'
  }) evaluateFacing({
    required double userHeadingDeg,
    required double targetBearingDeg,
    double thresholdDeg = defaultFacingThresholdDeg,
  }) {
    final delta = computeHeadingDelta(userHeadingDeg, targetBearingDeg);
    final isFacing = delta.abs() <= thresholdDeg;
    final isBackward = (delta.abs() - 180.0).abs() <= 45.0;
    final turnDir = isFacing
        ? 'straight'
        : (delta > 0 ? 'right' : 'left');

    return (
      isFacingPath: isFacing,
      isTravelingBackward: isBackward,
      deltaDegrees: delta,
      turnDirection: turnDir,
    );
  }
}
