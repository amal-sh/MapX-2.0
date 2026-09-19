import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static const double _stepLengthMeters = 0.5;
  static const double _stepMotionThreshold = 0.4;
  static const double _stepCooldownSeconds = 0.7;

  // Steps aren't recorded for this long after mapping starts or resumes
  // (Start/Resume, closing the turn or add-marker dialog): the tap that got us
  // here jostles the phone, and that motion would otherwise count as a step.
  static const double _resumeGraceSeconds = 0.6;

  String _arcoreStatus = 'Checking ARCore support...';
  bool _mapping = false;
  bool _isTurning = false;
  bool _isAddingNode = false;
  bool _isPaused = false;
  bool _isTracking = false;
  bool _isWalking = false;
  
  double _heading = 0;
  double _tilt = 0;
  double _motion = 0;
  double _peakMotion = 0;
  int _features = 0;
  int _minFeatures = 1 << 30;

  static const double _minUprightTilt = 45;

  final List<PathSegment> _segments = [];
  final List<Waypoint> _waypoints = [];
  int _stepCount = 0;
  double _lastStepTime = 0;
  // The grace period is timed from the next pose event after a resume, so it
  // works even before the first event of a session has arrived.
  bool _pendingGrace = false;
  double _resumeAt = 0;

  StreamSubscription? _poseSub;

  @override
  void initState() {
    super.initState();
    _checkArCore();
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
        return 'ARCore is supported and installed on this device.';
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
      _segments.add(PathSegment());
      _waypoints.clear();
      _stepCount = 0;
      _lastStepTime = 0;
      _peakMotion = 0;
      _minFeatures = 1 << 30;
      _isWalking = false;
      _isTurning = false;
      _isPaused = false;
      _pendingGrace = true;
    });

    try {
      await _methodChannel.invokeMethod('startSession');
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _mapping = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not start mapping')),
      );
      return;
    }
    if (!mounted) return;

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
    final tracking = map['tracking'] as bool;
    final heading = (map['heading'] as num).toDouble();
    final tilt = (map['tilt'] as num).toDouble();
    final motion = (map['motion'] as num).toDouble();
    final features = map['features'] as int;

    final now = (map['timestamp'] as int) / 1e9;
    if (_pendingGrace) {
      _resumeAt = now + _resumeGraceSeconds;
      _pendingGrace = false;
    }

    bool stepDetected = false;
    if (!_isTurning &&
        !_isAddingNode &&
        !_isPaused &&
        now >= _resumeAt &&
        motion >= _stepMotionThreshold &&
        (now - _lastStepTime) > _stepCooldownSeconds) {
      stepDetected = true;
      _lastStepTime = now;
      _stepCount++;
      _recordStep(heading);
    }

    setState(() {
      _isTracking = tracking;
      _isWalking = stepDetected || (now - _lastStepTime) < _stepCooldownSeconds;
      _heading = heading;
      _tilt = tilt;
      _motion = motion;
      if (motion > _peakMotion) {
        _peakMotion = motion;
      }
      _features = features;
      _minFeatures = min(_minFeatures, features);
    });
  }

  List<PathNode> get _computedNodes {
    final List<PathNode> nodes = [];
    double currentEast = 0;
    double currentNorth = 0;
    
    nodes.add(PathNode(0, 0, currentEast, currentNorth));
    
    int index = 1;
    for (final segment in _segments) {
      final avgHeadingRad = segment.averageHeading * pi / 180.0;
      for (final step in segment.steps) {
        currentEast += step.length * sin(avgHeadingRad);
        currentNorth += step.length * cos(avgHeadingRad);
        nodes.add(PathNode(index++, segment.averageHeading, currentEast, currentNorth));
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
    return total;
  }

  double get _directDistance {
    final nodes = _computedNodes;
    if (nodes.length < 2) return 0;
    return _horizontalDistance(nodes.last.east, nodes.last.north,
        nodes.first.east, nodes.first.north);
  }

  double _horizontalDistance(double ax, double az, double bx, double bz) {
    return sqrt(pow(ax - bx, 2) + pow(az - bz, 2));
  }

  void _recordStep(double heading) {
    if (_segments.isEmpty) {
      _segments.add(PathSegment());
    }
    _segments.last.steps.add(RawStep(heading, _stepLengthMeters));
  }
  
  Future<void> _registerTurn() async {
    setState(() {
      _isTurning = true;
    });

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Turn'),
        content: const Text('Please physically turn to face your new direction.\n\nTap Ready when you are done turning.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Ready'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    setState(() {
      _segments.add(PathSegment());
      _isTurning = false;
      _pendingGrace = true;
    });
  }

  @override
  void dispose() {
    _poseSub?.cancel();
    super.dispose();
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
      if (!_isPaused) _pendingGrace = true;
    });
  }

  Future<void> _addMarker() async {
    // Steps aren't recorded while the label dialog is open: tapping and
    // typing jostles the phone, which would otherwise be counted as walking.
    setState(() => _isAddingNode = true);
    final TextEditingController controller = TextEditingController();
    final String? label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Marker'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'e.g., Room 101'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
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
        _waypoints.add(Waypoint(_stepCount, label));
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

    final prefs = await SharedPreferences.getInstance();

    final mapData = {
      'segments': _segments.map((s) => s.toJson()).toList(),
      'waypoints': _waypoints.map((w) => w.toJson()).toList(),
      'stepCount': _stepCount,
      'name': widget.mapName,
      'floor': widget.floor,
    };

    // A building's floors share its name, so the floor is part of the key.
    await prefs.setString('map_${widget.mapName}#${widget.floor}', jsonEncode(mapData));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Map "${widget.mapName}" saved successfully!')),
    );

    // Stop mapping and return to dashboard
    Navigator.pop(context, true);
  }

  Future<bool> _onWillPop() async {
    if (_mapping) {
      final shouldPop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Map?'),
          content: const Text('You are currently mapping. Are you sure you want to leave without saving?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
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
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${widget.mapName} · Floor ${widget.floor}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          top: false,
          child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Text(
                _arcoreStatus,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              if (_mapping) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isTracking ? Icons.check_circle : Icons.error,
                      color: _isTracking ? Colors.green : Colors.orange,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(_isTracking ? 'Tracking OK' : 'Tracking lost'),
                    const SizedBox(width: 16),
                    Text(
                      _isPaused ? 'Paused' : (_isWalking ? 'Walking' : 'Still'),
                      style: TextStyle(
                        color: _isPaused
                            ? Colors.orange
                            : (_isWalking ? Colors.green : Colors.grey),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Steps: $_stepCount\n'
                  'heading: ${_heading.toStringAsFixed(0)}°   '
                  'tilt: ${_tilt.toStringAsFixed(0)}°\n'
                  'motion: ${_motion.toStringAsFixed(2)} (Peak: ${_peakMotion.toStringAsFixed(2)})\n'
                  'features: $_features (min '
                  '${_minFeatures == 1 << 30 ? "-" : _minFeatures})',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                if (_tilt < _minUprightTilt)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Hold the phone upright - heading is unreliable',
                      style: TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  'nodes: ${_computedNodes.length}   '
                  'path: ${_pathLength.toStringAsFixed(2)}m   '
                  'direct: ${_directDistance.toStringAsFixed(2)}m',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 13),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          color: Colors.white,
                        ),
                        child: CustomPaint(
                          painter: PathMapPainter(_computedNodes, _waypoints),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                    if (_mapping)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton(
                              onPressed: _registerTurn,
                              heroTag: 'turn_btn',
                              child: const Icon(Icons.turn_right),
                            ),
                            const SizedBox(height: 16),
                            FloatingActionButton(
                              onPressed: _addMarker,
                              heroTag: 'marker_btn',
                              child: const Icon(Icons.add_location_alt),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _mapping ? _togglePause : _startMapping,
                      icon: Icon(
                        (_mapping && !_isPaused) ? Icons.pause : Icons.play_arrow,
                      ),
                      label: Text(
                        !_mapping
                            ? 'Start Mapping'
                            : _isPaused
                                ? 'Resume Mapping'
                                : 'Pause Mapping',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _mapping ? _saveMap : null,
                      icon: const Icon(Icons.save),
                      label: const Text('Save Map'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
