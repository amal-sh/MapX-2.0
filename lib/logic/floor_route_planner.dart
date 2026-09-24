import '../models/map_models.dart';
import 'floor_graph.dart';

/// One single-floor stretch of a trip, walked from [from] to [to].
class TripLeg {
  final int floor;
  final Waypoint from;
  final Waypoint to;

  const TripLeg({required this.floor, required this.from, required this.to});

  /// Stairs or lift the walker takes at the end of this leg, if any.
  Waypoint? get exitConnector => to.isConnector ? to : null;
}

/// Plans a trip between two waypoints that may be on different floors of the
/// same building. Floors are linked by stairs/lift waypoints that share a type
/// and name (see [Waypoint.connectorKey]).
class FloorRoutePlanner {
  /// Returns the legs to walk, or null if the floors aren't linked.
  ///
  /// [graphs] holds each floor's path network; waypoints index into its
  /// nodes by [Waypoint.globalStepIndex]. Among linked connectors the preferred type
  /// is used when available, then the one giving the shortest total walk.
  static List<TripLeg>? plan({
    required Map<int, FloorGraph> graphs,
    required Map<int, List<Waypoint>> waypointsByFloor,
    required Waypoint start,
    required Waypoint destination,
    required bool preferLift,
  }) {
    if (start.floor == destination.floor) {
      return [TripLeg(floor: start.floor, from: start, to: destination)];
    }

    final startFloorConnectors =
        (waypointsByFloor[start.floor] ?? const <Waypoint>[]).where((w) => w.isConnector);
    final destFloorConnectors =
        (waypointsByFloor[destination.floor] ?? const <Waypoint>[]).where((w) => w.isConnector);

    final pairs = <(Waypoint, Waypoint)>[
      for (final a in startFloorConnectors)
        for (final b in destFloorConnectors)
          if (a.connectorKey == b.connectorKey) (a, b),
    ];
    if (pairs.isEmpty) return null;

    final preferred = preferLift ? Waypoint.liftCategory : Waypoint.stairsCategory;
    final preferredPairs = pairs.where((p) => p.$1.category == preferred).toList();
    final candidates = preferredPairs.isNotEmpty ? preferredPairs : pairs;

    double walk((Waypoint, Waypoint) p) =>
        (graphs[start.floor]?.distance(start.globalStepIndex, p.$1.globalStepIndex) ?? double.infinity) +
        (graphs[destination.floor]?.distance(p.$2.globalStepIndex, destination.globalStepIndex) ?? double.infinity);

    final best = candidates.reduce((a, b) => walk(a) <= walk(b) ? a : b);
    return [
      TripLeg(floor: start.floor, from: start, to: best.$1),
      TripLeg(floor: destination.floor, from: best.$2, to: destination),
    ];
  }
}
