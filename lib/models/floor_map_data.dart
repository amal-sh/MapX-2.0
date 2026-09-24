import '../logic/floor_graph.dart';
import 'map_models.dart';

/// One floor's saved map, as stored under [key] in SharedPreferences.
class FloorMapData {
  final String key;
  final int floor;
  final String? building;
  final List<PathSegment> segments;
  final List<Waypoint> waypoints;
  final List<WallSegment> walls;
  final List<PathLink> links;
  final int stepCount;

  /// Everything as loaded, so saving keeps fields this class doesn't know.
  final Map<String, dynamic> _raw;

  FloorMapData._(this.key, this._raw, this.floor, this.building, this.segments, this.waypoints, this.walls,
      this.links, this.stepCount);

  late final FloorGraph graph = FloorGraph.build(segments, floor, links);

  factory FloorMapData.fromJson(String key, Map data) {
    final raw = Map<String, dynamic>.from(data);
    final floor = raw['floor'] as int? ?? 0;
    final stepCount = raw['stepCount'] as int? ?? 0;
    List<Map<String, dynamic>> list(String k) =>
        [for (final e in (raw[k] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

    final waypoints = list('waypoints').map(Waypoint.fromJson).toList();
    // Always offer the walk's own ends, so a map without markers is navigable.
    if (!waypoints.any((w) => w.globalStepIndex == 0)) {
      waypoints.insert(0, Waypoint(0, 'Start', floor: floor));
    }
    if (stepCount > 0 && !waypoints.any((w) => w.globalStepIndex == stepCount)) {
      waypoints.add(Waypoint(stepCount, 'End', floor: floor));
    }

    return FloorMapData._(
      key,
      raw,
      floor,
      raw['name'] as String?,
      list('segments').map(PathSegment.fromJson).toList(),
      waypoints,
      list('walls').map(WallSegment.fromJson).toList(),
      list('links').map(PathLink.fromJson).toList(),
      stepCount,
    );
  }

  /// This map with its places and drawn paths replaced, ready to store.
  Map<String, dynamic> toJsonWith({required List<Waypoint> waypoints, required List<PathLink> links}) => {
        ..._raw,
        'waypoints': [for (final w in waypoints) w.toJson()],
        'links': [for (final l in links) l.toJson()],
      };
}
