import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/floor_graph.dart';
import '../models/floor_map_data.dart';
import '../models/map_models.dart';
import '../widgets/marker_dialog.dart';
import '../widgets/path_map_painter.dart';
import 'mapping_screen.dart';

enum _EditMode { places, paths }

/// Edits a saved floor map without walking it again: add, rename or delete
/// places on the path, and draw new paths between two places. Map
/// coordinates are metres, so a drawn path's length is known from the map.
///
/// Pops `true` when changes were saved.
class MapEditorScreen extends StatefulWidget {
  final String mapKey;
  final String title;

  const MapEditorScreen({super.key, required this.mapKey, required this.title});

  @override
  State<MapEditorScreen> createState() => _MapEditorScreenState();
}

class _MapEditorScreenState extends State<MapEditorScreen> {
  // How close (in screen pixels) a tap must be to a marker or the path.
  static const double _tapTolerancePx = 24;

  final _transform = TransformationController();

  FloorMapData? _map;
  late List<Waypoint> _waypoints;
  late List<PathLink> _links;
  late FloorGraph _graph;
  List<Waypoint> _otherFloorConnectors = const [];
  bool _dirty = false;

  _EditMode _mode = _EditMode.places;

  // Path being drawn: starts at a place, then bend points, until a second
  // place is tapped.
  Waypoint? _pathStart;
  final List<(double, double)> _bends = [];

  // Waiting for a tap on the point a walked path will start from.
  bool _pickingWalkStart = false;

  // A walked path offers to join an existing place/path it ends this close to.
  static const double _joinRadiusMeters = 3.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = FloorMapData.fromJson(widget.mapKey, jsonDecode(prefs.getString(widget.mapKey) ?? '{}') as Map);
    final connectors = data.building == null
        ? const <Waypoint>[]
        : await loadConnectorsOnOtherFloors(data.building!, data.floor);
    if (!mounted) return;
    setState(() {
      _map = data;
      _waypoints = [...data.waypoints];
      _links = [...data.links];
      _graph = data.graph;
      _otherFloorConnectors = connectors;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(widget.mapKey, jsonEncode(_map!.toJsonWith(waypoints: _waypoints, links: _links)));
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this map have not been saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  // ---- taps -------------------------------------------------------------

  void _onTap(Offset local, Size size) {
    final viewport = MapViewport.fit(_graph.nodes, _map!.walls, size);
    // Keep the tap target the same size on screen at any zoom level.
    final tolerance = _tapTolerancePx / _transform.value.getMaxScaleOnAxis();
    final (east, north) = viewport.toMap(local);

    Waypoint? hitPlace;
    var bestPlace = double.infinity;
    for (final w in _waypoints) {
      if (w.globalStepIndex >= _graph.nodes.length) continue;
      final n = _graph.nodes[w.globalStepIndex];
      final d = (viewport.toScreen(n.east, n.north) - local).distance;
      if (d <= tolerance && d < bestPlace) {
        bestPlace = d;
        hitPlace = w;
      }
    }
    final nearest = _graph.nearestNode(east, north);
    final onPath = nearest.distance * viewport.scale <= tolerance;

    if (_mode == _EditMode.places) {
      if (hitPlace != null) {
        _editPlace(hitPlace);
      } else if (onPath) {
        _addPlace(nearest.index);
      } else {
        _hint('Tap on the path to add a place there');
      }
      return;
    }

    // Paths mode
    if (_pickingWalkStart) {
      if (onPath) {
        setState(() => _pickingWalkStart = false);
        _walkNewPath(nearest.index);
      } else {
        _hint('Tap on a path to start the new path there');
      }
      return;
    }
    if (_pathStart == null) {
      if (hitPlace != null) {
        setState(() => _pathStart = hitPlace);
      } else if (onPath && _graph.linkOfNode(nearest.index) != null) {
        _confirmDeleteLink(_graph.linkOfNode(nearest.index)!);
      } else {
        _hint('Tap a place to start a new path');
      }
    } else if (hitPlace != null) {
      if (hitPlace.globalStepIndex != _pathStart!.globalStepIndex) _finishPath(hitPlace);
    } else {
      setState(() => _bends.add((east, north)));
    }
  }

  void _hint(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  // ---- places -----------------------------------------------------------

  Future<void> _addPlace(int node) async {
    final existing = _waypoints.where((w) => w.globalStepIndex == node).firstOrNull;
    if (existing != null) return _editPlace(existing);

    final result = await showDialog<MarkerDialogResult>(
      context: context,
      builder: (_) => MarkerDialog(knownConnectors: _otherFloorConnectors),
    );
    if (result == null) return;
    setState(() {
      _waypoints.add(Waypoint(node, result.label, floor: _map!.floor, category: result.category));
      _dirty = true;
    });
  }

  Future<void> _editPlace(Waypoint place) async {
    final result = await showDialog<MarkerDialogResult>(
      context: context,
      builder: (_) => MarkerDialog(knownConnectors: _otherFloorConnectors, initial: place),
    );
    if (result == null) return;
    setState(() {
      final i = _waypoints.indexOf(place);
      if (result.delete) {
        _waypoints.removeAt(i);
      } else {
        _waypoints[i] = Waypoint(place.globalStepIndex, result.label, floor: place.floor, category: result.category);
      }
      _dirty = true;
    });
  }

  // ---- paths ------------------------------------------------------------

  List<(double, double)> get _pendingPoints {
    final a = _graph.nodes[_pathStart!.globalStepIndex];
    return [(a.east, a.north), ..._bends];
  }

  static double _polylineLength(List<(double, double)> pts) {
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      d += sqrt(pow(pts[i].$1 - pts[i - 1].$1, 2) + pow(pts[i].$2 - pts[i - 1].$2, 2));
    }
    return d;
  }

  void _finishPath(Waypoint end) {
    final b = _graph.nodes[end.globalStepIndex];
    final length = _polylineLength([..._pendingPoints, (b.east, b.north)]);
    setState(() {
      _links.add(PathLink(fromNode: _pathStart!.globalStepIndex, toNode: end.globalStepIndex, bends: [..._bends]));
      _graph = FloorGraph.build(_map!.segments, _map!.floor, _links);
      _pathStart = null;
      _bends.clear();
      _dirty = true;
    });
    _hint('Path added: ${length.toStringAsFixed(1)} m');
  }

  void _cancelPath() => setState(() {
    _pathStart = null;
    _bends.clear();
    _pickingWalkStart = false;
  });

  /// Records a new path by walking it from [startNode], like mapping a new
  /// floor, then adds it to this map along with any places marked on the way.
  Future<void> _walkNewPath(int startNode) async {
    final map = _map!;
    final recording = await Navigator.push<MappingRecording>(
      context,
      MaterialPageRoute(
        builder: (_) => MappingScreen(
          mapName: map.building ?? widget.mapKey.substring(4),
          floor: map.floor,
          branch: MappingBranch(base: _graph, baseWaypoints: _waypoints, startNode: startNode),
        ),
      ),
    );
    if (recording == null || !mounted) return;

    // The walk's own coordinates start at (0, 0): move them to the start point.
    // Its headings are compass bearings, like the rest of the map, so no
    // rotation is needed.
    final origin = _graph.nodes[startNode];
    final walk = FloorGraph.walkNodes(recording.segments, map.floor);
    if (walk.length < 2) return;
    final points = [for (final n in walk.skip(1)) (origin.east + n.east, origin.north + n.north)];

    final joinNode = await _askToJoin(startNode, points);
    if (!mounted) return;

    setState(() {
      _links.add(PathLink(fromNode: startNode, toNode: joinNode, bends: points));
      _graph = FloorGraph.build(map.segments, map.floor, _links);
      final (rangeStart, rangeEnd) = _graph.linkNodeRanges.last;

      for (final w in recording.waypoints) {
        final k = w.globalStepIndex.clamp(0, points.length);
        var node = startNode;
        if (k > 0) {
          final (e, n) = points[k - 1];
          var best = double.infinity;
          for (var i = rangeStart; i < rangeEnd; i++) {
            final d = pow(_graph.nodes[i].east - e, 2) + pow(_graph.nodes[i].north - n, 2);
            if (d < best) {
              best = d.toDouble();
              node = i;
            }
          }
        }
        if (_waypoints.any((x) => x.globalStepIndex == node)) continue;
        _waypoints.add(Waypoint(node, w.label, floor: map.floor, category: w.category));
      }
      _dirty = true;
    });
    final length = _graph.linkLength(_links.length - 1, _links.last);
    _hint('Walked path added: ${length.toStringAsFixed(1)} m');
  }

  /// If the walk ended near an existing place or path, asks whether to join
  /// it there. Returns the node to join, or null to leave a dead end.
  Future<int?> _askToJoin(int startNode, List<(double, double)> points) async {
    final (endE, endN) = points.last;
    final origin = _graph.nodes[startNode];
    final walkLength = _polylineLength([(origin.east, origin.north), ...points]);

    double distTo(int node) => sqrt(pow(_graph.nodes[node].east - endE, 2) + pow(_graph.nodes[node].north - endN, 2));
    // A short walk always ends near where it began; don't offer to join it
    // straight back to its own start area.
    bool nearStart(int node) =>
        walkLength < 2 * _joinRadiusMeters &&
        sqrt(pow(_graph.nodes[node].east - origin.east, 2) + pow(_graph.nodes[node].north - origin.north, 2)) <
            _joinRadiusMeters;

    int? bestPlace;
    int? bestNode;
    for (var i = 0; i < _graph.nodes.length; i++) {
      if (distTo(i) > _joinRadiusMeters || nearStart(i)) continue;
      if (bestNode == null || distTo(i) < distTo(bestNode)) bestNode = i;
      final isPlace = _waypoints.any((w) => w.globalStepIndex == i);
      if (isPlace && (bestPlace == null || distTo(i) < distTo(bestPlace))) bestPlace = i;
    }
    final target = bestPlace ?? bestNode;
    if (target == null) return null;

    final place = _waypoints.where((w) => w.globalStepIndex == target).firstOrNull;
    final what = place == null ? 'an existing path' : place.displayName;
    final join = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Join the new path?'),
        content: Text('It ended ${distTo(target).toStringAsFixed(1)} m from $what. Connect it there?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Leave as dead end')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Join')),
        ],
      ),
    );
    return join == true ? target : null;
  }

  Future<void> _confirmDeleteLink(int linkIndex) async {
    final length = _graph.linkLength(linkIndex, _links[linkIndex]);
    final placesOnIt = _waypoints.where((w) => _graph.linkOfNode(w.globalStepIndex) == linkIndex).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this path?'),
        content: Text(
          'This drawn path is ${length.toStringAsFixed(1)} m long.'
          '${placesOnIt > 0 ? ' Places marked on it (and paths drawn from them) will be removed too.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _deleteLink(linkIndex);
      _dirty = true;
    });
  }

  void _deleteLink(int linkIndex) {
    final result = _graph.withoutLink(linkIndex, _waypoints, _links);
    _waypoints = result.waypoints;
    _links = result.links;
    _graph = FloorGraph.build(_map!.segments, _map!.floor, _links);
  }

  // ---- UI ---------------------------------------------------------------

  String get _instruction {
    if (_mode == _EditMode.places) return 'Tap the path to add a place. Tap a place to rename or delete it.';
    if (_pickingWalkStart) return 'Tap the point on a path where you will start walking.';
    if (_pathStart == null) return 'Draw: tap a place to start a path. Tap an added path to delete it.';
    return 'Tap where the path bends, then tap the place it ends at.';
  }

  @override
  Widget build(BuildContext context) {
    final map = _map;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context, false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Edit · ${widget.title}'),
          actions: [
            TextButton(
              onPressed: _dirty ? _save : null,
              child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        body: map == null
            ? const Center(child: CircularProgressIndicator(color: Colors.black))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: SegmentedButton<_EditMode>(
                      segments: const [
                        ButtonSegment(value: _EditMode.places, label: Text('Places'), icon: Icon(Icons.place_outlined)),
                        ButtonSegment(value: _EditMode.paths, label: Text('Paths'), icon: Icon(Icons.timeline)),
                      ],
                      selected: {_mode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() {
                        _mode = s.first;
                        _cancelPath();
                      }),
                    ),
                  ),
                  // Fixed two-line height: instructions change while editing,
                  // and the map below must not resize under the user's taps.
                  Container(
                    height: 34,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _instruction,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, height: 1.3, color: Color(0xFF71717A)),
                    ),
                  ),
                  // Always shown in Paths mode so the map never resizes mid-edit.
                  if (_mode == _EditMode.paths)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _pickingWalkStart
                          ? TextButton(onPressed: _cancelPath, child: const Text('Cancel'))
                          : OutlinedButton.icon(
                              onPressed: _pathStart != null ? null : () => setState(() => _pickingWalkStart = true),
                              icon: const Icon(Icons.directions_walk, size: 18),
                              label: const Text('Walk a new path'),
                            ),
                    ),
                  const SizedBox(height: 6),
                  Expanded(
                    // The path bar overlays the map rather than shrinking it,
                    // so the map doesn't re-fit and jump while drawing.
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: InteractiveViewer(
                            transformationController: _transform,
                            boundaryMargin: const EdgeInsets.all(80),
                            minScale: 0.5,
                            maxScale: 8.0,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final size = constraints.biggest;
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (d) => _onTap(d.localPosition, size),
                                  child: CustomPaint(
                                    painter: PathMapPainter(
                                      _graph.nodes,
                                      _waypoints,
                                      walls: map.walls,
                                      edges: _graph.edges,
                                      walkEnd: _graph.walkNodeCount - 1,
                                    ),
                                    foregroundPainter: _pathStart == null
                                        ? null
                                        : _PendingPathPainter(
                                            MapViewport.fit(_graph.nodes, map.walls, size),
                                            _pendingPoints,
                                          ),
                                    child: const SizedBox.expand(),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        if (_pathStart != null) Positioned(left: 0, right: 0, bottom: 0, child: _buildPathBar()),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildPathBar() {
    final length = _polylineLength(_pendingPoints);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE4E4E7))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('From ${_pathStart!.displayName}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    '${length.toStringAsFixed(1)} m so far · ${_bends.length} bend${_bends.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _bends.isEmpty ? null : () => setState(() => _bends.removeLast()),
              child: const Text('Undo bend'),
            ),
            TextButton(onPressed: _cancelPath, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// The path being drawn: from its start place through the bends so far.
class _PendingPathPainter extends CustomPainter {
  final MapViewport viewport;
  final List<(double, double)> points;

  _PendingPathPainter(this.viewport, this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final screen = [for (final p in points) viewport.toScreen(p.$1, p.$2)];
    final line = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (screen.length > 1) {
      final path = Path()..moveTo(screen.first.dx, screen.first.dy);
      for (final p in screen.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, line);
    }
    canvas.drawCircle(screen.first, 12, Paint()..color = const Color(0x552563EB));
    for (final p in screen.skip(1)) {
      canvas.drawCircle(p, 5, Paint()..color = const Color(0xFF2563EB));
    }
  }

  @override
  bool shouldRepaint(_PendingPathPainter old) => true;
}
