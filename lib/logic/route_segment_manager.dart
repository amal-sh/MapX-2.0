import 'dart:math';
import '../models/map_models.dart';

/// Represents a distinct route decision point / turn along the path.
class RouteTurnPoint {
  final int nodeIndex;
  final double distance;
  final double angleDeltaDeg;
  final String label;

  const RouteTurnPoint({
    required this.nodeIndex,
    required this.distance,
    required this.angleDeltaDeg,
    required this.label,
  });
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
        _turnPoints.add(RouteTurnPoint(
          nodeIndex: i,
          distance: dist,
          angleDeltaDeg: delta,
          label: label,
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

  /// Evaluates which decision segment the user is currently on.
  RouteDecisionSegment getSegmentForProgress(double currentProgress) {
    final s = currentProgress.clamp(0.0, _totalDistance);
    for (final seg in _segments) {
      if (s >= seg.startDistance && s <= seg.endDistance) {
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
      if (clamped >= _cumulativeDistances[i] && clamped <= _cumulativeDistances[i + 1]) {
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
    double? userEast,
    double? userNorth,
  }) {
    final sCurrent = currentProgress.clamp(0.0, _totalDistance);
    final sAhead = min(_totalDistance, sCurrent + lookaheadMeters);

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
    double deltaDegrees,
    String turnDirection, // 'left', 'right', or 'straight'
  }) evaluateFacing({
    required double userHeadingDeg,
    required double targetBearingDeg,
    double thresholdDeg = defaultFacingThresholdDeg,
  }) {
    final delta = computeHeadingDelta(userHeadingDeg, targetBearingDeg);
    final isFacing = delta.abs() <= thresholdDeg;
    final turnDir = isFacing
        ? 'straight'
        : (delta > 0 ? 'right' : 'left');

    return (
      isFacingPath: isFacing,
      deltaDegrees: delta,
      turnDirection: turnDir,
    );
  }
}
