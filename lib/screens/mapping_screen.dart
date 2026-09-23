import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/coordinate_transform.dart';
import '../models/map_models.dart';
import '../widgets/path_map_painter.dart';

class MappingScreen extends StatefulWidget {
  final String mapName;
  final int floor;

  const MappingScreen({super.key, required this.mapName, required this.floor});

  @override
  State<MappingScreen> createState() => _MappingScreenState();
}

class _MappingScreenState extends State<MappingScreen> {
  static const _methodChannel = MethodChannel('mapx/arcore');
  static const _poseChannel = EventChannel('mapx/arcore_pose');

  static const double _stepLengthMeters = 0.5; // for VIO node discretization
  static const double _defaultPdrStepLengthMeters = 0.72; // calibrated adult human step length
  static const double _stepMotionThreshold = 0.4;
  static const double _stepCooldownSeconds = 0.7;
  static const double _resumeGraceSeconds = 0.6;
  static const double _minUprightTilt = 45;

  String _arcoreStatus = 'Checking ARCore support...';
  bool _mapping = false;
  bool _isTurning = false;
  bool _isAddingNode = false;
  bool _isPaused = false;
  bool _isTracking = false;
  
  double _heading = 0;
  double _tilt = 0;
  double _peakMotion = 0;
  int _minFeatures = 1 << 30;

  // ARCore VIO & Spatial Sensor Fusion state
  final CoordinateTransform _coordinateTransform = CoordinateTransform();
  double? _lastVioX;
  double? _lastVioY;
  double? _lastVioZ;
  bool _isFloorDetected = false;

  // Real metric VIO keyframing in map coordinates (East, North)
  double _lastNodeEast = 0.0;
  double _lastNodeNorth = 0.0;
  double _currentMapEast = 0.0;
  double _currentMapNorth = 0.0;

  double? _lastPoseTime;
  double? _lastPoseHeading;
  double _turnRateDegPerSec = 0.0;
  double? _lastTilt;
  double _tiltRateDegPerSec = 0.0;
  double _reorientationCooldown = 0.0;

  final List<PathSegment> _segments = [];
  final List<Waypoint> _waypoints = [];
  int _stepCount = 0;
  double _lastStepTime = 0;
  bool _pendingGrace = false;
  double _resumeAt = 0;
  StreamSubscription? _poseSub;
  Timer? _screenKeepAliveTimer;
  static const Duration _screenInactivityTimeout = Duration(minutes: 8);

  void _resetScreenKeepAliveTimer() {
    if (!_mapping) return;
    try {
      _methodChannel.invokeMethod('setKeepScreenOn', {'enabled': true});
    } catch (_) {}
    _screenKeepAliveTimer?.cancel();
    _screenKeepAliveTimer = Timer(_screenInactivityTimeout, () {
      try {
        _methodChannel.invokeMethod('setKeepScreenOn', {'enabled': false});
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _checkArCore();
  }

  @override
  void dispose() {
    _screenKeepAliveTimer?.cancel();
    _poseSub?.cancel();
    try {
      _methodChannel.invokeMethod('setKeepScreenOn', {'enabled': false});
      _methodChannel.invokeMethod('stopArNavigation');
    } catch (_) {}
    super.dispose();
  }

  Future<void> _checkArCore() async {
    try {
      final result =
          await _methodChannel.invokeMethod<String>('checkAvailability');
      setState(() {
        _arcoreStatus = _describe(result);
      });
    } on PlatformException catch (e) {
      setState(() {
        _arcoreStatus = 'Error checking ARCore: ${e.message}';
      });
    }
  }

  String _describe(String? availability) {
    switch (availability) {
      case 'SUPPORTED_INSTALLED':
        return 'ARCore is supported and ready on this device.';
      case 'SUPPORTED_APK_TOO_OLD':
        return 'ARCore is supported, but Google Play Services for AR needs an update.';
      case 'SUPPORTED_NOT_INSTALLED':
        return 'ARCore is supported, but Google Play Services for AR is not installed.';
      case 'UNSUPPORTED_DEVICE_NOT_CAPABLE':
        return 'This device does NOT support ARCore.';
      default:
        return 'ARCore availability unknown ($availability).';
    }
  }

  Future<void> _startMapping() async {
    setState(() {
      _mapping = true;
      _segments.clear();
      _segments.add(PathSegment(floor: widget.floor));
      _waypoints.clear();
      _stepCount = 0;
      _lastStepTime = 0;
      _peakMotion = 0;
      _minFeatures = 1 << 30;
      _isTurning = false;
      _isPaused = false;
      _pendingGrace = true;
      _lastVioX = null;
      _lastVioY = null;
      _lastVioZ = null;
      _lastNodeEast = 0.0;
      _lastNodeNorth = 0.0;
      _currentMapEast = 0.0;
      _currentMapNorth = 0.0;
      _coordinateTransform.reset();
      _isFloorDetected = false;
    });

    try {
      await _methodChannel.invokeMethod('startSession');
      await _methodChannel.invokeMethod('startArNavigation');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _mapping = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not start mapping')),
      );
      return;
    }
    if (!mounted) return;

    _resetScreenKeepAliveTimer();

    _poseSub = _poseChannel.receiveBroadcastStream().listen(
      _onPose,
      onError: (Object error) {
        setState(() {
          _isTracking = false;
        });
      },
    );
  }

  void _onPose(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    final tracking = (map['tracking'] as bool?) ?? false;
    final heading = (map['heading'] as num).toDouble();
    final renderHeading = (map['renderHeading'] as num?)?.toDouble() ?? heading;
    final tilt = (map['tilt'] as num).toDouble();
    final motion = (map['motion'] as num).toDouble();
    final features = (map['features'] as int?) ?? 0;
    final now = (map['timestamp'] as int) / 1e9;

    final vioX = (map['x'] as num?)?.toDouble() ?? 0.0;
    final vioY = (map['y'] as num?)?.toDouble() ?? 0.0;
    final vioZ = (map['z'] as num?)?.toDouble() ?? 0.0;

    final isFloorDetected = (map['floorDetected'] as bool?) ?? false;
    final floorHeightRaw = (map['floorHeight'] as num?)?.toDouble() ?? 1.35;

    if (_pendingGrace) {
      _resumeAt = now + _resumeGraceSeconds;
      _pendingGrace = false;
    }

    final dt = _lastPoseTime == null ? 1 / 30 : (now - _lastPoseTime!).clamp(0.001, 0.5);
    _lastPoseTime = now;

    // A. Heading turn rate
    double dHeading = 0.0;
    if (_lastPoseHeading != null) {
      var d = (heading - _lastPoseHeading!).abs() % 360.0;
      if (d > 180.0) d = 360.0 - d;
      dHeading = d;
      final instantTurnRate = dHeading / dt;
      final decay = exp(-dt / 0.15);
      _turnRateDegPerSec = _turnRateDegPerSec * decay + instantTurnRate * (1.0 - decay);
    }
    _lastPoseHeading = heading;

    // B. Pitch / Tilt rate
    double dTilt = 0.0;
    if (_lastTilt != null) {
      dTilt = (tilt - _lastTilt!).abs();
      final instantTiltRate = dTilt / dt;
      final decay = exp(-dt / 0.15);
      _tiltRateDegPerSec = _tiltRateDegPerSec * decay + instantTiltRate * (1.0 - decay);
    }
    _lastTilt = tilt;

    // C. Vertical elevation change
    double dVioY = 0.0;
    if (_lastVioY != null && tracking) {
      dVioY = (vioY - _lastVioY!).abs();
    }
    _lastVioY = vioY;

    // 1. Calibration: Lock initial frame to Map North (East, North)
    if (tracking && !_coordinateTransform.isCalibrated) {
      _coordinateTransform.calibrate(
        startEast: _lastNodeEast,
        startNorth: _lastNodeNorth,
        startHeadingDeg: heading,
        camX: vioX,
        camY: vioY,
        camZ: vioZ,
        camYawDeg: renderHeading,
        floorHeight: floorHeightRaw,
      );
      _lastVioX = vioX;
      _lastVioY = vioY;
      _lastVioZ = vioZ;
      _currentMapEast = _lastNodeEast;
      _currentMapNorth = _lastNodeNorth;
    }

    // 2. Hybrid VIO Spatial Keyframing + PDR Fallback
    bool stepDetected = false;
    if (!_isTurning && !_isAddingNode && !_isPaused && now >= _resumeAt) {
      if (tracking && _coordinateTransform.isCalibrated && _lastVioX != null) {
        final dx = vioX - _lastVioX!;
        final dz = vioZ - _lastVioZ!;
        final frameDist = sqrt(dx * dx + dz * dz);

        // Update real map coordinates from 3D VIO
        final mapPos = _coordinateTransform.worldToMap(vioX, vioZ);
        _currentMapEast = mapPos.east;
        _currentMapNorth = mapPos.north;

        // Detect in-place device adjustment:
        final isTurningInPlace = (_turnRateDegPerSec > 35.0 || dHeading > 3.0) && frameDist < 0.020;
        final isTiltingInPlace = (_tiltRateDegPerSec > 20.0 || dTilt > 2.5) && frameDist < 0.020;
        final isVerticalLevelShift = (dVioY > 0.035 && dVioY > 1.5 * frameDist && frameDist < 0.020);
        final isActivelyAdjusting = isTurningInPlace || isTiltingInPlace || isVerticalLevelShift;

        if (isActivelyAdjusting) {
          _reorientationCooldown = 0.35;
        } else if (frameDist >= 0.020) {
          _reorientationCooldown = 0.0; // walking forward clears cooldown immediately
        } else if (_reorientationCooldown > 0.0) {
          _reorientationCooldown = (_reorientationCooldown - dt).clamp(0.0, 5.0);
        }
        final isDeviceAdjusting = isActivelyAdjusting || (_reorientationCooldown > 0.0);

        // Filter out glitchy teleport jumps (> 1.5m in ~33ms)
        if (frameDist < 1.5) {
          _lastVioX = vioX;
          _lastVioY = vioY;
          _lastVioZ = vioZ;

          // Euclidean distance from last dropped keyframe node
          final dEast = mapPos.east - _lastNodeEast;
          final dNorth = mapPos.north - _lastNodeNorth;
          final distFromLastNode = sqrt(dEast * dEast + dNorth * dNorth);

          // Automatic corridor turn detection: if heading changed > 35° from last recorded step
          // Must NOT trigger while adjusting device in place!
          if (!isDeviceAdjusting && _segments.isNotEmpty && _segments.last.steps.isNotEmpty) {
            final lastHeading = _segments.last.steps.last.heading;
            final diff = (heading - lastHeading).abs() % 360.0;
            final normDiff = diff > 180 ? 360 - diff : diff;
            if (normDiff > 35.0) {
              // Commit distance walked up to the corner vertex before starting new segment
              if (distFromLastNode >= 0.15) {
                _recordStep(heading, length: distFromLastNode);
                _stepCount++;
                _lastNodeEast = mapPos.east;
                _lastNodeNorth = mapPos.north;
              }
              _segments.add(PathSegment(floor: widget.floor));
            }
          }

          // Spatial keyframing: drop a node when user has physically traversed >= _stepLengthMeters
          if (!isDeviceAdjusting && distFromLastNode >= _stepLengthMeters) {
            stepDetected = true;
            _lastStepTime = now;
            _stepCount++;
            _recordStep(heading, length: distFromLastNode);
            _lastNodeEast = mapPos.east;
            _lastNodeNorth = mapPos.north;
          }
        }
      } else {
        // PDR Fallback: Step detection using accelerometer motion thresholding
        // Inhibit if adjusting device in-place
        final isTiltingInPlace = (_tiltRateDegPerSec > 20.0 || dTilt > 2.5);
        final isTurningInPlace = (_turnRateDegPerSec > 35.0 || dHeading > 3.0);
        final isDeviceAdjusting = isTiltingInPlace || isTurningInPlace || (_reorientationCooldown > 0.0);

        if (!isDeviceAdjusting && motion >= _stepMotionThreshold && (now - _lastStepTime) > _stepCooldownSeconds) {
          stepDetected = true;
          _lastStepTime = now;
          _stepCount++;
          _recordStep(heading, length: _defaultPdrStepLengthMeters);
          final rad = heading * pi / 180.0;
          _lastNodeEast += _defaultPdrStepLengthMeters * sin(rad);
          _lastNodeNorth += _defaultPdrStepLengthMeters * cos(rad);
          _currentMapEast = _lastNodeEast;
          _currentMapNorth = _lastNodeNorth;
        }
      }
    }

    if (stepDetected || motion >= 0.30) {
      _resetScreenKeepAliveTimer();
    }

    setState(() {
      _isTracking = tracking;
      _isFloorDetected = isFloorDetected;
      _heading = heading;
      _tilt = tilt;
      if (motion > _peakMotion) {
        _peakMotion = motion;
      }
      _minFeatures = min(_minFeatures, features);
    });
  }

  List<PathNode> get _computedNodes {
    final List<PathNode> nodes = [];
    double currentEast = 0;
    double currentNorth = 0;

    final initialHeading = _segments.isNotEmpty && _segments.first.steps.isNotEmpty
        ? _segments.first.steps.first.heading
        : 0.0;
    nodes.add(PathNode(0, initialHeading, currentEast, currentNorth, floor: widget.floor));

    int index = 1;
    for (final segment in _segments) {
      final avgHeadingRad = segment.averageHeading * pi / 180.0;
      for (final step in segment.steps) {
        currentEast += step.length * sin(avgHeadingRad);
        currentNorth += step.length * cos(avgHeadingRad);
        nodes.add(PathNode(index++, segment.averageHeading, currentEast, currentNorth, floor: widget.floor));
      }
    }
    return nodes;
  }

  double get _pathLength {
    final nodes = _computedNodes;
    double total = 0;
    for (var i = 1; i < nodes.length; i++) {
      total += _horizontalDistance(nodes[i].east, nodes[i].north,
          nodes[i - 1].east, nodes[i - 1].north);
    }
    // Include live progress toward next keyframe
    if (_isTracking && _coordinateTransform.isCalibrated) {
      final liveEast = _currentMapEast - _lastNodeEast;
      final liveNorth = _currentMapNorth - _lastNodeNorth;
      final liveDist = sqrt(liveEast * liveEast + liveNorth * liveNorth);
      total += liveDist.clamp(0.0, _stepLengthMeters);
    }
    return total;
  }

  double _horizontalDistance(double ax, double az, double bx, double bz) {
    return sqrt(pow(ax - bx, 2) + pow(az - bz, 2));
  }

  void _recordStep(double heading, {double? length}) {
    if (_segments.isEmpty) {
      _segments.add(PathSegment(floor: widget.floor));
    }
    _segments.last.steps.add(RawStep(heading, length ?? _stepLengthMeters, floor: widget.floor));
  }

  Future<void> _registerTurn() async {
    setState(() {
      _isTurning = true;
    });

    // Commit distance walked up to the corner vertex before starting new corridor segment
    if (_isTracking && _coordinateTransform.isCalibrated) {
      final remEast = _currentMapEast - _lastNodeEast;
      final remNorth = _currentMapNorth - _lastNodeNorth;
      final distFromLastNode = sqrt(remEast * remEast + remNorth * remNorth);
      if (distFromLastNode >= 0.15 && _segments.isNotEmpty) {
        _recordStep(_heading, length: distFromLastNode);
        _stepCount++;
        _lastNodeEast = _currentMapEast;
        _lastNodeNorth = _currentMapNorth;
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Corridor Turn'),
        content: const Text('Face your new direction of travel.\n\nTap Ready when you have completed your turn.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Ready', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (!mounted) return;

    setState(() {
      _segments.add(PathSegment(floor: widget.floor));
      _isTurning = false;
      _pendingGrace = true;
    });
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
      if (!_isPaused) _pendingGrace = true;
    });
  }

  Future<void> _addMarker() async {
    setState(() => _isAddingNode = true);
    final TextEditingController controller = TextEditingController();
    final String? label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Waypoint / POI'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'e.g., Room 101, Elevator, Exit',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    setState(() {
      _isAddingNode = false;
      _pendingGrace = true;
      if (label != null && label.isNotEmpty) {
        _waypoints.add(Waypoint(_stepCount, label, floor: widget.floor));
      }
    });
  }

  Future<void> _saveMap() async {
    if (_segments.isEmpty || _stepCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot save an empty map.')),
      );
      return;
    }

    // Save any remainder distance at the end of the route so physical distance is precisely preserved
    if (_isTracking && _coordinateTransform.isCalibrated) {
      final remEast = _currentMapEast - _lastNodeEast;
      final remNorth = _currentMapNorth - _lastNodeNorth;
      final distFromLastNode = sqrt(remEast * remEast + remNorth * remNorth);
      if (distFromLastNode >= 0.08 && _segments.isNotEmpty) {
        _segments.last.steps.add(RawStep(_heading, distFromLastNode, floor: widget.floor));
        _stepCount++;
        _lastNodeEast = _currentMapEast;
        _lastNodeNorth = _currentMapNorth;
      }
    }

    // Stop AR session cleanly and release screen wake lock
    _screenKeepAliveTimer?.cancel();
    try {
      await _methodChannel.invokeMethod('setKeepScreenOn', {'enabled': false});
      await _methodChannel.invokeMethod('stopArNavigation');
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();

    final mapData = {
      'segments': _segments.map((s) => s.toJson()).toList(),
      'waypoints': _waypoints.map((w) => w.toJson()).toList(),
      'walls': <Map<String, dynamic>>[],
      'stepCount': _stepCount,
      'name': widget.mapName,
      'floor': widget.floor,
    };

    await prefs.setString('map_${widget.mapName}#${widget.floor}', jsonEncode(mapData));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Map "${widget.mapName}" saved successfully with ${_computedNodes.length} nodes!')),
    );

    Navigator.pop(context, true);
  }

  Future<bool> _onWillPop() async {
    if (_mapping) {
      final shouldPop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Mapping?'),
          content: const Text('You are actively recording a map. Are you sure you want to leave without saving?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (shouldPop == true) {
        _screenKeepAliveTimer?.cancel();
        try {
          await _methodChannel.invokeMethod('setKeepScreenOn', {'enabled': false});
          await _methodChannel.invokeMethod('stopArNavigation');
        } catch (_) {}
      }
      return shouldPop ?? false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_mapping,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: _mapping ? _buildSplitScreenMapping(context) : _buildIdleScreen(context),
    );
  }

  /// Idle / Setup Screen before mapping begins
  Widget _buildIdleScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          color: Colors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('${widget.mapName} · Floor ${widget.floor}'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F4F5),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Icon(CupertinoIcons.viewfinder, size: 28, color: Colors.black),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Ready to Map ${widget.mapName}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _arcoreStatus,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF71717A)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Mapping Feature Highlights
              Expanded(
                child: ListView(
                  children: [
                    _buildFeatureRow(
                      icon: Icons.splitscreen_rounded,
                      title: 'Split-Screen AR View',
                      subtitle: 'Live camera feed at the top and interactive 2D floorplan at the bottom.',
                    ),
                    const SizedBox(height: 14),
                    _buildFeatureRow(
                      icon: CupertinoIcons.scope,
                      title: 'Hybrid ARCore VIO + PDR',
                      subtitle: 'Millimeter visual-inertial odometry fused with step dead-reckoning fallback.',
                    ),
                    const SizedBox(height: 14),
                    _buildFeatureRow(
                      icon: CupertinoIcons.device_phone_portrait,
                      title: 'Hold Phone Upright',
                      subtitle: 'Maintain an upright chest-height posture for optimal optical feature tracking.',
                    ),
                  ],
                ),
              ),

              // Start Mapping Button
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
                onPressed: _startMapping,
                icon: const Icon(CupertinoIcons.play_arrow_solid, size: 20),
                label: const Text(
                  'Start Mapping',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureRow({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF4F4F5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: Colors.black),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF71717A), height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Active Split-Screen: Top half AR Camera, Bottom half 2D Map
  Widget _buildSplitScreenMapping(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetScreenKeepAliveTimer(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
        children: [
          // ==================== TOP HALF: LIVE AR CAMERA HUD ====================
          Expanded(
            flex: 44,
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  // Top Navigation & Status Bar Overlay
                  Positioned(
                    top: 8,
                    left: 14,
                    right: 14,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Back / Discard button
                        GestureDetector(
                          onTap: () async {
                            final shouldPop = await _onWillPop();
                            if (shouldPop && context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.chevron_back, color: Colors.white, size: 16),
                                SizedBox(width: 4),
                                Text(
                                  'Exit',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Tracking Quality Pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _isTracking
                                  ? const Color(0xFF22C55E).withValues(alpha: 0.4)
                                  : const Color(0xFFF59E0B).withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _isTracking ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _isTracking ? 'VIO Tracking' : 'PDR Sensor Fallback',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Center Reticle / Alignment crosshair
                  Center(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
                      ),
                      child: Center(
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bottom bar of Top Half (Floor lock + Walls count + Tilt)
                  Positioned(
                    bottom: 12,
                    left: 14,
                    right: 14,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Floor Detection Tag
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isFloorDetected ? CupertinoIcons.check_mark_circled_solid : CupertinoIcons.search,
                                color: _isFloorDetected ? const Color(0xFF22C55E) : Colors.white70,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _isFloorDetected ? 'Floor locked' : 'Scanning surfaces...',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),

                        // Tilt warning badge (if tilted down)
                        if (_tilt < _minUprightTilt)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.device_phone_portrait, color: Colors.white, size: 14),
                                SizedBox(width: 4),
                                Text(
                                  'Hold upright',
                                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ==================== BOTTOM HALF: 2D FLOORPLAN & CONTROLS ====================
          Expanded(
            flex: 56,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 18,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    children: [
                      // Drag indicator / header
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE4E4E7),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Quick Telemetry Bar
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('Steps', '$_stepCount'),
                          Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                          _buildStatItem('Distance', '${_pathLength.toStringAsFixed(1)}m'),
                          Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                          _buildStatItem('Nodes', '${_computedNodes.length}'),
                          Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                          _buildStatItem('Heading', '${_heading.toStringAsFixed(0)}°'),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 2D Map Canvas Preview
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFAFAFA),
                                    border: Border.all(color: const Color(0xFFE4E4E7)),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: InteractiveViewer(
                                    minScale: 0.5,
                                    maxScale: 6.0,
                                    child: CustomPaint(
                                      painter: PathMapPainter(
                                        _computedNodes,
                                        _waypoints,
                                      ),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Floating Map Controls (Turn & Waypoint)
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FloatingActionButton.small(
                                    onPressed: _registerTurn,
                                    heroTag: 'turn_btn',
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    elevation: 3,
                                    tooltip: 'Register Turn',
                                    child: const Icon(CupertinoIcons.arrow_turn_up_right, size: 20),
                                  ),
                                  const SizedBox(height: 10),
                                  FloatingActionButton.small(
                                    onPressed: _addMarker,
                                    heroTag: 'marker_btn',
                                    backgroundColor: Colors.black,
                                    foregroundColor: Colors.white,
                                    elevation: 3,
                                    tooltip: 'Add POI / Room',
                                    child: const Icon(CupertinoIcons.placemark, size: 20),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Bottom Action Buttons (Pause/Resume & Save)
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isPaused ? Colors.black : const Color(0xFFF4F4F5),
                                foregroundColor: _isPaused ? Colors.white : Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _togglePause,
                              icon: Icon(
                                _isPaused ? CupertinoIcons.play_arrow_solid : CupertinoIcons.pause_fill,
                                size: 16,
                              ),
                              label: Text(
                                _isPaused ? 'Resume' : 'Pause',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _stepCount > 0 ? _saveMap : null,
                              icon: const Icon(CupertinoIcons.floppy_disk, size: 16),
                              label: const Text(
                                'Save Map',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.black),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF71717A), fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
