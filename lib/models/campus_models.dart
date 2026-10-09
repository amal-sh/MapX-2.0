import 'map_models.dart';

/// A GPS position as (latitude, longitude).
typedef GeoPoint = (double lat, double lng);

/// Points at one building's entrance. Matched by floor and name rather than
/// node index, so it survives edits that renumber a floor's nodes.
class EntranceRef {
  final String building;
  final int floor;
  final String label;

  const EntranceRef({required this.building, required this.floor, required this.label});

  bool matches(Waypoint w) => w.isEntrance && w.floor == floor && w.label == label;

  Map<String, dynamic> toJson() => {'building': building, 'floor': floor, 'label': label};

  factory EntranceRef.fromJson(Map<String, dynamic> json) => EntranceRef(
        building: json['building'] as String,
        floor: json['floor'] as int? ?? 0,
        label: json['label'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is EntranceRef && other.building == building && other.floor == floor && other.label == label;

  @override
  int get hashCode => Object.hash(building, floor, label);
}

/// An outdoor walking route between entrances of two buildings, found by a
/// routing service when an admin links the buildings and stored, so
/// navigation doesn't depend on the service being reachable.
class BuildingConnection {
  final EntranceRef a;
  final EntranceRef b;
  final double distanceMeters;
  final double durationSeconds;

  /// The route from [a] to [b], following footpaths.
  final List<GeoPoint> route;

  /// Where [route] came from: 'osrm', or 'straight' when no route was found.
  final String source;

  const BuildingConnection({
    required this.a,
    required this.b,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.route,
    this.source = 'osrm',
  });

  String get id => '${a.building}|${a.floor}|${a.label}~${b.building}|${b.floor}|${b.label}';

  bool involves(String building) => a.building == building || b.building == building;

  bool connects(String x, String y) =>
      (a.building == x && b.building == y) || (a.building == y && b.building == x);

  /// This connection's entrance in [building].
  EntranceRef entranceIn(String building) => a.building == building ? a : b;

  /// The other building's entrance, seen from [building].
  EntranceRef otherEnd(String building) => a.building == building ? b : a;

  /// The route walked starting from [building]'s entrance.
  List<GeoPoint> routeFrom(String building) => a.building == building ? route : route.reversed.toList();

  Map<String, dynamic> toJson() => {
        'a': a.toJson(),
        'b': b.toJson(),
        'distanceMeters': distanceMeters,
        'durationSeconds': durationSeconds,
        // Firestore can't store nested arrays, so points are maps.
        'route': [for (final (lat, lng) in route) {'lat': lat, 'lng': lng}],
        'source': source,
      };

  factory BuildingConnection.fromJson(Map<String, dynamic> json) => BuildingConnection(
        a: EntranceRef.fromJson(Map<String, dynamic>.from(json['a'] as Map)),
        b: EntranceRef.fromJson(Map<String, dynamic>.from(json['b'] as Map)),
        distanceMeters: (json['distanceMeters'] as num).toDouble(),
        durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0,
        route: [
          for (final p in (json['route'] as List? ?? const []))
            ((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
        ],
        source: json['source'] as String? ?? 'osrm',
      );
}
