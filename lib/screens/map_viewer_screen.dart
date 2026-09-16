import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/map_models.dart';
import '../widgets/path_map_painter.dart';

class MapViewerScreen extends StatefulWidget {
  final String mapKey;
  final String mapName;

  const MapViewerScreen({super.key, required this.mapKey, required this.mapName});

  @override
  State<MapViewerScreen> createState() => _MapViewerScreenState();
}

class _MapViewerScreenState extends State<MapViewerScreen> {
  bool _isLoading = true;
  List<PathSegment> _segments = [];
  List<Waypoint> _waypoints = [];
  int _stepCount = 0;

  Waypoint? _startLocation;
  Waypoint? _destination;

  @override
  void initState() {
    super.initState();
    _loadMapData();
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
      
      setState(() {
        _segments = segments;
        _waypoints = waypoints;
        _stepCount = mapData['stepCount'] ?? 0;
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

  @override
  Widget build(BuildContext context) {
    final nodes = _computedNodes;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mapName),
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
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: const Text('Pinch to zoom, drag to pan', style: TextStyle(color: Colors.grey)),
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
