import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';

import '../models/map_models.dart';
import 'coordinate_transform.dart';
import 'route_segment_manager.dart';
import 'wall_collision_validator.dart';

enum TrackingConfidence {
  high,
  medium,
  low,
  lost,
}

/// A comprehensive fused snapshot of the walker's physical position,
/// 3D ARCore pose, floor metrics, walls, and tracking confidence.
class FusedPosition {
  final double east;
  final double north;
  final double headingDegrees;
  final double tiltDegrees;
  final double progressMeters; // arc-length meters along route
  final double totalRouteMeters;
  final bool isFloorDetected;
  final double floorHeight;
  final double floorConfidence;
  final double cameraFovY;
  final String arTrackingState;
  final TrackingConfidence confidence;
  final bool isDrifting;
  final String driftReason;
  final List<WallSegment> detectedWalls;
  final bool depthSupported;
  final bool depthAvailable;
  final int stepCount;
  final double actualStrideLength;

  const FusedPosition({
    required this.east,
    required this.north,
    required this.headingDegrees,
    required this.tiltDegrees,
    required this.progressMeters,
    required this.totalRouteMeters,
    this.isFloorDetected = false,
    this.floorHeight = 1.35,
    this.floorConfidence = 0.0,
    this.cameraFovY = 60.0,
    this.arTrackingState = 'INITIALIZING',
    this.confidence = TrackingConfidence.medium,
    this.isDrifting = false,
    this.driftReason = '',
    this.detectedWalls = const [],
    this.depthSupported = false,
    this.depthAvailable = false,
    this.stepCount = 0,
    this.actualStrideLength = 0.5,
  });
}

/// Robust sensor fusion engine combining ARCore 6-DOF VIO metric displacement,
/// PDR gait cadence filtering, corridor geometry constraints, and real-time drift detection.
class SpatialSensorFusion {
  static const _poseChannel = EventChannel('mapx/arcore_pose');

  static const double minStepCadenceSeconds = 0.50;
  static const double maxStepCadenceSeconds = 1.40;
  static const double stepMotionThreshold = 0.30;
  static const double defaultStepLengthMeters = 0.72; // Standard adult human step length (meters)

  final List<PathNode> route;
  final List<WallSegment> mappedWalls;
  final double corridorHalfWidth;
  final RouteSegmentManager segmentManager;

  late final List<double> _cumulativeDistances;
  late final double _totalRouteDistance;
  double get totalRouteDistance => _totalRouteDistance;

  final CoordinateTransform coordinateTransform = CoordinateTransform();

  final _controller = StreamController<FusedPosition>.broadcast();
  Stream<FusedPosition> get positions => _controller.stream;

  StreamSubscription? _sub;

  // State
  double _progress;
  double _displayedProgress;
  double _totalVioDisplacement = 0.0;
  double _totalPdrDisplacement = 0.0;
  int _stepCount = 0;
  double _strideLengthEstimate = defaultStepLengthMeters;

  // Sub-frame VIO displacement accumulator to eliminate stance-phase metric loss
  double _subFrameVioAccumulator = 0.0;
  double _vioDistSinceLastStep = 0.0;
  double _stationaryTime = 0.0;

  double? _lastVioX;
  double? _lastVioY;
  double? _lastVioZ;
  double? _lastPoseTime;
  double? _lastRenderHeading;
  double _turnRateDegPerSec = 0.0;
  double? _lastTilt;
  double _tiltRateDegPerSec = 0.0;
  double? _lastQx;
  double? _lastQy;
  double? _lastQz;
  double? _lastQw;
  double _angularSpeedDegPerSec = 0.0;
  double _reorientationCooldown = 0.0;
  double _lastStepTime = 0.0;
  int _consecutiveGaitPeaks = 0;
  bool _isGaitActive = false;
  bool _wasTracking = false;

  double get currentProgress => _progress;

  // Smoothing filters
  double? _smoothedCompSin;
  double? _smoothedCompCos;
  double? _smoothedTilt;
  double? _smoothedCameraHeight;
  double? _smoothedFov;

  bool _isDrifting = false;
  String _driftReason = '';

  SpatialSensorFusion({
    required this.route,
    this.mappedWalls = const [],
    this.corridorHalfWidth = 1.35,
    double startProgress = 0.0,
    RouteSegmentManager? segmentManager,
  })  : segmentManager = segmentManager ?? RouteSegmentManager(route: route),
        _progress = startProgress,
        _displayedProgress = startProgress {
    _cumulativeDistances = [0.0];
    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = sqrt(pow(cur.east - prev.east, 2) + pow(cur.north - prev.north, 2));
      _cumulativeDistances.add(_cumulativeDistances.last + d);
    }
    _totalRouteDistance = _cumulativeDistances.isEmpty ? 0.0 : _cumulativeDistances.last;
  }

  void start() {
    _sub ??= _poseChannel.receiveBroadcastStream().listen(_onPoseEvent);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  ({double east, double north, double headingDeg}) _sampleAt(double dist) {
    final clamped = dist.clamp(0.0, _totalRouteDistance);
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

  double _angleDiff(double a, double b) {
    var d = (a - b) % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
  }

  void _onPoseEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    final now = (map['timestamp'] as int) / 1e9;

    final vioX = (map['x'] as num).toDouble();
    final vioY = (map['y'] as num).toDouble();
    final vioZ = (map['z'] as num).toDouble();
    final bool hasQuaternion = map.containsKey('qx') && map['qx'] != null;
    final qx = (map['qx'] as num?)?.toDouble() ?? 0.0;
    final qy = (map['qy'] as num?)?.toDouble() ?? 0.0;
    final qz = (map['qz'] as num?)?.toDouble() ?? 0.0;
    final qw = (map['qw'] as num?)?.toDouble() ?? 1.0;
    final heading = (map['heading'] as num).toDouble();
    final renderHeading = (map['renderHeading'] as num?)?.toDouble() ?? heading;
    final tilt = (map['tilt'] as num).toDouble();
    final motion = (map['motion'] as num).toDouble();

    final isFloorDetected = (map['floorDetected'] as bool?) ?? false;
    final floorHeightRaw = (map['floorHeight'] as num?)?.toDouble() ?? 1.35;
    final floorConfidence = (map['floorConfidence'] as num?)?.toDouble() ?? 0.0;
    final cameraFovYRaw = (map['cameraFovY'] as num?)?.toDouble() ?? 60.0;
    final arTrackingState = (map['arTrackingState'] as String?) ?? 'INITIALIZING';
    final isTracking = arTrackingState == 'TRACKING';
    final depthSupported = (map['depthSupported'] as bool?) ?? false;
    final depthAvailable = (map['depthAvailable'] as bool?) ?? false;

    // Parse dynamic walls detected by ARCore vertical plane tracker
    final rawWalls = map['walls'] as List<dynamic>? ?? [];
    final List<WallSegment> detectedWalls = [];
    for (final w in rawWalls) {
      if (w is Map) {
        final x1 = (w['x1'] as num?)?.toDouble() ?? 0.0;
        final z1 = (w['z1'] as num?)?.toDouble() ?? 0.0;
        final x2 = (w['x2'] as num?)?.toDouble() ?? 0.0;
        final z2 = (w['z2'] as num?)?.toDouble() ?? 0.0;
        // Map world endpoints to map coordinates if calibrated
        final p1 = coordinateTransform.isCalibrated
            ? coordinateTransform.worldToMap(x1, z1)
            : (east: x1, north: z1);
        final p2 = coordinateTransform.isCalibrated
            ? coordinateTransform.worldToMap(x2, z2)
            : (east: x2, north: z2);
        detectedWalls.add(WallSegment(
          startEast: p1.east,
          startNorth: p1.north,
          endEast: p2.east,
          endNorth: p2.north,
        ));
      }
    }

    // 1. Initial calibration when floor plane is locked, or Re-calibration after tracking recovery
    if (isTracking && isFloorDetected) {
      if (!coordinateTransform.isCalibrated) {
        final startNode = route.first;
        coordinateTransform.calibrate(
          startEast: startNode.east,
          startNorth: startNode.north,
          startHeadingDeg: startNode.heading,
          camX: vioX,
          camY: vioY,
          camZ: vioZ,
          camYawDeg: renderHeading,
          floorHeight: floorHeightRaw,
        );
      } else if (!_wasTracking) {
        // RE-ANCHORING ON TRACKING RECOVERY:
        // While ARCore tracking was degraded/lost, PDR dead-reckoning maintained the user's
        // forward progress. Now that ARCore is tracking again, re-anchor the coordinate
        // transform to the current corridor position so the virtual AR world aligns with the
        // user's actual real-world location (e.g. at 10m, not back at 8m).
        final currentPos = _sampleAt(_progress);
        coordinateTransform.calibrate(
          startEast: currentPos.east,
          startNorth: currentPos.north,
          startHeadingDeg: currentPos.headingDeg,
          camX: vioX,
          camY: vioY,
          camZ: vioZ,
          camYawDeg: renderHeading,
          floorHeight: floorHeightRaw,
        );
        // Reset last VIO pose baseline to avoid computing a bogus jump across the tracking outage
        _lastVioX = vioX;
        _lastVioY = vioY;
        _lastVioZ = vioZ;
      }
    }

    // Turn rate, tilt rate, and 3D reorientation tracking
    final dt = _lastPoseTime == null ? 1 / 30 : (now - _lastPoseTime!).clamp(0.001, 0.5);
    _lastPoseTime = now;

    // A. Azimuth / Heading turn rate (horizontal yaw)
    double dHeading = 0.0;
    if (_lastRenderHeading != null) {
      dHeading = _angleDiff(renderHeading, _lastRenderHeading!).abs();
      final instantTurnRate = dHeading / dt;
      final decay = exp(-dt / 0.15);
      _turnRateDegPerSec = _turnRateDegPerSec * decay + instantTurnRate * (1.0 - decay);
    }
    _lastRenderHeading = renderHeading;

    // B. Pitch / Tilt rate (holding phone upright, tilting up/down)
    double dTilt = 0.0;
    double instantTiltRate = 0.0;
    if (_lastTilt != null) {
      dTilt = (tilt - _lastTilt!).abs();
      instantTiltRate = dTilt / dt;
      final decay = exp(-dt / 0.15);
      _tiltRateDegPerSec = _tiltRateDegPerSec * decay + instantTiltRate * (1.0 - decay);
    }
    _lastTilt = tilt;

    // C. 3D Quaternion angular velocity (all 3 rotation axes combined)
    double dAngle3D = 0.0;
    if (hasQuaternion && _lastQx != null) {
      final dot = (qx * _lastQx! + qy * _lastQy! + qz * _lastQz! + qw * _lastQw!).abs().clamp(0.0, 1.0);
      dAngle3D = 2.0 * acos(dot) * 180.0 / pi;
      final instantAngularSpeed = dAngle3D / dt;
      final decay = exp(-dt / 0.15);
      _angularSpeedDegPerSec = _angularSpeedDegPerSec * decay + instantAngularSpeed * (1.0 - decay);
    }
    if (hasQuaternion) {
      _lastQx = qx;
      _lastQy = qy;
      _lastQz = qz;
      _lastQw = qw;
    }

    // D. Vertical hand level / elevation change (raising or lowering phone without walking)
    double dVioY = 0.0;
    if (_lastVioY != null && _wasTracking && isTracking) {
      dVioY = (vioY - _lastVioY!).abs();
    }
    _lastVioY = vioY;

    // Compute raw frame horizontal displacement and speed for in-place motion gating
    double frameDist = 0.0;
    double instantSpeed = 0.0;
    if (_lastVioX != null && _wasTracking && isTracking) {
      final dx = vioX - _lastVioX!;
      final dz = vioZ - _lastVioZ!;
      frameDist = sqrt(dx * dx + dz * dz);
      instantSpeed = dt > 0.0 ? frameDist / dt : 0.0;
    }

    // A user is stationary if their horizontal speed is under 0.40 m/s or frameDist < 0.015m
    final isStationaryMotion = instantSpeed < 0.40 || frameDist < 0.015;

    // Detect device manipulation states:
    // In-place turn (yaw): sustained turn rate > 25 deg/sec or sudden frame turn > 4.5 deg
    final isTurningInPlace = _turnRateDegPerSec > 25.0 || dHeading > 4.5;

    // In-place tilt / pitch change:
    // When stationary, detect any deliberate tilt adjustment (rate > 12 deg/s or dTilt > 0.8 deg)
    // When physically walking, require rapid tilt > 25 deg/s so normal walking sway is never suppressed
    final isTiltingInPlace = isStationaryMotion
        ? (instantTiltRate > 12.0 || _tiltRateDegPerSec > 10.0 || dTilt > 0.8)
        : (_tiltRateDegPerSec > 25.0 || dTilt > 3.5);

    // In-place 3D reorientation: sustained angular speed > 28 deg/sec or sudden frame reorientation > 4.5 deg
    final isReorientingInPlace = hasQuaternion
        ? (_angularSpeedDegPerSec > 28.0 || dAngle3D > 4.5)
        : (isTurningInPlace || isTiltingInPlace);

    // In-place vertical level shift: vertical movement dominates horizontal movement
    final isVerticalLevelShift = (dVioY > 0.020 && dVioY > 1.8 * frameDist);

    final isActivelyAdjusting = isTurningInPlace || isTiltingInPlace || isReorientingInPlace || isVerticalLevelShift;

    // Cooldown buffer: after user tilts, rotates, or shifts phone level in-place, maintain suppression
    // unless the user walks forward (instantSpeed >= 0.50 m/s and frameDist >= 0.018m), which clears cooldown immediately.
    final isWalkingForward = instantSpeed >= 0.50 && frameDist >= 0.018;
    if (isActivelyAdjusting) {
      _reorientationCooldown = 0.20;
    } else if (isWalkingForward) {
      _reorientationCooldown = 0.0;
    } else if (_reorientationCooldown > 0.0) {
      _reorientationCooldown = (_reorientationCooldown - dt).clamp(0.0, 5.0);
    }
    final isDeviceAdjusting = isActivelyAdjusting || (_reorientationCooldown > 0.0);

    // 2. Gait rhythm / step cadence detection
    bool isStepEvent = false;
    if (isDeviceAdjusting) {
      // INHIBIT STEP TRIGGERING DURING IN-PLACE TURN, TILT, OR LEVEL CHANGE:
      // Foot shuffling, body pivoting, arm level shifts, or tilting phone upright
      // must NOT be registered as forward walking strides!
      _consecutiveGaitPeaks = 0;
      _isGaitActive = false;
      _subFrameVioAccumulator = 0.0;
    } else if (motion >= stepMotionThreshold) {
      final gap = now - _lastStepTime;
      if (gap >= minStepCadenceSeconds) {
        _consecutiveGaitPeaks =
            (gap <= maxStepCadenceSeconds && _consecutiveGaitPeaks > 0) ? _consecutiveGaitPeaks + 1 : 1;
        _lastStepTime = now;

        if (_consecutiveGaitPeaks >= 2) {
          _isGaitActive = true;
          _stepCount++;
          _totalPdrDisplacement += _strideLengthEstimate;
          isStepEvent = true;
        }
      }
    } else if (now - _lastStepTime > maxStepCadenceSeconds * 1.5) {
      _isGaitActive = false;
      _consecutiveGaitPeaks = 0;
    }

    // 3. VIO Metric Displacement & Sensor Fusion with PDR Fallback
    double deltaProgress = 0.0;

    // Evaluate effective corridor heading and turn tolerance:
    double tangentHeadingDeg = _sampleAt(_progress).headingDeg;
    final currentSeg = segmentManager.getSegmentForProgress(_progress);
    final upcomingTurn = currentSeg.upcomingTurn;

    if (upcomingTurn != null && upcomingTurn.isInTurnZone(_progress)) {
      final deltaToTurn = _angleDiff(heading, upcomingTurn.outgoingHeadingDeg).abs();
      if (deltaToTurn <= 45.0) {
        // User turned into outgoing corridor within tolerance zone (+/- 1m)
        segmentManager.registerTurnCompleted(upcomingTurn);
        if (_progress < upcomingTurn.distance) {
          // Early turn: advance progress to the turn point to activate next segment corridor
          _progress = upcomingTurn.distance;
          _displayedProgress = max(_displayedProgress, upcomingTurn.distance);
        }
        tangentHeadingDeg = upcomingTurn.outgoingHeadingDeg;
      } else {
        final deltaIncoming = _angleDiff(heading, upcomingTurn.incomingHeadingDeg).abs();
        if (deltaIncoming <= 45.0 && _progress <= upcomingTurn.maxValidDistance) {
          // User is still walking straight along incoming corridor in the tolerance zone
          tangentHeadingDeg = upcomingTurn.incomingHeadingDeg;
        } else {
          tangentHeadingDeg = upcomingTurn.outgoingHeadingDeg;
        }
      }
    }

    final headingDeltaDeg = _angleDiff(heading, tangentHeadingDeg);
    final absHeadingDelta = headingDeltaDeg.abs();

    // Corridor alignment:
    // When the user is facing generally along the corridor path (within +/- 45°), they receive 1.0 (100% distance).
    // Between 45° and 75°, smooth roll-off to 0.0.
    // Beyond 75° (facing wall / sideways), scale is 0.0 (progress inhibited).
    // For reverse direction (180° +/- 45°), scale is -1.0.
    final isFacingPath = absHeadingDelta <= 55.0;

    double corridorScale = 0.0;
    if (absHeadingDelta <= 45.0) {
      corridorScale = 1.0;
    } else if (absHeadingDelta <= 75.0) {
      corridorScale = (75.0 - absHeadingDelta) / 30.0;
    } else if ((absHeadingDelta - 180.0).abs() <= 45.0) {
      corridorScale = -1.0;
    } else if ((absHeadingDelta - 180.0).abs() <= 75.0) {
      corridorScale = -((75.0 - (absHeadingDelta - 180.0).abs()) / 30.0);
    }

    if (isTracking) {
      // ACTIVE TRACKING: High-precision metric VIO drives progression
      if (_lastVioX != null && _wasTracking) {
        final dx = vioX - _lastVioX!;
        final dz = vioZ - _lastVioZ!;
        final frameDist = sqrt(dx * dx + dz * dz);

        // Filter out glitchy VIO jumps (> 1.5m in one ~33ms frame)
        if (frameDist < 1.5) {
          double effectiveDist = frameDist;

          // Camera horizontal forward vector projection & lateral arc swing filtering
          if (isDeviceAdjusting) {
            effectiveDist = 0.0;
          } else if (frameDist < 0.015 && dVioY > 0.020) {
            // Predominantly vertical hand movement with negligible horizontal motion
            effectiveDist = 0.0;
          } else if (hasQuaternion && frameDist < 0.020) {
            final fx = -2.0 * (qx * qz + qw * qy);
            final fz = -(1.0 - 2.0 * (qx * qx + qy * qy));
            final hLen = sqrt(fx * fx + fz * fz);
            if (hLen > 0.05) {
              final hfx = fx / hLen;
              final hfz = fz / hLen;
              final fwdComp = dx * hfx + dz * hfz;
              final latComp = (dx * (-hfz) + dz * hfx).abs();
              // If motion is predominantly lateral arc swing with negligible forward component, suppress it
              if (latComp > 2.0 * fwdComp.abs() && fwdComp.abs() < 0.015) {
                effectiveDist = 0.0;
              }
            }
          }

          final isPhysicallyMoving = (_isGaitActive || motion >= 0.15) && !isDeviceAdjusting;

          // When physically moving, accumulate frame displacements along corridor
          // When stationary, ignore microscopic sensor jitter (< 10mm/frame)
          if (isPhysicallyMoving || effectiveDist >= 0.010) {
            _subFrameVioAccumulator += effectiveDist;
            _vioDistSinceLastStep += effectiveDist;
          }

          final isMoving = isPhysicallyMoving || _subFrameVioAccumulator >= 0.020;

          if (isMoving && _subFrameVioAccumulator > 0.0 && !isDeviceAdjusting) {
            _stationaryTime = 0.0;
            final appliedDist = _subFrameVioAccumulator;
            _totalVioDisplacement += appliedDist;
            deltaProgress = appliedDist * corridorScale;
            _subFrameVioAccumulator = 0.0;

            // Online VIO Step Calibration:
            // When a confirmed physical step occurs and VIO was tracking cleanly across the step,
            // adapt the step length estimate using the distance accumulated across the full step duration.
            if (isStepEvent) {
              if (_vioDistSinceLastStep >= 0.40 && _vioDistSinceLastStep <= 1.25) {
                _strideLengthEstimate = _strideLengthEstimate * 0.85 + _vioDistSinceLastStep * 0.15;
              }

              // True Anti-Slippage Fallback:
              // ONLY when facing along path corridor, NOT adjusting device, and confirmed gait rhythm.
              // Note: When ARCore is tracking properly with good floor confidence, trust VIO ground truth!
              // Anti-slippage fallback is strictly for when visual tracking is degraded.
              final isReliableVio = isTracking && floorConfidence >= 0.35;
              if (!isReliableVio && _vioDistSinceLastStep < 0.15 && isFacingPath && !isDeviceAdjusting && _isGaitActive) {
                final pdrDelta = _strideLengthEstimate * corridorScale;
                if (pdrDelta.abs() > deltaProgress.abs()) {
                  deltaProgress = pdrDelta;
                }
              }
              _vioDistSinceLastStep = 0.0;
            }
          } else {
            // Stationary deadband: phone is held still / resting or adjusting device.
            // Reset accumulator after stillness or device adjustment to prevent integration drift.
            _stationaryTime += dt;
            if (_stationaryTime > 0.4 || isDeviceAdjusting) {
              _subFrameVioAccumulator = 0.0;
            }
          }
        }
      }
    } else {
      // TRACKING LOST OR DEGRADED: PDR Dead-Reckoning Fallback
      if (isStepEvent && isFacingPath && !isDeviceAdjusting && _isGaitActive) {
        deltaProgress = _strideLengthEstimate * corridorScale;
        _totalVioDisplacement += deltaProgress.abs();
      }
      _vioDistSinceLastStep = 0.0;
      _subFrameVioAccumulator = 0.0;
    }

    _lastVioX = vioX;
    _lastVioZ = vioZ;
    _wasTracking = isTracking;

    // 4. Update along-corridor progress with boundary clamping
    final proposedProgress = (_progress + deltaProgress).clamp(0.0, _totalRouteDistance);
    final proposedPos = _sampleAt(proposedProgress);

    // 5. Anti-Drift & Boundary Verification
    _isDrifting = false;
    _driftReason = '';

    // Check A: Wall Penetration
    final currentPos = _sampleAt(_progress);
    final allWalls = [...mappedWalls, ...detectedWalls];
    final wallBlocked = (proposedProgress != _progress) && WallCollisionValidator.isLineOfSightBlocked(
      startEast: currentPos.east,
      startNorth: currentPos.north,
      targetEast: proposedPos.east,
      targetNorth: proposedPos.north,
      walls: allWalls,
    );

    if (wallBlocked) {
      _isDrifting = true;
      _driftReason = 'Wall collision detected ahead';
      // Inhibit advancing through the wall!
    } else {
      _progress = proposedProgress;
    }

    // Check B: VIO vs PDR Disparity check
    if (_totalVioDisplacement > 10.0 && _totalPdrDisplacement > 6.0) {
      final disparity = (_totalVioDisplacement - _totalPdrDisplacement).abs();
      if (disparity > 5.0 && disparity > 0.4 * _totalVioDisplacement) {
        _isDrifting = true;
        _driftReason = 'Tracking displacement divergence (${disparity.toStringAsFixed(1)}m)';
      }
    }

    // 6. Smooth progress easing for rendering
    const smoothingTimeConstant = 0.35;
    final alpha = 1.0 - exp(-dt / smoothingTimeConstant);
    _displayedProgress = _lerp(_displayedProgress, _progress, alpha);

    final finalSample = _sampleAt(_displayedProgress);

    // Heading & Camera FOV smoothing
    final compRad = heading * pi / 180.0;
    _smoothedCompSin = _lerp(_smoothedCompSin, sin(compRad), 0.12);
    _smoothedCompCos = _lerp(_smoothedCompCos, cos(compRad), 0.12);
    final smoothedCompassHeading = (atan2(_smoothedCompSin!, _smoothedCompCos!) * 180.0 / pi + 360.0) % 360.0;

    _smoothedTilt = _lerp(_smoothedTilt, tilt, 0.12);

    _smoothedCameraHeight = _lerp(_smoothedCameraHeight, floorHeightRaw, 0.10);
    _smoothedFov = _lerp(_smoothedFov, cameraFovYRaw, 0.10);

    // Compute overall tracking confidence
    TrackingConfidence confidence;
    if (!isTracking) {
      confidence = TrackingConfidence.lost;
    } else if (_isDrifting || floorConfidence < 0.3) {
      confidence = TrackingConfidence.low;
    } else if (floorConfidence >= 0.6 && isFloorDetected) {
      confidence = TrackingConfidence.high;
    } else {
      confidence = TrackingConfidence.medium;
    }

    _controller.add(FusedPosition(
      east: finalSample.east,
      north: finalSample.north,
      headingDegrees: smoothedCompassHeading,
      tiltDegrees: _smoothedTilt!,
      progressMeters: _displayedProgress,
      totalRouteMeters: _totalRouteDistance,
      isFloorDetected: isFloorDetected,
      floorHeight: _smoothedCameraHeight ?? 1.35,
      floorConfidence: floorConfidence,
      cameraFovY: _smoothedFov ?? 60.0,
      arTrackingState: arTrackingState,
      confidence: confidence,
      isDrifting: _isDrifting,
      driftReason: _driftReason,
      detectedWalls: detectedWalls,
      depthSupported: depthSupported,
      depthAvailable: depthAvailable,
      stepCount: _stepCount,
      actualStrideLength: _strideLengthEstimate,
    ));
  }

  double _lerp(double? prev, double target, double alpha) {
    if (prev == null) return target;
    return prev + (target - prev) * alpha;
  }

  /// Relocalizes progress to a known junction/waypoint arc-length.
  void snapToProgress(double targetProgress) {
    _progress = targetProgress.clamp(0.0, _totalRouteDistance);
    _displayedProgress = _progress;
  }

  /// Processes an event directly (useful for testing or custom streams)
  void processPoseEvent(Map<String, dynamic> map) => _onPoseEvent(map);

  /// Resets all session tracking, accumulators, and PDR baselines for a new navigation run.
  void resetSession({double startProgress = 0.0}) {
    segmentManager.reset();
    _progress = startProgress.clamp(0.0, _totalRouteDistance);
    _displayedProgress = _progress;
    _totalVioDisplacement = 0.0;
    _totalPdrDisplacement = 0.0;
    _stepCount = 0;
    _strideLengthEstimate = defaultStepLengthMeters;
    _lastVioX = null;
    _lastVioY = null;
    _lastVioZ = null;
    _lastPoseTime = null;
    _lastRenderHeading = null;
    _turnRateDegPerSec = 0.0;
    _lastTilt = null;
    _tiltRateDegPerSec = 0.0;
    _lastQx = null;
    _lastQy = null;
    _lastQz = null;
    _lastQw = null;
    _angularSpeedDegPerSec = 0.0;
    _reorientationCooldown = 0.0;
    _lastStepTime = 0.0;
    _consecutiveGaitPeaks = 0;
    _isGaitActive = false;
    _wasTracking = false;
    _subFrameVioAccumulator = 0.0;
    _smoothedCompSin = null;
    _smoothedCompCos = null;
    _vioDistSinceLastStep = 0.0;
    _stationaryTime = 0.0;
    _isDrifting = false;
    _driftReason = '';
    coordinateTransform.reset();
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
