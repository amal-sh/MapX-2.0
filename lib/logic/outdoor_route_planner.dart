import '../models/outdoor_models.dart';
import '../models/map_models.dart';
import 'floor_graph.dart';
import 'floor_route_planner.dart';

/// The outdoor walk between two buildings, taken after an indoor leg.
class OutdoorHop {
  final BuildingConnection connection;
  final String fromBuilding;

  const OutdoorHop(this.connection, this.fromBuilding);

  String get toBuilding => connection.otherEnd(fromBuilding).building;
  EntranceRef get exit => connection.entranceIn(fromBuilding);
  EntranceRef get arrival => connection.otherEnd(fromBuilding);

  /// The route in walking order.
  List<GeoPoint> get route => connection.routeFrom(fromBuilding);
}

/// A trip, possibly through several floors and two buildings: indoor [legs]
/// in order, with an outdoor walk after some of them.
class OutdoorTrip {
  final List<TripLeg> legs;

  /// Index of a leg -> the outdoor walk taken after it.
  final Map<int, OutdoorHop> outdoorAfterLeg;
  final double distanceMeters;

  const OutdoorTrip(this.legs, this.outdoorAfterLeg, this.distanceMeters);
}

/// Plans trips between places in the same or different buildings. Inside a
/// building it uses [FloorRoutePlanner] (stairs/lifts between floors); between
/// buildings it walks to an entrance linked by a [BuildingConnection], goes
/// outside, and continues from the linked entrance of the other building.
/// Only direct connections are used (no passing through a third building).
class OutdoorRoutePlanner {
  static OutdoorTrip? plan({
    required Map<String, Map<int, FloorGraph>> graphs,
    required Map<String, Map<int, List<Waypoint>>> waypoints,
    required List<BuildingConnection> connections,
    required String startBuilding,
    required Waypoint start,
    required String destinationBuilding,
    required Waypoint destination,
    required bool preferLift,
  }) {
    List<TripLeg>? indoor(String building, Waypoint from, Waypoint to) {
      final legs = FloorRoutePlanner.plan(
        graphs: graphs[building] ?? const {},
        waypointsByFloor: waypoints[building] ?? const {},
        start: from,
        destination: to,
        preferLift: preferLift,
      );
      return legs?.map((l) => TripLeg(floor: l.floor, from: l.from, to: l.to, building: building)).toList();
    }

    double length(List<TripLeg> legs) {
      var d = 0.0;
      for (final l in legs) {
        d += graphs[l.building]?[l.floor]?.distance(l.from.globalStepIndex, l.to.globalStepIndex) ?? double.infinity;
      }
      return d;
    }

    if (startBuilding == destinationBuilding) {
      final legs = indoor(startBuilding, start, destination);
      return legs == null ? null : OutdoorTrip(legs, const {}, length(legs));
    }

    Waypoint? entrance(EntranceRef ref) =>
        (waypoints[ref.building]?[ref.floor] ?? const <Waypoint>[]).where(ref.matches).firstOrNull;

    OutdoorTrip? best;
    for (final c in connections.where((c) => c.connects(startBuilding, destinationBuilding))) {
      final exit = entrance(c.entranceIn(startBuilding));
      final arrival = entrance(c.otherEnd(startBuilding));
      if (exit == null || arrival == null) continue;
      final before = indoor(startBuilding, start, exit);
      final after = indoor(destinationBuilding, arrival, destination);
      if (before == null || after == null) continue;
      final total = length(before) + c.distanceMeters + length(after);
      if (!total.isFinite || (best != null && total >= best.distanceMeters)) continue;
      best = OutdoorTrip(
        [...before, ...after],
        {before.length - 1: OutdoorHop(c, startBuilding)},
        total,
      );
    }
    return best;
  }
}
