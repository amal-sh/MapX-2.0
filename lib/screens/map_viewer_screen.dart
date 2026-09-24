import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/depth_occlusion_manager.dart';
import '../logic/floor_graph.dart';
import '../logic/floor_route_planner.dart';
import '../logic/relocalization_manager.dart';
import '../logic/route_instructions.dart';
import '../logic/route_segment_manager.dart';
import '../logic/spatial_sensor_fusion.dart';
import '../logic/wall_collision_validator.dart';
import '../models/floor_map_data.dart';
import '../models/map_models.dart';
import '../widgets/navigation/ar_mini_map.dart';
import '../widgets/navigation/ar_path_painter.dart';
import '../widgets/navigation/ar_world_scanner_overlay.dart';
import '../widgets/navigation/off_path_direction_prompt.dart';
import '../widgets/path_map_painter.dart';
import 'map_editor_screen.dart';

class MapViewerScreen extends StatefulWidget {
  final String mapKey;
  final String mapName;

  const MapViewerScreen({super.key, required this.mapKey, required this.mapName});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  List<Waypoint> _waypoints = [];
  List<WallSegment> _walls = [];
  List<WallSegment> _detectedWalls = [];
  int _stepCount = 0;
  int _currentFloor = 0;

  // Every mapped floor of this building. The fields above always hold the
  // floor currently shown (see _showFloor).
  Map<int, FloorMapData> _floors = {};
  FloorGraph? _graph;

  // Cross-floor trips: which connector type to route through, and the legs
  // being walked (frozen when navigation starts).
  bool _preferLift = true;
  List<TripLeg>? _activeLegs;
  int _legIndex = 0;
  // Reached the stairs/lift at the end of a leg; waiting for the walker to
  // confirm they're on the next floor.
  bool _atConnector = false;

  Waypoint? _startLocation;
  Waypoint? _destination;
  bool _isArMode = false;
  bool _useArCore = true;
  static const platform = MethodChannel('mapx/arcore');

  late final AnimationController _pulseController;
  SpatialSensorFusion? _fusionEngine;
  StreamSubscription<FusedPosition>? _fusionSub;
  RelocalizationManager? _relocalizer;
  RouteSegmentManager? _segmentManager;
  final DepthOcclusionManager _depthOcclusionManager = DepthOcclusionManager();

  double _liveEast = 0;
  double _liveNorth = 0;
  double _liveHeading = 0;
  double _liveTilt = 90;
  double _liveProgress = 0;
  double _routeTotalDistance = 0;
  List<TurnInstruction> _turnInstructions = const [];

  bool _isFloorDetected = false;
  double _floorConfidence = 0.0;
  double _liveCameraHeight = 1.35;
  double _liveFov = 60.0;
  TrackingConfidence _trackingConfidence = TrackingConfidence.medium;
  bool _isDrifting = false;
  String _driftReason = '';

  // Off-path heading detection
  bool _isFacingPath = true;
  double _offPathAngleDelta = 0.0;
  String _turnDirection = 'straight';
  bool _isAtTurn = false;

  // Progressive path reveal
  double _revealedEndDistance = 0.0;

  // Depth occlusion sampling timer
  Timer? _depthQueryTimer;

  bool _showFloorAnchoredBadge = false;
  Timer? _badgeTimer;

  DateTime? _arrivalZoneEntryTime;
  bool _hasArrivedAtDestination = false;

  Timer? _navScreenKeepAliveTimer;
  static const Duration _navScreenInactivityTimeout = Duration(minutes: 8);

  void _resetNavScreenKeepAliveTimer() {
    if (!_isArMode) return;
    try {
      platform.invokeMethod('setKeepScreenOn', {'enabled': true});
    } catch (_) {}
    _navScreenKeepAliveTimer?.cancel();
    _navScreenKeepAliveTimer = Timer(_navScreenInactivityTimeout, () {
      try {
        platform.invokeMethod('setKeepScreenOn', {'enabled': false});
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat();
    _loadMapData();
  }

  @override
  void dispose() {
    _navScreenKeepAliveTimer?.cancel();
    try {
      platform.invokeMethod('setKeepScreenOn', {'enabled': false});
    } catch (_) {}
    _badgeTimer?.cancel();
    _depthQueryTimer?.cancel();
    _depthOcclusionManager.clear();
    _fusionSub?.cancel();
    _fusionEngine?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadMapData() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(widget.mapKey);

    if (jsonStr == null) {
      setState(() => _isLoading = false);
      return;
    }

    final openedData = jsonDecode(jsonStr) as Map;
    final opened = FloorMapData.fromJson(widget.mapKey, openedData);
    final floors = <int, FloorMapData>{opened.floor: opened};
    // Other floors of the same building (older maps without a stored name
    // can't be matched, so they stay single-floor).
    final building = openedData['name'] as String?;
    if (building != null) {
      for (final key in prefs.getKeys().where((k) => k.startsWith('map_') && k != widget.mapKey)) {
        final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
        if (data['name'] != building) continue;
        final floor = FloorMapData.fromJson(key, data);
        floors.putIfAbsent(floor.floor, () => floor);
      }
    }

    // A selected place may have been renamed or deleted in the editor.
    final allPlaces = {for (final f in floors.values) ...f.waypoints};
    Waypoint? defaultStart = allPlaces.contains(_startLocation) ? _startLocation : null;
    Waypoint? defaultDest = allPlaces.contains(_destination) ? _destination : null;
    if (defaultStart == null && opened.waypoints.isNotEmpty) {
      defaultStart = opened.waypoints.first;
    }
    if (defaultDest == null && opened.waypoints.length >= 2) {
      defaultDest = opened.waypoints.last;
    }

    setState(() {
      _floors = floors;
      _startLocation = defaultStart;
      _destination = defaultDest;
      _showFloor(defaultStart?.floor ?? opened.floor);
      _isLoading = false;
    });
  }

  /// Makes [floor] the one drawn and navigated on.
  void _showFloor(int floor) {
    final data = _floors[floor];
    if (data == null) return;
    _waypoints = data.waypoints;
    _walls = data.walls;
    _stepCount = data.stepCount;
    _graph = data.graph;
    _currentFloor = floor;
  }

  /// Every place on every floor, lowest floor first.
  List<Waypoint> get _allWaypoints {
    final floors = _floors.keys.toList()..sort();
    return [for (final f in floors) ..._floors[f]!.waypoints];
  }

  String _placeName(Waypoint w) =>
      _floors.length > 1 ? '${w.displayName} · Floor ${w.floor}' : w.displayName;

  List<TripLeg>? get _plannedLegs {
    if (_startLocation == null || _destination == null) return null;
    return FloorRoutePlanner.plan(
      graphs: {for (final e in _floors.entries) e.key: e.value.graph},
      waypointsByFloor: {for (final e in _floors.entries) e.key: e.value.waypoints},
      start: _startLocation!,
      destination: _destination!,
      preferLift: _preferLift,
    );
  }

  /// The leg on the floor being shown: the one being walked while
  /// navigating, otherwise the planned leg on this floor (if any).
  TripLeg? get _displayLeg {
    if (_activeLegs != null) {
      return _legIndex < _activeLegs!.length ? _activeLegs![_legIndex] : null;
    }
    return _plannedLegs?.where((l) => l.floor == _currentFloor).firstOrNull;
  }

  bool get _hasNextLeg => _activeLegs != null && _legIndex < _activeLegs!.length - 1;

  List<PathNode> get _computedNodes => _graph?.nodes ?? const [];

  /// Total length of the floor's walkable paths, walked and drawn.
  double get _pathLength {
    final graph = _graph;
    if (graph == null) return 0;
    var dist = 0.0;
    for (final (a, b) in graph.edges) {
      dist += sqrt(pow(graph.nodes[a].east - graph.nodes[b].east, 2) +
          pow(graph.nodes[a].north - graph.nodes[b].north, 2));
    }
    return dist;
  }

  List<PathNode>? get _routeNodes {
    final leg = _displayLeg;
    if (leg == null || leg.floor != _currentFloor) return null;
    final graph = _graph;
    if (graph == null) return null;
    // Shortest way through the floor's paths, including drawn shortcuts.
    final path = graph.shortestPath(leg.from.globalStepIndex, leg.to.globalStepIndex);
    if (path == null) return null;
    final rawSublist = [for (final i in path) graph.nodes[i]];

    // Explicitly reconstruct the active navigation route so that every node has
    // the correct directional heading pointing along the route toward the destination.
    // This ensures that whether navigating Start -> Destination or Destination -> Start,
    // the initial node and all subsequent nodes have valid forward traversal headings.
    final List<PathNode> directedNodes = [];
    for (int i = 0; i < rawSublist.length; i++) {
      final current = rawSublist[i];
      double headingDeg;
      if (i < rawSublist.length - 1) {
        double? foundHeading;
        for (int j = i + 1; j < rawSublist.length; j++) {
          final fNext = rawSublist[j];
          final fde = fNext.east - current.east;
          final fdn = fNext.north - current.north;
          if (sqrt(fde * fde + fdn * fdn) > 0.001) {
            foundHeading = (atan2(fde, fdn) * 180.0 / pi + 360.0) % 360.0;
            break;
          }
        }
        if (foundHeading != null) {
          headingDeg = foundHeading;
        } else if (directedNodes.isNotEmpty) {
          headingDeg = directedNodes.last.heading;
        } else {
          headingDeg = current.heading;
        }
      } else if (directedNodes.isNotEmpty) {
        headingDeg = directedNodes.last.heading;
      } else {
        headingDeg = current.heading;
      }

      directedNodes.add(PathNode(
        i,
        headingDeg,
        current.east,
        current.north,
        floor: current.floor,
        elevation: current.elevation,
      ));
    }
    return directedNodes;
  }

  bool get _arReady => !_useArCore || (_isFloorDetected && _floorConfidence >= 0.35);

  bool get _canStartNavigation {
    final legs = _plannedLegs;
    if (legs == null) return false;
    return legs.length > 1 || legs.first.from.globalStepIndex != legs.first.to.globalStepIndex;
  }

  Future<void> _startArNavigation() => _startNavigation(useArCore: true);
  Future<void> _startSensorArNavigation() => _startNavigation(useArCore: false);

  Future<void> _startNavigation({required bool useArCore}) async {
    final legs = _plannedLegs;
    if (legs == null || !_canStartNavigation) {
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

    _activeLegs = legs;
    _legIndex = 0;
    _showFloor(legs.first.floor);
    _isFloorDetected = false;
    _floorConfidence = 0.0;
    _showFloorAnchoredBadge = false;
    _beginLeg();

    if (mounted) {
      setState(() {
        _useArCore = useArCore;
        _isArMode = true;
      });
      _resetNavScreenKeepAliveTimer();
    }
  }

  /// Starts tracking along the current leg. The AR session keeps running
  /// across legs; each leg gets a fresh fusion engine, which calibrates
  /// itself to the leg's first node (the stairs/lift on a new floor).
  void _beginLeg() {
    _atConnector = false;
    _isFacingPath = true;
    _hasArrivedAtDestination = false;
    _arrivalZoneEntryTime = null;
    _depthQueryTimer?.cancel();
    _depthOcclusionManager.clear();
    _routeTotalDistance = 0;
    _liveProgress = 0.0;

    final route = _routeNodes;
    if (route == null || route.length < 2) {
      // Nothing to walk on this floor: the trip starts at the stairs/lift, or
      // ends right at the one just taken.
      if (_hasNextLeg) {
        _atConnector = true;
      } else {
        _hasArrivedAtDestination = true;
      }
      return;
    }

    // Reset tracking state completely for a clean start
    _detectedWalls = [];
    _isDrifting = false;
    _driftReason = '';
    _trackingConfidence = TrackingConfidence.medium;

    // Explicitly anchor initial physical position to the starting node coordinate
    _liveEast = route.first.east;
    _liveNorth = route.first.north;
    _liveProgress = 0.0;
    _liveHeading = route.first.heading;
    _turnInstructions = computeTurnInstructions(route);

    _segmentManager = RouteSegmentManager(route: route);
    _revealedEndDistance = _segmentManager!.computeRevealedEndDistance(0);
    _isFacingPath = true;
    _offPathAngleDelta = 0.0;
    _turnDirection = 'straight';
    _depthOcclusionManager.clear();

    _depthQueryTimer?.cancel();
    _depthQueryTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      _triggerDepthOcclusionCheck();
    });

    _fusionEngine = SpatialSensorFusion(
      route: route,
      mappedWalls: _walls,
    );
    _routeTotalDistance = _fusionEngine!.totalRouteDistance;

    _relocalizer = RelocalizationManager(
      route: route,
      walls: _walls,
      fusionEngine: _fusionEngine!,
      onRelocalized: (event) {
        debugPrint("Relocalized: ${event.reason}");
      },
    );

    _fusionSub = _fusionEngine!.positions.listen((pos) {
      if (!mounted) return;
      final wasDetected = _isFloorDetected;

      final targetBearing = _segmentManager?.sampleTargetBearing(
        pos.progressMeters,
        userEast: pos.east,
        userNorth: pos.north,
      ) ?? pos.headingDegrees;

      final facingEval = RouteSegmentManager.evaluateFacing(
        userHeadingDeg: pos.headingDegrees,
        targetBearingDeg: targetBearing,
        thresholdDeg: 35.0,
      );

      final revealedEnd = _segmentManager?.computeRevealedEndDistance(pos.progressMeters) ?? (pos.progressMeters + 8.0);

      final currentSeg = _segmentManager?.getSegmentForProgress(pos.progressMeters);
      final upcomingTurn = currentSeg?.upcomingTurn;
      final distToTurn = upcomingTurn != null ? (upcomingTurn.distance - pos.progressMeters) : null;
      final isAtTurn = distToTurn != null && distToTurn.abs() <= 0.6;

      setState(() {
        _liveEast = pos.east;
        _liveNorth = pos.north;
        _liveHeading = pos.headingDegrees;
        _liveTilt = pos.tiltDegrees;
        _liveProgress = pos.progressMeters;
        _isFloorDetected = pos.isFloorDetected;
        _floorConfidence = pos.floorConfidence;
        _liveCameraHeight = pos.floorHeight;
        _liveFov = pos.cameraFovY;
        _trackingConfidence = pos.confidence;
        _isDrifting = pos.isDrifting;
        _driftReason = pos.driftReason;
        _isFacingPath = facingEval.isFacingPath;
        _offPathAngleDelta = facingEval.deltaDegrees;
        _turnDirection = facingEval.turnDirection;
        _isAtTurn = isAtTurn;
        _revealedEndDistance = revealedEnd;

        if (pos.detectedWalls.isNotEmpty) {
          _detectedWalls = pos.detectedWalls;
        }
      });

      // Periodic relocalization checking if drifting
      if (pos.isDrifting) {
        _relocalizer?.checkAndRelocalize(pos);
      }

      if (!wasDetected && pos.isFloorDetected && pos.floorConfidence >= 0.4) {
        setState(() => _showFloorAnchoredBadge = true);
        _badgeTimer?.cancel();
        _badgeTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showFloorAnchoredBadge = false);
        });
      }

      _resetNavScreenKeepAliveTimer();
    });

    _fusionEngine!.start();
  }

  /// The walker confirmed they took the stairs/lift: switch to the next
  /// floor's map and continue from the matching stairs/lift there.
  Future<void> _advanceLeg() async {
    if (!_hasNextLeg) return;
    await _fusionSub?.cancel();
    _fusionSub = null;
    _fusionEngine?.dispose();
    _fusionEngine = null;
    _relocalizer = null;
    _segmentManager = null;
    if (!mounted) return;

    _legIndex++;
    _showFloor(_activeLegs![_legIndex].floor);
    _beginLeg();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Now navigating on Floor $_currentFloor')),
    );
  }

  ({String title, String subtitle, IconData icon}) get _connectorGuidance {
    final exit = _activeLegs![_legIndex].to;
    final nextFloor = _activeLegs![_legIndex + 1].floor;
    final isLift = exit.category == Waypoint.liftCategory;
    return (
      title: 'Take ${exit.displayName} to Floor $nextFloor',
      subtitle: "Tap \"I'm on Floor $nextFloor\" when you get there",
      icon: isLift ? Icons.elevator_outlined : Icons.stairs_outlined,
    );
  }

  void _triggerDepthOcclusionCheck() {
    if (!_useArCore || !_isArMode || !_arReady) return;
    final route = _routeNodes;
    if (route == null || route.isEmpty) return;

    final queries = <WaypointDepthQuery>[];
    final dest = route.last;

    final pitch = (_liveTilt - 90.0) * pi / 180.0;
    final fovV = (_liveFov.clamp(35.0, 90.0)) * pi / 180.0;
    final heading = _liveHeading * pi / 180.0;

    final cosH = cos(heading);
    final sinH = sin(heading);
    final cosP = cos(pitch);
    final sinP = sin(pitch);

    final fx = sinH * cosP;
    final fy = sinP;
    final fz = cosH * cosP;

    final rx = cosH;
    final rz = -sinH;
    final ux = -sinH * sinP;
    final uy = cosP;
    final uz = -cosH * sinP;

    final effCamHeight = _liveCameraHeight.clamp(0.4, 2.5);

    void addCandidate(int id, double east, double north) {
      final dx = east - _liveEast;
      final dy = -effCamHeight;
      final dz = north - _liveNorth;

      final zCam = dx * fx + dy * fy + dz * fz;
      if (zCam < 0.2 || zCam > 20.0) return;

      final xCam = dx * rx + dz * rz;
      final yCam = dx * ux + dy * uy + dz * uz;

      final tanHalfFov = tan(fovV * 0.5);
      final normX = (0.5 + (xCam / zCam) / (2 * tanHalfFov)).clamp(0.05, 0.95);
      final normY = (0.5 - (yCam / zCam) / (2 * tanHalfFov)).clamp(0.05, 0.95);

      queries.add(WaypointDepthQuery(
        id: id,
        screenX: normX,
        screenY: normY,
        expectedDistance: zCam,
        east: east,
        north: north,
      ));
    }

    addCandidate(dest.index, dest.east, dest.north);

    for (final tp in _segmentManager?.turnPoints ?? const <RouteTurnPoint>[]) {
      if (tp.nodeIndex < route.length) {
        final node = route[tp.nodeIndex];
        addCandidate(node.index, node.east, node.north);
      }
    }

    if (queries.isNotEmpty) {
      _depthOcclusionManager.queryDepthOcclusions(queries).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  ({String title, String subtitle, IconData icon}) get _currentGuidance {
    if (_hasArrivedAtDestination) {
      return (
        title: 'You have arrived',
        subtitle: _destination?.label ?? '',
        icon: CupertinoIcons.flag_fill,
      );
    }

    if (_atConnector) return _connectorGuidance;

    if (!_isFacingPath) {
      return (
        title: _turnDirection == 'left'
            ? 'Turn Left ${_offPathAngleDelta.abs().toStringAsFixed(0)}°'
            : 'Turn Right ${_offPathAngleDelta.abs().toStringAsFixed(0)}°',
        subtitle: 'Face towards path to continue',
        icon: _turnDirection == 'left' ? CupertinoIcons.arrow_turn_up_left : CupertinoIcons.arrow_turn_up_right,
      );
    }

    if (_trackingConfidence == TrackingConfidence.lost) {
      return (
        title: 'Tracking Degraded',
        subtitle: 'Point camera at floor and move slowly',
        icon: CupertinoIcons.exclamationmark_triangle_fill,
      );
    }

    // 5-FACTOR SPATIAL ARRIVAL VALIDATION
    final dest = _routeNodes?.last;
    if (dest != null) {
      final spatialDist = sqrt(pow(dest.east - _liveEast, 2) + pow(dest.north - _liveNorth, 2));
      final remainingAlongRoute = (_routeTotalDistance - _liveProgress).clamp(0.0, double.infinity);
      final allWalls = [..._walls, ..._detectedWalls];

      final isLineOfSightClear = !WallCollisionValidator.isLineOfSightBlocked(
        startEast: _liveEast,
        startNorth: _liveNorth,
        targetEast: dest.east,
        targetNorth: dest.north,
        walls: allWalls,
      );

      final isTrackingReliable = _trackingConfidence != TrackingConfidence.low &&
          _trackingConfidence != TrackingConfidence.lost;

      final hasMovedFromStart = _routeTotalDistance < 1.5 || _liveProgress >= 0.8;
      final isInArrivalZone = hasMovedFromStart &&
          spatialDist <= 1.2 &&
          remainingAlongRoute <= 1.5 &&
          isLineOfSightClear &&
          isTrackingReliable;

      if (isInArrivalZone) {
        _arrivalZoneEntryTime ??= DateTime.now();
        if (DateTime.now().difference(_arrivalZoneEntryTime!).inMilliseconds >= 800) {
          if (_hasNextLeg) {
            _atConnector = true;
            return _connectorGuidance;
          }
          _hasArrivedAtDestination = true;
          return (
            title: 'You have arrived',
            subtitle: _destination?.label ?? '',
            icon: CupertinoIcons.flag_fill,
          );
        }
      } else {
        _arrivalZoneEntryTime = null;
      }
    }

    for (final instr in _turnInstructions) {
      if (instr.distance > _liveProgress) {
        final distToTurn = instr.distance - _liveProgress;
        final icon = instr.label.contains('U-turn')
            ? CupertinoIcons.arrow_uturn_left
            : instr.angleDeltaDeg > 0
                ? CupertinoIcons.arrow_turn_up_right
                : CupertinoIcons.arrow_turn_up_left;
        if (distToTurn <= 0.6) {
          return (
            title: '${instr.label} now',
            subtitle: 'Turn ${instr.angleDeltaDeg > 0 ? "right" : "left"} here',
            icon: icon,
          );
        }

        return (
          title: instr.label,
          subtitle: 'in ${distToTurn.toStringAsFixed(0)}m',
          icon: icon,
        );
      }
    }

    return (
      title: 'Continue straight',
      subtitle: 'to ${_displayLeg?.to.displayName ?? _destination?.label ?? "destination"}',
      icon: CupertinoIcons.arrow_up,
    );
  }

  Future<void> _openEditor() async {
    final floor = _floors[_currentFloor];
    if (floor == null) return;
    final title = floor.building == null ? widget.mapName : '${floor.building} · Floor ${floor.floor}';
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => MapEditorScreen(mapKey: floor.key, title: title)),
    );
    if (saved == true && mounted) {
      await _loadMapData();
      if (mounted) _showFloor(floor.floor);
      if (mounted) setState(() {});
    }
  }

  /// Under the pickers for a cross-floor trip: the lift/stairs choice and the
  /// planned route, or why there isn't one.
  Widget _buildFloorChangeSummary() {
    final legs = _plannedLegs;
    const muted = TextStyle(fontSize: 12, color: Color(0xFF71717A));
    if (legs == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'No stairs or lift links Floor ${_startLocation!.floor} and Floor ${_destination!.floor}. '
          'While mapping, mark the same stairs/lift with the same name on both floors.',
          style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C)),
        ),
      );
    }
    final via = legs.first.to;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Lift'), icon: Icon(Icons.elevator_outlined, size: 16)),
              ButtonSegment(value: false, label: Text('Stairs'), icon: Icon(Icons.stairs_outlined, size: 16)),
            ],
            selected: {_preferLift},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() => _preferLift = s.first),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Via ${via.displayName} to Floor ${legs.last.floor}',
              style: muted,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _stopNavigation() async {
    _navScreenKeepAliveTimer?.cancel();
    _badgeTimer?.cancel();
    _depthQueryTimer?.cancel();
    _depthOcclusionManager.clear();
    _isFloorDetected = false;
    _floorConfidence = 0.0;
    _showFloorAnchoredBadge = false;
    final bool didArrive = _hasArrivedAtDestination;
    _hasArrivedAtDestination = false;
    _arrivalZoneEntryTime = null;
    _isFacingPath = true;
    _isDrifting = false;
    _driftReason = '';
    _detectedWalls = [];
    await _fusionSub?.cancel();
    _fusionSub = null;
    _fusionEngine?.dispose();
    _fusionEngine = null;
    _relocalizer = null;
    _segmentManager = null;
    _activeLegs = null;
    _legIndex = 0;
    _atConnector = false;
    try {
      await platform.invokeMethod('setKeepScreenOn', {'enabled': false});
      await platform.invokeMethod(_useArCore ? 'stopArNavigation' : 'stopCameraPreview');
      await platform.invokeMethod('stopSession');
    } catch (e) {
      debugPrint("AR Error: $e");
    }

    if (mounted) {
      setState(() {
        _isArMode = false;
        _liveProgress = 0.0;
        // If user arrived at destination, advance start to that destination for the next navigation
        if (didArrive && _destination != null) {
          _startLocation = _destination;
          _destination = null;
        }
        _showFloor(_startLocation?.floor ?? _currentFloor);
        if (_startLocation != null) {
          final nodes = _computedNodes;
          final idx = _startLocation!.globalStepIndex.clamp(0, nodes.isEmpty ? 0 : nodes.length - 1);
          if (nodes.isNotEmpty) {
            _liveEast = nodes[idx].east;
            _liveNorth = nodes[idx].north;
            _liveHeading = nodes[idx].heading;
          }
        }
      });
      // Refresh map data to ensure latest waypoints are in sync
      _loadMapData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isArMode) {
      final route = _routeNodes ?? const <PathNode>[];
      final allWalls = [..._walls, ..._detectedWalls];

      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _resetNavScreenKeepAliveTimer(),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
          children: [
            // Glowing route line strictly anchored to the real floor
            if (_arReady && route.length >= 2)
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
                    startLabel: _displayLeg?.from.displayName ?? 'Start',
                    destinationLabel: _displayLeg?.to.displayName ?? 'Destination',
                    cameraHeight: _liveCameraHeight,
                    verticalFovDegrees: _liveFov,
                    liveProgress: _liveProgress,
                    walls: allWalls,
                    isFloorLocked: _arReady,
                    currentFloor: _currentFloor,
                    isFacingPath: _isFacingPath,
                    maxRevealedDistance: _revealedEndDistance,
                    waypointOcclusions: _depthOcclusionManager.occlusionStates,
                  ),
                ),
              ),

            // Scanning HUD loader while ARCore detects floor plane
            if (_useArCore && !_arReady)
              ArWorldScannerOverlay(
                floorConfidence: _floorConfidence,
                onCancel: _stopNavigation,
              ),

            // Back button when in AR navigation mode
            if (_arReady)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 14,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(CupertinoIcons.back, color: Colors.white, size: 24),
                    onPressed: _stopNavigation,
                  ),
                ),
              ),

            // Top Status Bar: Floor height and tracking confidence
            if (_useArCore && _isFloorDetected)
              Positioned(
                top: MediaQuery.of(context).padding.top + 14,
                left: 64,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.pin_fill,
                        color: Colors.white,
                        size: 13,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Floor ${_liveCameraHeight.toStringAsFixed(2)}m',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),

            // Persistent top-right Mini-Map Overlay
            if (_arReady && route.length >= 2)
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                right: 14,
                child: ArMiniMap(
                  route: route,
                  walls: allWalls,
                  turnPoints: _segmentManager?.turnPoints ?? const [],
                  userEast: _liveEast,
                  userNorth: _liveNorth,
                  userHeadingDegrees: _liveHeading,
                  revealedEndDistance: _revealedEndDistance,
                  currentProgress: _liveProgress,
                ),
              ),

            // Off-Path Direction Prompt: guides user when facing away from path
            if (_arReady && !_isFacingPath)
              Positioned.fill(
                child: IgnorePointer(
                  child: OffPathDirectionPrompt(
                    deltaDegrees: _offPathAngleDelta,
                    turnDirection: _turnDirection,
                    isAtTurn: _isAtTurn,
                  ),
                ),
              ),

            // Subtle Drift / Relocalization indicator
            if (_isDrifting)
              Positioned(
                top: MediaQuery.of(context).padding.top + 50,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.arrow_2_circlepath, color: Colors.white, size: 14),
                        const SizedBox(width: 8),
                        Text(
                          _driftReason.isNotEmpty ? _driftReason : 'Calibrating tracking...',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
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
                      color: Colors.black.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white, width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.15),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.checkmark_circle_fill, color: Colors.white, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Floor Anchored in 3D Space',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (_arReady) ...[
              // Next turn guidance banner (shown when aligned with path)
              if (_isFacingPath)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 176,
                  left: 16,
                  right: 16,
                  child: _GuidanceBanner(guidance: _currentGuidance),
                ),

              // Took the stairs/lift: confirm arrival on the next floor. Also
              // offered when close, in case tracking under-counts the walk.
              if (_hasNextLeg && (_atConnector || _routeTotalDistance - _liveProgress <= 3.0))
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 110,
                  left: 24,
                  right: 24,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 6,
                    ),
                    icon: Icon(
                      _activeLegs![_legIndex].to.category == Waypoint.liftCategory
                          ? Icons.elevator_outlined
                          : Icons.stairs_outlined,
                      size: 20,
                    ),
                    label: Text(
                      "I'm on Floor ${_activeLegs![_legIndex + 1].floor}",
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    onPressed: _advanceLeg,
                  ),
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
        ),
      );
    }

    final nodes = _computedNodes;
    return Scaffold(
      floatingActionButton: _isLoading || _floors[_currentFloor] == null
          ? null
          : Padding(
              // Clear the Start AR Navigation button below the map.
              padding: const EdgeInsets.only(bottom: 76),
              child: FloatingActionButton(
                heroTag: 'edit_map',
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                tooltip: 'Edit map',
                onPressed: _openEditor,
                child: const Icon(Icons.edit_outlined),
              ),
            ),
      appBar: AppBar(
        leading: CupertinoNavigationBarBackButton(
          color: Colors.black,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.mapName),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.videocam),
            tooltip: 'AR Navigation (without ARCore)',
            onPressed: _startSensorArNavigation,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFAFAFA),
                    border: Border(bottom: BorderSide(color: Color(0xFFE4E4E7))),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Stat(label: 'Steps', value: '$_stepCount'),
                      Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                      _Stat(label: 'Nodes', value: '${nodes.length}'),
                      Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                      _Stat(label: 'Distance', value: '${_pathLength.toStringAsFixed(1)}m'),
                      Container(width: 1, height: 24, color: const Color(0xFFE4E4E7)),
                      _Stat(label: 'Floor', value: '$_currentFloor'),
                    ],
                  ),
                ),
                if (_allWaypoints.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(bottom: BorderSide(color: Color(0xFFE4E4E7))),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<Waypoint>(
                                key: ValueKey(('start', _startLocation)),
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Start'),
                                initialValue: _startLocation,
                                items: _allWaypoints
                                    .map((w) => DropdownMenuItem(value: w, child: Text(_placeName(w), overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: (val) => setState(() {
                                  _startLocation = val;
                                  if (val != null) _showFloor(val.floor);
                                }),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: DropdownButtonFormField<Waypoint>(
                                key: ValueKey(('dest', _destination)),
                                isExpanded: true,
                                decoration: const InputDecoration(labelText: 'Destination'),
                                initialValue: _destination,
                                items: _allWaypoints
                                    .map((w) => DropdownMenuItem(value: w, child: Text(_placeName(w), overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: (val) => setState(() => _destination = val),
                              ),
                            ),
                          ],
                        ),
                        if (_startLocation != null &&
                            _destination != null &&
                            _startLocation!.floor != _destination!.floor)
                          _buildFloorChangeSummary(),
                      ],
                    ),
                  ),
                if (_floors.length > 1)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Row(
                      children: [
                        for (final f in (_floors.keys.toList()..sort()))
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text('Floor $f'),
                              selected: f == _currentFloor,
                              onSelected: (_) => setState(() => _showFloor(f)),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: InteractiveViewer(
                    boundaryMargin: const EdgeInsets.all(40),
                    minScale: 0.1,
                    maxScale: 8.0,
                    child: CustomPaint(
                      painter: PathMapPainter(
                        nodes,
                        _waypoints,
                        edges: _graph?.edges,
                        walkEnd: (_graph?.walkNodeCount ?? 1) - 1,
                        routeNodes: _routeNodes,
                        walls: [..._walls, ..._detectedWalls],
                      ),
                      child: Container(),
                    ),
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _canStartNavigation ? _startArNavigation : null,
                      icon: const Icon(CupertinoIcons.location_north_fill, size: 18),
                      label: const Text('Start AR Navigation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
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
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: Colors.black)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Color(0xFF71717A), fontSize: 11, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _GuidanceBanner extends StatelessWidget {
  final ({String title, String subtitle, IconData icon}) guidance;
  const _GuidanceBanner({required this.guidance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(guidance.icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  guidance.title,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  guidance.subtitle,
                  style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DistanceBar extends StatelessWidget {
  final double remainingMeters;
  final double totalMeters;
  const _DistanceBar({required this.remainingMeters, required this.totalMeters});

  @override
  Widget build(BuildContext context) {
    final stepsRemaining = (remainingMeters / 0.55).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _distanceStat('${remainingMeters.toStringAsFixed(1)}m', 'remaining'),
          Container(width: 1, height: 32, color: Colors.white24),
          _distanceStat('$stepsRemaining', 'steps left'),
          Container(width: 1, height: 32, color: Colors.white24),
          _distanceStat('${totalMeters.toStringAsFixed(1)}m', 'total'),
        ],
      ),
    );
  }

  Widget _distanceStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        Text(label, style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 11)),
      ],
    );
  }
}
