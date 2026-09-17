import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import '../models/map_models.dart';

/// A live snapshot of the walker's estimated position and device orientation
/// during navigation.
class LivePosition {
  final double east;
  final double north;
  final double headingDegrees;
  final double tiltDegrees;

  const LivePosition({
    required this.east,
    required this.north,
    required this.headingDegrees,
    required this.tiltDegrees,
  });
}

/// Tracks the walker's live position during navigation by map-matching: each
/// detected step advances (or retreats) a single arc-length "progress"
/// distance along the already-recorded route, rather than freely integrating
/// (east, north) from raw heading. Free integration lets small compass error
/// accumulate as *lateral* drift away from the corridor the walker is
/// actually in; snapping to the route makes that drift impossible by
/// construction, since the reported position is always a point on the
/// recorded path itself (see the AR floor-detection/anchoring research).
///
/// Step-length/motion-threshold constants mirror mapping_screen.dart, and
/// step *direction* (forward vs. backward) compares the live compass heading
/// against the route's own stored segment heading at the walker's current
/// position, so turns are handled by the route geometry, not by trusting
/// absolute heading to stay accurate over a long walk.
class LivePositionTracker {
  static const _poseChannel = EventChannel('mapx/arcore_pose');

  static const double stepLengthMeters = 0.5;
  static const double stepMotionThreshold = 0.4;
  static const double stepCooldownSeconds = 0.7;

  // TEMPORARY: step-triggered position advancement is disabled so the AR
  // line's heading/rendering stability can be assessed on its own, without
  // incidental phone jerks while panning to look around being misread as
  // footsteps. Position stays fixed at the start of the route until this is
  // switched back on. Re-enable once the line itself is solid.
  static const bool _stepDetectionEnabled = false;

  final List<PathNode> route;
  late final List<double> _distances;
  late final double _totalDistance;

  final _controller = StreamController<LivePosition>.broadcast();
  Stream<LivePosition> get positions => _controller.stream;

  StreamSubscription? _sub;
  double _progress;
  double _lastStepTime = 0;

  // Smoothed separately from the raw heading used for step math: the AR
  // overlay projects points in real 3D, where perspective math amplifies
  // small heading jitter into large on-screen swings for points away from
  // screen center - most visibly wherever the route bends away from
  // straight-ahead, since a rotation displaces off-axis points more than
  // ones near the viewing direction. A low-pass filter on sin/cos (a
  // circular mean, safe across the 0/360 wraparound) trades some latency
  // for a visibly stable line. Tuned fairly aggressive since heading noise
  // gets worse while actively tilting the phone (see MainActivity's
  // headingAndTiltFromMatrix: heading gets less precise as pitch steepens),
  // and turns are exactly where that noise reads as a lack of anchoring.
  static const double _headingSmoothing = 0.12;
  double? _smoothedSin;
  double? _smoothedCos;
  double? _smoothedTilt;

  LivePositionTracker({required this.route, double startProgress = 0})
      : _progress = startProgress {
    _distances = [0];
    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = sqrt(pow(cur.east - prev.east, 2) + pow(cur.north - prev.north, 2));
      _distances.add(_distances.last + d);
    }
    _totalDistance = _distances.isEmpty ? 0 : _distances.last;
  }

  void start() {
    _sub ??= _poseChannel.receiveBroadcastStream().listen(_onPose);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// The route position and stored segment heading at arc-length [dist].
  ({double east, double north, double headingDeg}) _sampleAt(double dist) {
    final clamped = dist.clamp(0.0, _totalDistance);
    for (var i = 0; i < route.length - 1; i++) {
      if (clamped >= _distances[i] && clamped <= _distances[i + 1]) {
        final span = _distances[i + 1] - _distances[i];
        final u = span > 0.0001 ? (clamped - _distances[i]) / span : 0.0;
        final a = route[i];
        final b = route[i + 1];
        return (
          east: a.east + (b.east - a.east) * u,
          north: a.north + (b.north - a.north) * u,
          headingDeg: b.heading,
        );
      }
    }
    final last = route.last;
    return (east: last.east, north: last.north, headingDeg: last.heading);
  }

  double _angleDiffDeg(double a, double b) {
    var d = (a - b) % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
  }

  void _onPose(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    final heading = (map['heading'] as num).toDouble();
    // Falls back to the compass heading on an older native build that
    // doesn't send it yet, rather than crashing on a missing key.
    final renderHeadingRaw = (map['renderHeading'] as num?)?.toDouble() ?? heading;
    final tilt = (map['tilt'] as num).toDouble();
    final motion = (map['motion'] as num).toDouble();
    final now = (map['timestamp'] as int) / 1e9;

    if (_stepDetectionEnabled &&
        motion >= stepMotionThreshold &&
        (now - _lastStepTime) > stepCooldownSeconds) {
      _lastStepTime = now;
      final tangentHeadingDeg = _sampleAt(_progress).headingDeg;
      final forward = _angleDiffDeg(heading, tangentHeadingDeg).abs() < 90.0;
      _progress = (_progress + (forward ? stepLengthMeters : -stepLengthMeters))
          .clamp(0.0, _totalDistance);
    }

    final sample = _sampleAt(_progress);

    final renderHeadingRad = renderHeadingRaw * pi / 180.0;
    _smoothedSin = _lerp(_smoothedSin, sin(renderHeadingRad), _headingSmoothing);
    _smoothedCos = _lerp(_smoothedCos, cos(renderHeadingRad), _headingSmoothing);
    _smoothedTilt = _lerp(_smoothedTilt, tilt, _headingSmoothing);
    final smoothedHeadingDeg = (atan2(_smoothedSin!, _smoothedCos!) * 180.0 / pi + 360.0) % 360.0;

    _controller.add(LivePosition(
      east: sample.east,
      north: sample.north,
      headingDegrees: smoothedHeadingDeg,
      tiltDegrees: _smoothedTilt!,
    ));
  }

  double _lerp(double? previous, double target, double alpha) {
    if (previous == null) return target;
    return previous + (target - previous) * alpha;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
