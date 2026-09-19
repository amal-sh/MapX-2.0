import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../logic/live_position_tracker.dart';
import '../logic/route_instructions.dart';
import '../models/map_models.dart';
import '../widgets/navigation/ar_path_painter.dart';
import '../widgets/navigation/ar_world_scanner_overlay.dart';
import '../widgets/path_map_painter.dart';
import 'package:flutter/services.dart';

class MapViewerScreen extends StatefulWidget {
  final String mapKey;
  final String mapName;

  const MapViewerScreen({super.key, required this.mapKey, required this.mapName});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  List<PathSegment> _segments = [];
  List<Waypoint> _waypoints = [];
  int _stepCount = 0;

  Waypoint? _startLocation;
  Waypoint? _destination;
  bool _isArMode = false;
  // True when the AR view uses ARCore (floor detection); false for the
  // sensor-only mode over a plain camera preview.
  bool _useArCore = true;
  static const platform = MethodChannel('mapx/arcore');

  late final AnimationController _pulseController;
  LivePositionTracker? _tracker;
  StreamSubscription<LivePosition>? _positionSub;
  double _liveEast = 0;
  double _liveNorth = 0;
  double _liveHeading = 0;
  double _liveTilt = 90;
  double _liveProgress = 0;
  double _routeTotalDistance = 0;
  List<TurnInstruction> _turnInstructions = const [];
  bool _isFloorDetected = false;
  double _liveCameraHeight = 1.35;
  double _liveFov = 60.0;
  bool _showFloorAnchoredBadge = false;
  Timer? _badgeTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat();
    _loadMapData();
  }

  @override
  void dispose() {
    _badgeTimer?.cancel();
    _positionSub?.cancel();
    _tracker?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadMapData() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(widget.mapKey);

    if (jsonStr != null) {
      final mapData = jsonDecode(jsonStr);
      final List<PathSegment> segments = [];
      if (mapData['segments'] != null) {
        for (var s in mapData['segments']) {
          segments.add(PathSegment.fromJson(s));
        }
      }

      final List<Waypoint> waypoints = [];
      if (mapData['waypoints'] != null) {
        for (var w in mapData['waypoints']) {
          waypoints.add(Waypoint.fromJson(w));
        }
      }

      final stepCount = mapData['stepCount'] as int? ?? 0;
      // Maps recorded without any "Add Marker" taps have no named waypoints,
      // which would otherwise hide the start/destination pickers entirely.
      // Fall back to the walk's own start and end so a route (and AR
      // navigation) is still selectable.
      if (waypoints.isEmpty && stepCount > 0) {
        waypoints.add(Waypoint(0, 'Start'));
        waypoints.add(Waypoint(stepCount, 'End'));
      }

      setState(() {
        _segments = segments;
        _waypoints = waypoints;
        _stepCount = stepCount;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
      });
    }
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
    double dist = 0;
    for (final segment in _segments) {
      for (final step in segment.steps) {
        dist += step.length;
      }
    }
    return dist;
  }

  List<PathNode>? get _routeNodes {
    if (_startLocation == null || _destination == null) return null;
    final nodes = _computedNodes;
    int startIdx = _startLocation!.globalStepIndex;
    int endIdx = _destination!.globalStepIndex;

    if (startIdx >= nodes.length) startIdx = nodes.length - 1;
    if (endIdx >= nodes.length) endIdx = nodes.length - 1;

    if (startIdx <= endIdx) {
      return nodes.sublist(startIdx, endIdx + 1);
    } else {
      return nodes.sublist(endIdx, startIdx + 1).reversed.toList();
    }
  }

  // The line is drawn once there's something to anchor it to: an ARCore floor
  // plane, or immediately in sensor-only mode (assumed camera height).
  bool get _arReady => !_useArCore || _isFloorDetected;

  bool get _canStartNavigation =>
      _startLocation != null && _destination != null && (_routeNodes?.length ?? 0) >= 2;

  Future<void> _startArNavigation() => _startNavigation(useArCore: true);

  /// The same AR line, but sensor-only over a plain camera preview - no
  /// ARCore session, so it works where ARCore can't find a floor.
  Future<void> _startSensorArNavigation() => _startNavigation(useArCore: false);

  Future<void> _startNavigation({required bool useArCore}) async {
    final route = _routeNodes;
    if (route == null || route.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a start and destination below first')),
      );
      return;
    }

    try {
      await platform.invokeMethod('startSession');
      await platform.invokeMethod(useArCore ? 'startArNavigation' : 'startCameraPreview');
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not start navigation')),
        );
      }
      return;
    }

    _isFloorDetected = false;
    _showFloorAnchoredBadge = false;
    _liveEast = route.first.east;
    _liveNorth = route.first.north;
    _liveProgress = 0;
    _turnInstructions = computeTurnInstructions(route);
    _tracker = LivePositionTracker(route: route);
    _routeTotalDistance = _tracker!.totalDistance;
    _positionSub = _tracker!.positions.listen((pos) {
      if (!mounted) return;
      final wasDetected = _isFloorDetected;
      setState(() {
        _liveEast = pos.east;
        _liveNorth = pos.north;
        _liveHeading = pos.headingDegrees;
        _liveTilt = pos.tiltDegrees;
        _liveProgress = pos.progress;
        _isFloorDetected = pos.isFloorDetected;
        _liveCameraHeight = pos.cameraHeight;
        _liveFov = pos.verticalFovDegrees;
      });

      if (!wasDetected && pos.isFloorDetected) {
        setState(() => _showFloorAnchoredBadge = true);
        _badgeTimer?.cancel();
        _badgeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showFloorAnchoredBadge = false);
        });
      }
    });
    _tracker!.start();

    if (mounted) {
      setState(() {
        _useArCore = useArCore;
        _isArMode = true;
      });
    }
  }

  ({String title, String subtitle, IconData icon}) get _currentGuidance {
    final remaining = (_routeTotalDistance - _liveProgress).clamp(0.0, double.infinity);
    if (remaining <= 1.0) {
      return (
        title: 'You have arrived',
        subtitle: _destination?.label ?? '',
        icon: Icons.flag,
      );
    }
    for (final instr in _turnInstructions) {
      if (instr.distance > _liveProgress) {
        final distToTurn = instr.distance - _liveProgress;
        final icon = instr.label.contains('U-turn')
            ? Icons.u_turn_left
            : instr.angleDeltaDeg > 0
                ? Icons.turn_right
                : Icons.turn_left;
        return (
          title: instr.label,
          subtitle: 'in ${distToTurn.toStringAsFixed(0)}m',
          icon: icon,
        );
      }
    }
    return (
      title: 'Continue straight',
      subtitle: 'to ${_destination?.label ?? "destination"}',
      icon: Icons.straight,
    );
  }

  Future<void> _stopNavigation() async {
    _badgeTimer?.cancel();
    _isFloorDetected = false;
    _showFloorAnchoredBadge = false;
    await _positionSub?.cancel();
    _positionSub = null;
    _tracker?.dispose();
    _tracker = null;
    try {
      await platform.invokeMethod(_useArCore ? 'stopArNavigation' : 'stopCameraPreview');
    } catch (e) {
      debugPrint("AR Error: $e");
    }
    if (mounted) setState(() => _isArMode = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isArMode) {
      final route = _routeNodes ?? const <PathNode>[];
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Glowing route line anchored to the real floor
            if (_arReady)
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: ArPathPainter(
                    route: route,
                    liveEast: _liveEast,
                    liveNorth: _liveNorth,
                    headingDegrees: _liveHeading,
                    tiltDegrees: _liveTilt,
                    animationProgress: _pulseController.value,
                    startLabel: _startLocation?.label ?? 'Start',
                    destinationLabel: _destination?.label ?? 'Destination',
                    cameraHeight: _liveCameraHeight,
                    verticalFovDegrees: _liveFov,
                    liveProgress: _liveProgress,
                  ),
                ),
              ),

            // Scanning HUD loader while ARCore detects floor plane
            if (_useArCore && !_isFloorDetected)
              ArWorldScannerOverlay(
                onCancel: _stopNavigation,
              ),

            // Back button when in AR navigation mode
            if (_arReady)
              Positioned(
                top: 50,
                left: 20,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30),
                  onPressed: _stopNavigation,
                ),
              ),

            // Real-time floor height and orientation HUD
            if (_useArCore && _isFloorDetected)
              Positioned(
                top: 50,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.anchor, color: Color(0xFF10B981), size: 14),
                      const SizedBox(width: 6),
                      Text(
                        'Floor ${_liveCameraHeight.toStringAsFixed(2)}m',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),

            // Temporary "Floor Anchored in 3D Space" confirmation badge
            if (_showFloorAnchoredBadge)
              Positioned(
                top: 100,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF10B981), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withValues(alpha: 0.35),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Floor Anchored in 3D Space',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_arReady) ...[
              Positioned(
                top: MediaQuery.of(context).padding.top + 100,
                left: 16,
                right: 16,
                child: _GuidanceBanner(guidance: _currentGuidance),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 24,
                child: _DistanceBar(
                  remainingMeters: (_routeTotalDistance - _liveProgress).clamp(0.0, double.infinity),
                  totalMeters: _routeTotalDistance,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final nodes = _computedNodes;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mapName),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'AR Navigation (without ARCore)',
            onPressed: _startSensorArNavigation,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  width: double.infinity,
                  color: Colors.teal.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Stat(label: 'Steps', value: '$_stepCount'),
                      _Stat(label: 'Nodes', value: '${nodes.length}'),
                      _Stat(label: 'Distance', value: '${_pathLength.toStringAsFixed(1)}m'),
                    ],
                  ),
                ),
                if (_waypoints.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButton<Waypoint>(
                            isExpanded: true,
                            hint: const Text('Start'),
                            value: _startLocation,
                            items: _waypoints.map((w) {
                              return DropdownMenuItem(
                                value: w,
                                child: Text(w.label),
                              );
                            }).toList(),
                            onChanged: (val) => setState(() => _startLocation = val),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<Waypoint>(
                            isExpanded: true,
                            hint: const Text('Destination'),
                            value: _destination,
                            items: _waypoints.map((w) {
                              return DropdownMenuItem(
                                value: w,
                                child: Text(w.label),
                              );
                            }).toList(),
                            onChanged: (val) => setState(() => _destination = val),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: InteractiveViewer(
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    minScale: 0.1,
                    maxScale: 10.0,
                    child: Center(
                      child: CustomPaint(
                        painter: PathMapPainter(nodes, _waypoints, routeNodes: _routeNodes),
                        // We give the painter a fixed size canvas, and InteractiveViewer handles the zooming.
                        // However, PathMapPainter currently scales to the canvas size.
                        // Let's pass a huge size and let it draw in the middle, then InteractiveViewer zooms it.
                        size: const Size(2000, 2000),
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  color: Colors.white,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Pinch to zoom, drag to pan', style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _canStartNavigation ? _startArNavigation : null,
                            icon: const Icon(Icons.view_in_ar),
                            label: const Text('Start Navigation'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              ],
            ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.teal)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

/// Turn-by-turn guidance card, shown at the top of the AR view - a
/// Google-Maps-style "next instruction" banner (icon, instruction, distance
/// to it) rather than the plain heading readout.
class _GuidanceBanner extends StatelessWidget {
  final ({String title, String subtitle, IconData icon}) guidance;
  const _GuidanceBanner({required this.guidance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: Color(0xFF00E5FF), shape: BoxShape.circle),
            child: Icon(guidance.icon, color: const Color(0xFF0F172A), size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  guidance.title,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (guidance.subtitle.isNotEmpty)
                  Text(guidance.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Remaining-distance/steps bar, shown at the bottom of the AR view -
/// Google-Maps-style trip summary.
class _DistanceBar extends StatelessWidget {
  final double remainingMeters;
  final double totalMeters;
  const _DistanceBar({required this.remainingMeters, required this.totalMeters});

  @override
  Widget build(BuildContext context) {
    final stepsRemaining = (remainingMeters / LivePositionTracker.stepLengthMeters).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _distanceStat('${remainingMeters.toStringAsFixed(0)}m', 'remaining'),
          Container(width: 1, height: 32, color: Colors.white24),
          _distanceStat('$stepsRemaining', 'steps left'),
          Container(width: 1, height: 32, color: Colors.white24),
          _distanceStat('${totalMeters.toStringAsFixed(0)}m', 'total'),
        ],
      ),
    );
  }

  Widget _distanceStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
      ],
    );
  }
}
