import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/depth_occlusion_manager.dart';
import '../logic/outdoor_route_planner.dart';
import '../logic/floor_graph.dart';
import '../logic/floor_route_planner.dart';
import '../logic/relocalization_manager.dart';
import '../logic/route_instructions.dart';
import '../logic/route_segment_manager.dart';
import '../logic/spatial_sensor_fusion.dart';
import '../logic/wall_collision_validator.dart';
import '../models/outdoor_models.dart';
import '../models/floor_map_data.dart';
import '../models/map_models.dart';
import '../widgets/navigation/ar_mini_map.dart';
import '../widgets/navigation/ar_path_painter.dart';
import '../widgets/navigation/ar_world_scanner_overlay.dart';
import '../widgets/navigation/off_path_direction_prompt.dart';
import '../widgets/path_map_painter.dart';
import '../services/building_repository.dart';
import '../services/navigation_history_service.dart';
import 'outdoor_navigation_screen.dart';

class MapViewerScreen extends StatefulWidget {
  final String mapKey;
  final String mapName;
  final String? targetDestinationName;
  final int? targetFloor;

  const MapViewerScreen({
    super.key,
    required this.mapKey,
    required this.mapName,
    this.targetDestinationName,
    this.targetFloor,
  });

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

  // Every mapped floor of the building shown. The fields above always hold
  // the floor currently shown (see _showFloor).
  Map<int, FloorMapData> _floors = {};
  FloorGraph? _graph;

  // The building shown, every loaded building (this one and any linked to it
  // outdoors) and the links between them.
  String _building = '';
  Map<String, Map<int, FloorMapData>> _site = {};
  List<BuildingConnection> _connections = [];

  // Cross-floor trips: which connector type to route through, and the legs
  // being walked (frozen when navigation starts).
  bool _preferLift = true;
  List<TripLeg>? _activeLegs;
  // Outdoor walks of the active trip, by the leg they follow.
  Map<int, OutdoorHop> _activeOutdoor = {};
  int _legIndex = 0;
  // Reached the stairs/lift at the end of a leg; waiting for the walker to
  // confirm they're on the next floor.
  bool _atConnector = false;

  _Place? _startLocation;
  _Place? _destination;
  bool _isArMode = false;
  bool _useArCore = true;
  static const platform = MethodChannel('mapx/arcore');
  final TransformationController _mapTransformController = TransformationController();

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
  bool _isTravelingBackward = false;
  double _extraTurnDistance = 0.0;
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
    _mapTransformController.dispose();
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
    final building = opened.building ?? widget.mapKey.substring(4);

    // Every stored floor, grouped by building; the opened map wins a clash.
    final all = <String, Map<int, FloorMapData>>{
      building: {opened.floor: opened},
    };
    for (final key in prefs.getKeys().where((k) => k.startsWith('map_') && k != widget.mapKey)) {
      try {
        final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
        final floor = FloorMapData.fromJson(key, data);
        all.putIfAbsent(floor.building ?? key.substring(4), () => {}).putIfAbsent(floor.floor, () => floor);
      } catch (_) {}
    }

    // This building plus those linked to it outdoors.
    final connections = await BuildingRepository.instance.loadConnections();
    final linked = {building, for (final c in connections.where((c) => c.involves(building))) c.otherEnd(building).building};
    final site = {for (final b in linked) if (all[b] != null) b: all[b]!};

    // A selected place may have been renamed or deleted in the editor.
    final allPlaces = {
      for (final b in site.entries)
        for (final f in b.value.values)
          for (final w in f.waypoints) _Place(b.key, w),
    };
    _Place? defaultStart = allPlaces.contains(_startLocation) ? _startLocation : null;
    _Place? defaultDest = allPlaces.contains(_destination) ? _destination : null;
    final here = [for (final f in site[building]!.values) for (final w in f.waypoints) _Place(building, w)];

    if (widget.targetDestinationName != null) {
      final name = widget.targetDestinationName!.toLowerCase();
      final match = here
          .where((p) => p.label.toLowerCase() == name || p.displayName.toLowerCase() == name)
          .firstOrNull;
      if (match != null) {
        defaultDest = match;
        if (defaultStart == match) defaultStart = here.where((p) => p != match).firstOrNull;
      }
    }

    if (defaultStart == null && opened.waypoints.isNotEmpty) {
      defaultStart = _Place(building, opened.waypoints.first);
    }
    if (defaultDest == null && opened.waypoints.length >= 2) {
      defaultDest = _Place(building, opened.waypoints.last);
    }

    // Show the destination's floor when coming from search, else the start's.
    final shown = widget.targetDestinationName != null ? defaultDest : defaultStart;
    final shownBuilding = shown?.building ?? building;
    final initialFloor = widget.targetFloor ?? shown?.floor ?? opened.floor;

    setState(() {
      _site = site;
      _connections = connections;
      _startLocation = defaultStart;
      _destination = defaultDest;
      _showBuilding(shownBuilding, initialFloor);
      _isLoading = false;
    });
  }

  /// Makes [building]'s [floor] the one drawn and navigated on.
  void _showBuilding(String building, int floor) {
    final floors = _site[building];
    if (floors == null) return;
    _building = building;
    _floors = floors;
    _showFloor(floors.containsKey(floor) ? floor : (floors.keys.toList()..sort()).first);
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

  /// Every place: this building's first (lowest floor first), then linked
  /// buildings'.
  List<_Place> get _allPlaces {
    final buildings = _site.keys.toList()..sort((a, b) => a == _building ? -1 : (b == _building ? 1 : a.compareTo(b)));
    return [
      for (final b in buildings)
        for (final f in (_site[b]!.keys.toList()..sort()))
          for (final w in _site[b]![f]!.waypoints) _Place(b, w),
    ];
  }

  String _placeName(_Place p) {
    final multiFloor = (_site[p.building]?.length ?? 1) > 1;
    if (p.building == _building || _site.length == 1) {
      return multiFloor ? '${p.displayName} · Floor ${p.floor}' : p.displayName;
    }
    return '${p.displayName} · ${p.building}${multiFloor ? ', Floor ${p.floor}' : ''}';
  }

  OutdoorTrip? get _plannedTrip {
    final start = _startLocation, destination = _destination;
    if (start == null || destination == null) return null;
    return OutdoorRoutePlanner.plan(
      graphs: {
        for (final b in _site.entries) b.key: {for (final f in b.value.entries) f.key: f.value.graph},
      },
      waypoints: {
        for (final b in _site.entries) b.key: {for (final f in b.value.entries) f.key: f.value.waypoints},
      },
      connections: _connections,
      startBuilding: start.building,
      start: start.place,
      destinationBuilding: destination.building,
      destination: destination.place,
      preferLift: _preferLift,
    );
  }

  List<TripLeg>? get _plannedLegs => _plannedTrip?.legs;

  /// The leg on the floor being shown: the one being walked while
  /// navigating, otherwise the planned leg on this floor (if any).
  TripLeg? get _displayLeg {
    if (_activeLegs != null) {
      return _legIndex < _activeLegs!.length ? _activeLegs![_legIndex] : null;
    }
    return _plannedLegs?.where((l) => l.building == _building && l.floor == _currentFloor).firstOrNull;
  }

  bool get _hasNextLeg => _activeLegs != null && _legIndex < _activeLegs!.length - 1;

  /// The outdoor walk after the current leg, if the trip leaves the building.
  OutdoorHop? get _outdoorNext => _activeLegs == null ? null : _activeOutdoor[_legIndex];

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
    if (leg == null || leg.floor != _currentFloor || (leg.building != null && leg.building != _building)) return null;
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
    final trip = _plannedTrip;
    if (trip == null || !_canStartNavigation) {
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

    final legs = trip.legs;
    _activeLegs = legs;
    _activeOutdoor = trip.outdoorAfterLeg;
    _legIndex = 0;
    _showBuilding(legs.first.building ?? _building, legs.first.floor);
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
      segmentManager: _segmentManager,
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
        userHeadingDeg: pos.headingDegrees,
        userEast: pos.east,
        userNorth: pos.north,
      ) ?? pos.headingDegrees;

      final facingEval = _segmentManager?.evaluateFacingWithTolerance(
        userHeadingDeg: pos.headingDegrees,
        currentProgress: pos.progressMeters,
        targetBearingDeg: targetBearing,
        thresholdDeg: 35.0,
      ) ?? RouteSegmentManager.evaluateFacing(
        userHeadingDeg: pos.headingDegrees,
        targetBearingDeg: targetBearing,
        thresholdDeg: 35.0,
      );

      final revealedEnd = _segmentManager?.computeRevealedEndDistance(pos.progressMeters) ?? (pos.progressMeters + 8.0);

      final currentSeg = _segmentManager?.getSegmentForProgress(pos.progressMeters);
      final upcomingTurn = currentSeg?.upcomingTurn;
      final distToTurn = upcomingTurn != null ? (upcomingTurn.distance - pos.progressMeters) : null;
      final isAtTurn = distToTurn != null && distToTurn.abs() <= RouteSegmentManager.turnToleranceMeters;

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
        _isTravelingBackward = pos.isTravelingBackward || facingEval.isTravelingBackward;
        _extraTurnDistance = pos.extraTurnDistance;
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
    final outdoor = _outdoorNext;
    await _fusionSub?.cancel();
    _fusionSub = null;
    _fusionEngine?.dispose();
    _fusionEngine = null;
    _relocalizer = null;
    _segmentManager = null;
    if (!mounted) return;

    if (outdoor != null && !await _walkOutside(outdoor)) return;
    if (!mounted) return;

    _legIndex++;
    final leg = _activeLegs![_legIndex];
    _showBuilding(leg.building ?? _building, leg.floor);
    _beginLeg();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(outdoor != null ? 'Now navigating in $_building' : 'Now navigating on Floor $_currentFloor'),
      ),
    );
  }

  /// The outdoor part of a trip: the camera and AR session are released
  /// while the street map guides the walker, then restarted inside the next
  /// building. Returns false if the walker stopped navigating outside.
  Future<bool> _walkOutside(OutdoorHop hop) async {
    try {
      await platform.invokeMethod(_useArCore ? 'stopArNavigation' : 'stopCameraPreview');
      await platform.invokeMethod('stopSession');
    } catch (e) {
      debugPrint('AR Error: $e');
    }
    if (!mounted) return false;
    final arrived = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => OutdoorNavigationScreen(hop: hop)),
    );
    if (!mounted) return false;
    if (arrived != true) {
      await _stopNavigation();
      return false;
    }
    try {
      await platform.invokeMethod('startSession');
      await platform.invokeMethod(_useArCore ? 'startArNavigation' : 'startCameraPreview');
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Could not restart AR')));
      }
      await _stopNavigation();
      return false;
    }
    // A new building means a new floor to find.
    _isFloorDetected = false;
    _floorConfidence = 0.0;
    _showFloorAnchoredBadge = false;
    return true;
  }

  ({String title, String subtitle, IconData icon}) get _connectorGuidance {
    final exit = _activeLegs![_legIndex].to;
    final outdoor = _outdoorNext;
    if (outdoor != null) {
      return (
        title: 'Exit through ${exit.displayName}',
        subtitle: 'Then walk to ${outdoor.toBuilding}. Tap "Walk outside" at the door.',
        icon: Icons.door_front_door_outlined,
      );
    }
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

    if (_isTravelingBackward) {
      return (
        title: 'Wrong Direction',
        subtitle: 'Turn around to follow the route',
        icon: CupertinoIcons.arrow_uturn_down,
      );
    }

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

    for (var i = 0; i < _turnInstructions.length; i++) {
      final instr = _turnInstructions[i];
      if (_segmentManager != null && _segmentManager!.isTurnCompleted(i)) {
        continue;
      }
      final distToTurn = instr.distance - _liveProgress;
      if (distToTurn < -RouteSegmentManager.turnToleranceMeters) {
        continue;
      }

      final icon = instr.label.contains('U-turn')
          ? CupertinoIcons.arrow_uturn_left
          : instr.angleDeltaDeg > 0
              ? CupertinoIcons.arrow_turn_up_right
              : CupertinoIcons.arrow_turn_up_left;

      if (distToTurn.abs() <= RouteSegmentManager.turnToleranceMeters) {
        return (
          title: '${instr.label} now',
          subtitle: 'Turn ${instr.angleDeltaDeg > 0 ? "right" : "left"} here',
          icon: icon,
        );
      }

      if (distToTurn > RouteSegmentManager.turnToleranceMeters) {
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

  /// Under the pickers for a trip that changes floor or building: the
  /// lift/stairs choice and the planned route, or why there isn't one.
  Widget _buildTripSummary() {
    final start = _startLocation!, destination = _destination!;
    final trip = _plannedTrip;
    const muted = TextStyle(fontSize: 12, color: Color(0xFF71717A));
    if (trip == null) {
      final reason = start.building != destination.building
          ? '${start.building} and ${destination.building} aren\'t linked. On the home screen, open the Outdoor '
              'Map and link them through their entrances.'
          : 'No stairs or lift links Floor ${start.floor} and Floor ${destination.floor}. '
              'While mapping, mark the same stairs/lift with the same name on both floors.';
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(reason, style: const TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
      );
    }

    final legs = trip.legs;
    final steps = <String>[];
    var changesFloor = false;
    for (var i = 0; i < legs.length - 1; i++) {
      final hop = trip.outdoorAfterLeg[i];
      if (hop != null) {
        steps.add('exit at ${legs[i].to.displayName}, walk ${hop.connection.distanceMeters.toStringAsFixed(0)} m '
            'outside to ${hop.toBuilding}');
      } else {
        changesFloor = true;
        steps.add('${legs[i].to.displayName} to Floor ${legs[i + 1].floor}');
      }
    }
    final summary = Text('Via ${steps.join(', then ')}', style: muted);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: changesFloor
          ? Row(
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
                Expanded(child: summary),
              ],
            )
          : summary,
    );
  }

  void _zoomIn() {
    final matrix = _mapTransformController.value.clone();
    matrix.scaleByDouble(1.25, 1.25, 1.0, 1.0);
    _mapTransformController.value = matrix;
  }

  void _zoomOut() {
    final matrix = _mapTransformController.value.clone();
    matrix.scaleByDouble(0.8, 0.8, 1.0, 1.0);
    _mapTransformController.value = matrix;
  }

  void _resetView() {
    _mapTransformController.value = Matrix4.identity();
  }

  void _showPlacePickerSheet({required bool isStart}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        String searchQuery = '';
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final places = _allPlaces.where((p) {
              if (searchQuery.isEmpty) return true;
              final q = searchQuery.toLowerCase();
              return p.displayName.toLowerCase().contains(q) ||
                  p.building.toLowerCase().contains(q) ||
                  p.label.toLowerCase().contains(q);
            }).toList();

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.65,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE4E4E7),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isStart ? 'Select Origin' : 'Select Destination',
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(CupertinoIcons.xmark, size: 20),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Search rooms, labs, stairs...',
                          hintStyle: GoogleFonts.inter(color: const Color(0xFFA1A1AA), fontSize: 14),
                          prefixIcon: const Icon(CupertinoIcons.search, size: 18, color: Color(0xFF71717A)),
                          filled: true,
                          fillColor: const Color(0xFFF4F4F5),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.black),
                          ),
                        ),
                        onChanged: (val) {
                          setSheetState(() => searchQuery = val);
                        },
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: places.isEmpty
                            ? Center(
                                child: Text(
                                  'No locations found',
                                  style: GoogleFonts.inter(color: const Color(0xFF71717A), fontSize: 14),
                                ),
                              )
                            : ListView.separated(
                                itemCount: places.length,
                                separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFF4F4F5)),
                                itemBuilder: (context, idx) {
                                  final place = places[idx];
                                  final isSelected = isStart ? (_startLocation == place) : (_destination == place);
                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                    leading: Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: isSelected ? Colors.black : const Color(0xFFF4F4F5),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        place.place.isConnector
                                            ? (place.place.category == Waypoint.liftCategory
                                                ? Icons.elevator_outlined
                                                : Icons.stairs_outlined)
                                            : CupertinoIcons.placemark,
                                        size: 18,
                                        color: isSelected ? Colors.white : const Color(0xFF27272A),
                                      ),
                                    ),
                                    title: Text(
                                      place.displayName,
                                      style: GoogleFonts.inter(
                                        fontSize: 15,
                                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                        color: Colors.black,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _placeName(place),
                                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF71717A)),
                                    ),
                                    trailing: isSelected
                                        ? const Icon(CupertinoIcons.checkmark, size: 18, color: Colors.black)
                                        : null,
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      setState(() {
                                        if (isStart) {
                                          _startLocation = place;
                                          _showBuilding(place.building, place.floor);
                                        } else {
                                          _destination = place;
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showRouteOptionsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE4E4E7),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Route & Accessibility Options',
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(CupertinoIcons.xmark, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Vertical Connector Preference',
                      style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF71717A)),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Elevator / Lift'),
                          icon: Icon(Icons.elevator_outlined, size: 18),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Stairs'),
                          icon: Icon(Icons.stairs_outlined, size: 18),
                        ),
                      ],
                      selected: {_preferLift},
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return Colors.black;
                          return const Color(0xFFF4F4F5);
                        }),
                        foregroundColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return Colors.white;
                          return const Color(0xFF18181B);
                        }),
                      ),
                      onSelectionChanged: (s) {
                        setSheetState(() {});
                        setState(() => _preferLift = s.first);
                      },
                    ),
                    if (_startLocation != null &&
                        _destination != null &&
                        (_startLocation!.building != _destination!.building ||
                            _startLocation!.floor != _destination!.floor)) ...[
                      const SizedBox(height: 16),
                      _buildTripSummary(),
                    ],
                    const SizedBox(height: 20),
                    const Divider(height: 1, color: Color(0xFFE4E4E7)),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black,
                          side: const BorderSide(color: Color(0xFFE4E4E7)),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          _startSensorArNavigation();
                        },
                        icon: const Icon(CupertinoIcons.videocam, size: 18),
                        label: Text('Sensor AR Navigation (without ARCore)', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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
    // Persist completed navigations offline so Recent Trips stays live.
    // Captured before state is reset below.
    final NavigationHistoryService? historyService =
        didArrive ? NavigationHistoryService.instance : null;
    final String? historyFromBuilding = didArrive
        ? (_activeLegs?.first.building ??
            _startLocation?.building ??
            _building)
        : null;
    final Waypoint? historyFromWaypoint =
        didArrive ? (_activeLegs?.first.from ?? _startLocation?.place) : null;
    final String? historyToBuilding = didArrive
        ? (_activeLegs?.last.building ??
            _destination?.building ??
            _building)
        : null;
    final Waypoint? historyToWaypoint =
        didArrive ? (_activeLegs?.last.to ?? _destination?.place) : null;
    final double? historyDistance =
        didArrive ? (_plannedTrip?.distanceMeters ?? _routeTotalDistance) : null;
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
    _activeOutdoor = {};
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
        _showBuilding(_startLocation?.building ?? _building, _startLocation?.floor ?? _currentFloor);
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
      if (historyService != null &&
          historyFromBuilding != null &&
          historyFromWaypoint != null &&
          historyToBuilding != null &&
          historyToWaypoint != null) {
        unawaited(historyService.logTrip(
          fromBuilding: historyFromBuilding,
          fromFloor: historyFromWaypoint.floor,
          fromLabel: historyFromWaypoint.displayName,
          toBuilding: historyToBuilding,
          toFloor: historyToWaypoint.floor,
          toLabel: historyToWaypoint.displayName,
          distanceMeters: historyDistance,
        ));
      }
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

            // Off-Path Direction Prompt: guides user when facing away from path or traveling backward
            if (_arReady && (!_isFacingPath || _isTravelingBackward))
              Positioned.fill(
                child: IgnorePointer(
                  child: OffPathDirectionPrompt(
                    deltaDegrees: _offPathAngleDelta,
                    turnDirection: _turnDirection,
                    isAtTurn: _isAtTurn,
                    isTravelingBackward: _isTravelingBackward,
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
                      _outdoorNext != null
                          ? Icons.directions_walk
                          : _activeLegs![_legIndex].to.category == Waypoint.liftCategory
                              ? Icons.elevator_outlined
                              : Icons.stairs_outlined,
                      size: 20,
                    ),
                    label: Text(
                      _outdoorNext != null
                          ? 'Walk outside to ${_outdoorNext!.toBuilding}'
                          : "I'm on Floor ${_activeLegs![_legIndex + 1].floor}",
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
                  remainingMeters: (_routeTotalDistance - _liveProgress + _extraTurnDistance).clamp(0.0, double.infinity),
                  totalMeters: _routeTotalDistance + _extraTurnDistance,
                ),
              ),
            ],
          ],
        ),
        ),
      );
    }

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          leading: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE4E4E7)),
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(CupertinoIcons.chevron_left, size: 18, color: Colors.black),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          title: Text(
            'Route Overview',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 17, color: Colors.black),
          ),
        ),
        body: const Center(child: CircularProgressIndicator(color: Colors.black)),
      );
    }

    final nodes = _computedNodes;
    final floorsList = _floors.keys.toList()..sort((a, b) => b.compareTo(a));
    final calculatedSteps = _stepCount > 0 ? _stepCount : max(1, (_pathLength / 0.65).round());

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Top Navigation Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(CupertinoIcons.chevron_left, size: 18, color: Colors.black),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'Route Overview',
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _building.isNotEmpty
                              ? '${_building.toUpperCase()} • FLOOR $_currentFloor'
                              : widget.mapName.toUpperCase(),
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                            color: const Color(0xFF71717A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(CupertinoIcons.slider_horizontal_3, size: 18, color: Colors.black),
                      tooltip: 'Route options',
                      onPressed: _showRouteOptionsSheet,
                    ),
                  ),
                ],
              ),
            ),

            // Route Origin & Destination Card
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE4E4E7)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left vertical connector line
                      Column(
                        children: [
                          const SizedBox(height: 5),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.black,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Container(
                            width: 1.5,
                            height: 38,
                            color: const Color(0xFFD4D4D8),
                          ),
                          const Icon(
                            CupertinoIcons.location,
                            size: 16,
                            color: Colors.black,
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            // Origin
                            InkWell(
                              onTap: () => _showPlacePickerSheet(isStart: true),
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Origin',
                                          style: GoogleFonts.inter(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            color: const Color(0xFF71717A),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _startLocation?.displayName ?? _startLocation?.label ?? 'Select start',
                                          style: GoogleFonts.inter(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF4F4F5),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFFE4E4E7)),
                                    ),
                                    child: Text(
                                      'F${_startLocation?.floor ?? _currentFloor}',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF71717A),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Destination
                            InkWell(
                              onTap: () => _showPlacePickerSheet(isStart: false),
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Destination',
                                          style: GoogleFonts.inter(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            color: const Color(0xFF71717A),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _destination?.displayName ?? _destination?.label ?? 'Select destination',
                                          style: GoogleFonts.inter(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.black,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'Level ${_destination?.floor ?? _currentFloor}',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: const Color(0xFFFDE047),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Metrics chip row
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.directions_walk, size: 14, color: Color(0xFF27272A)),
                            const SizedBox(width: 4),
                            Text(
                              '$calculatedSteps steps',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF27272A),
                              ),
                            ),
                          ],
                        ),
                        Text('·', style: GoogleFonts.inter(color: const Color(0xFFA1A1AA), fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.circle_grid_hex, size: 13, color: Color(0xFF27272A)),
                            const SizedBox(width: 4),
                            Text(
                              '${_routeNodes?.length ?? nodes.length} Nodes',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF27272A),
                              ),
                            ),
                          ],
                        ),
                        Text('·', style: GoogleFonts.inter(color: const Color(0xFFA1A1AA), fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.straighten, size: 13, color: Color(0xFF27272A)),
                            const SizedBox(width: 4),
                            Text(
                              '${_pathLength.toStringAsFixed(1)} m',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF27272A),
                              ),
                            ),
                          ],
                        ),
                        Text('·', style: GoogleFonts.inter(color: const Color(0xFFA1A1AA), fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.square_stack_3d_up, size: 13, color: Color(0xFF27272A)),
                            const SizedBox(width: 4),
                            Text(
                              'Level ${_destination?.floor ?? _currentFloor}',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF27272A),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 2D Map Canvas
            Expanded(
              child: Stack(
                children: [
                  InteractiveViewer(
                    transformationController: _mapTransformController,
                    boundaryMargin: const EdgeInsets.all(60),
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

                  // Bottom-left 1m grid indicator
                  Positioned(
                    left: 16,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE4E4E7)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 14, height: 2, color: const Color(0xFF71717A)),
                          const SizedBox(width: 6),
                          Text(
                            '1 m grid',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF71717A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Left vertical floor selector
                  if (floorsList.isNotEmpty)
                    Positioned(
                      left: 16,
                      top: 16,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE4E4E7)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final f in floorsList)
                              Padding(
                                padding: const EdgeInsets.all(3),
                                child: InkWell(
                                  onTap: () => setState(() => _showFloor(f)),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: f == _currentFloor ? Colors.black : Colors.transparent,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      'F$f',
                                      style: GoogleFonts.inter(
                                        color: f == _currentFloor ? Colors.white : const Color(0xFF71717A),
                                        fontWeight: f == _currentFloor ? FontWeight.w700 : FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                  // Right floating controls (Compass, Zoom in/out, Recenter FAB)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Compass North button
                        InkWell(
                          onTap: _resetView,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFE4E4E7)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'N',
                                  style: GoogleFonts.inter(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: const Color(0xFF27272A),
                                  ),
                                ),
                                const Icon(CupertinoIcons.arrow_up, size: 9, color: Color(0xFF27272A)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Zoom in / out pill
                        Container(
                          width: 38,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(19),
                            border: Border.all(color: const Color(0xFFE4E4E7)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              InkWell(
                                onTap: _zoomIn,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(19)),
                                child: Container(
                                  height: 36,
                                  alignment: Alignment.center,
                                  child: const Icon(CupertinoIcons.plus, size: 16, color: Color(0xFF27272A)),
                                ),
                              ),
                              const Divider(height: 1, thickness: 1, color: Color(0xFFE4E4E7)),
                              InkWell(
                                onTap: _zoomOut,
                                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(19)),
                                child: Container(
                                  height: 36,
                                  alignment: Alignment.center,
                                  child: const Icon(CupertinoIcons.minus, size: 16, color: Color(0xFF27272A)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Recenter FAB
                        InkWell(
                          onTap: _resetView,
                          borderRadius: BorderRadius.circular(22),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(CupertinoIcons.location_fill, size: 18, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom Navigation Card & AR Start
            Container(
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: const Border(top: BorderSide(color: Color(0xFFE4E4E7))),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 12,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Turn instruction row
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F4F5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE4E4E7)),
                        ),
                        child: Icon(
                          _turnInstructions.isNotEmpty && _turnInstructions.first.angleDeltaDeg < 0
                              ? CupertinoIcons.arrow_turn_up_left
                              : CupertinoIcons.arrow_turn_up_right,
                          size: 18,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _turnInstructions.isNotEmpty
                                  ? _turnInstructions.first.label
                                  : (_hasNextLeg
                                      ? 'Take connector to next floor'
                                      : 'Follow path to destination'),
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'In ${_pathLength > 0 ? _pathLength.toStringAsFixed(0) : "12"} meters',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: const Color(0xFF71717A),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '$calculatedSteps steps',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Start AR Navigation Button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      onPressed: _canStartNavigation
                          ? _startArNavigation
                          : () => _showPlacePickerSheet(isStart: _startLocation == null),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(CupertinoIcons.viewfinder, size: 20, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(
                            'Start AR Navigation',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(CupertinoIcons.arrow_up_right, size: 16, color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Accessible route options text link
                  InkWell(
                    onTap: _showRouteOptionsSheet,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Accessible route options',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF71717A),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(CupertinoIcons.slider_horizontal_3, size: 14, color: Color(0xFF71717A)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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

/// A place in a particular building. Place names and node numbers only mean
/// something within one building, so pickers and trips carry both.
class _Place {
  final String building;
  final Waypoint place;

  const _Place(this.building, this.place);

  int get floor => place.floor;
  String get label => place.label;
  String get displayName => place.displayName;
  int get globalStepIndex => place.globalStepIndex;

  @override
  bool operator ==(Object other) => other is _Place && other.building == building && other.place == place;

  @override
  int get hashCode => Object.hash(building, place);
}
