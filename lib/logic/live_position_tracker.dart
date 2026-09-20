import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import '../models/map_models.dart';

/// A live snapshot of the walker's estimated position and device orientation
/// during navigation, including ARCore floor plane detection metrics.
class LivePosition {
  final double east;
  final double north;
  final double headingDegrees;
  final double tiltDegrees;
  final double progress; // arc-length meters walked along the route
  final bool isFloorDetected;
  final double cameraHeight;
  final double verticalFovDegrees;
  final String arTrackingState;

  const LivePosition({
    required this.east,
    required this.north,
    required this.headingDegrees,
    required this.tiltDegrees,
    required this.progress,
    this.isFloorDetected = false,
    this.cameraHeight = 1.35,
    this.verticalFovDegrees = 60.0,
    this.arTrackingState = 'INITIALIZING',
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
/// Step length/motion-magnitude threshold mirror mapping_screen.dart, but
/// unlike mapping (a deliberate, closely-watched recording process), the
/// trigger itself requires a sustained walking rhythm rather than a single
/// motion spike, so an incidental jerk while navigating doesn't move the
/// tracked position (see _consecutivePeaks below). Step *direction* (forward
/// vs. backward) compares the live compass heading against the route's own
/// stored segment heading at the walker's current position, so turns are
/// handled by the route geometry, not by trusting absolute heading to stay
/// accurate over a long walk.
class LivePositionTracker {
  static const _poseChannel = EventChannel('mapx/arcore_pose');

  static const double stepLengthMeters = 0.72;
  static const double stepMotionThreshold = 0.4;

  // A genuine footstep is followed by another one at a fairly steady
  // cadence, over and over; an isolated jerk (adjusting grip, a bump,
  // gesturing while looking around) is a one-off spike with nothing
  // resembling it nearby. So a single motion spike is never enough on its
  // own - it only becomes a step once it's the *second* spike in a row
  // spaced at a plausible walking cadence. An isolated jerk never gets that
  // second, similarly-timed spike, so it's filtered out for free.
  //
  // The minimum matches mapping_screen.dart's proven step cadence exactly
  // (that detector's only debounce, and the one this project already trusts)
  // rather than a shorter one: a looser minimum let a single footstep's
  // accelerometer bounce register as two separate steps, advancing the
  // tracked position faster than real walking.
  static const double _minStepIntervalSeconds = 0.7;
  static const double _maxStepIntervalSeconds = 1.2;

  static const bool _stepDetectionEnabled = true;

  final List<PathNode> route;
  late final List<double> _distances;
  late final double _totalDistance;
  double get totalDistance => _totalDistance;

  final _controller = StreamController<LivePosition>.broadcast();
  Stream<LivePosition> get positions => _controller.stream;

  StreamSubscription? _sub;
  double _progress;
  double _displayedProgress;
  double _lastPeakTime = 0;
  double? _lastPoseTime;
  int _consecutivePeaks = 0;

  // Position only advances in discrete stepLengthMeters jumps, the instant a
  // step is confirmed, so rendering straight from _progress made the line
  // visibly snap forward once per step instead of gliding. _displayedProgress
  // eases toward _progress instead of jumping to it, so the walk between
  // steps still reads as continuous motion. Kept separate from _progress
  // itself, which stays the immediately-correct value used for the
  // forward/backward tangent decision at turns.
  //
  // The easing is time-based (using actual elapsed seconds between pose
  // updates), not a fixed fraction applied per update - a fixed-per-update
  // fraction makes the smoothing rate depend on how often pose events happen
  // to arrive, and converges most of the way within a fraction of a second,
  // which visibly caught up in a burst right as each new step landed rather
  // than gliding evenly across the whole ~0.7-1.2s step interval.
  static const double _positionSmoothingTimeConstant = 0.55;

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
  double? _smoothedCameraHeight;
  double? _smoothedFov;

  LivePositionTracker({required this.route, double startProgress = 0})
      : _progress = startProgress,
        _displayedProgress = startProgress {
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

    if (_stepDetectionEnabled && motion >= stepMotionThreshold) {
      final gap = now - _lastPeakTime;
      // Debounces one footstep's rising motion from being counted as
      // multiple spikes in quick succession.
      if (gap >= _minStepIntervalSeconds) {
        _consecutivePeaks =
            (gap <= _maxStepIntervalSeconds && _consecutivePeaks > 0) ? _consecutivePeaks + 1 : 1;
        _lastPeakTime = now;

        if (_consecutivePeaks >= 2) {
          final tangentHeadingDeg = _sampleAt(_progress).headingDeg;
          final forward = _angleDiffDeg(heading, tangentHeadingDeg).abs() < 90.0;
          _progress = (_progress + (forward ? stepLengthMeters : -stepLengthMeters))
              .clamp(0.0, _totalDistance);
        }
      }
    }

    final dt = _lastPoseTime == null ? 1 / 30 : (now - _lastPoseTime!).clamp(0.0, 0.5);
    _lastPoseTime = now;
    final positionAlpha = 1 - exp(-dt / _positionSmoothingTimeConstant);
    _displayedProgress = _lerp(_displayedProgress, _progress, positionAlpha);
    final sample = _sampleAt(_displayedProgress);

    final renderHeadingRad = renderHeadingRaw * pi / 180.0;
    _smoothedSin = _lerp(_smoothedSin, sin(renderHeadingRad), _headingSmoothing);
    _smoothedCos = _lerp(_smoothedCos, cos(renderHeadingRad), _headingSmoothing);
    _smoothedTilt = _lerp(_smoothedTilt, tilt, _headingSmoothing);
    final smoothedHeadingDeg = (atan2(_smoothedSin!, _smoothedCos!) * 180.0 / pi + 360.0) % 360.0;

    final isFloorDetected = (map['floorDetected'] as bool?) ?? false;
    final floorHeightRaw = (map['floorHeight'] as num?)?.toDouble() ?? 1.35;
    final fovRaw = (map['cameraFovY'] as num?)?.toDouble() ?? 60.0;
    final arTrackingState = (map['arTrackingState'] as String?) ?? 'INITIALIZING';

    _smoothedCameraHeight = _lerp(_smoothedCameraHeight, floorHeightRaw, 0.1);
    _smoothedFov = _lerp(_smoothedFov, fovRaw, 0.1);

    _controller.add(LivePosition(
      east: sample.east,
      north: sample.north,
      headingDegrees: smoothedHeadingDeg,
      tiltDegrees: _smoothedTilt!,
      progress: _displayedProgress,
      isFloorDetected: isFloorDetected,
      cameraHeight: _smoothedCameraHeight ?? 1.35,
      verticalFovDegrees: _smoothedFov ?? 60.0,
      arTrackingState: arTrackingState,
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
