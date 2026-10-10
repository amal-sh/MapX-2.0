import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/outdoor_route_planner.dart';
import 'package:mapx/logic/floor_graph.dart';
import 'package:mapx/logic/geo_math.dart';
import 'package:mapx/models/outdoor_models.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/services/routing_service.dart';

/// A straight corridor of [steps] 1m steps heading east.
FloorGraph corridor(int steps, int floor) {
  final s = PathSegment(floor: floor);
  for (var i = 0; i < steps; i++) {
    s.steps.add(RawStep(90, 1, floor: floor));
  }
  return FloorGraph.build([s], floor);
}

Waypoint entrance(int index, String label, {int floor = 0}) =>
    Waypoint(index, label, floor: floor, category: Waypoint.entranceCategory, latitude: 10, longitude: 20);

BuildingConnection link(String a, String ea, String b, String eb, double meters, {int floorA = 0, int floorB = 0}) =>
    BuildingConnection(
      a: EntranceRef(building: a, floor: floorA, label: ea),
      b: EntranceRef(building: b, floor: floorB, label: eb),
      distanceMeters: meters,
      durationSeconds: meters / 1.3,
      route: const [(10.0, 20.0), (10.001, 20.001)],
    );

void main() {
  group('geo maths', () {
    test('haversine matches known distances', () {
      // One degree of latitude is about 111.2 km.
      expect(haversineMeters((0, 0), (1, 0)), closeTo(111195, 50));
      expect(haversineMeters((12.97, 77.59), (12.97, 77.59)), 0);
    });

    test('progress along a route: closest point, offset and distance left', () {
      // About 111 m north, then about 111 m east (near the equator).
      const route = <GeoPoint>[(0, 0), (0.001, 0), (0.001, 0.001)];
      final total = polylineMeters(route);
      expect(total, closeTo(222.4, 0.5));

      // Halfway up the first leg, 10 m to the east of it.
      final p = progressAlongRoute(route, (0.0005, 0.00009));
      expect(p.segment, 0);
      expect(p.offRouteMeters, closeTo(10, 0.5));
      expect(p.remainingMeters, closeTo(total * 0.75, 0.5));

      // Past the end: nothing left.
      expect(progressAlongRoute(route, (0.001, 0.002)).remainingMeters, closeTo(0, 1e-6));
    });

    test('bearing points the right way', () {
      expect(bearingDegrees((0, 0), (1, 0)), closeTo(0, 1e-6));
      expect(bearingDegrees((0, 0), (0, 1)), closeTo(90, 1e-6));
    });
  });

  group('OSRM route parsing', () {
    const from = (12.9716, 77.5946), to = (12.9726, 77.5956);

    test('reads the footpath and adds the exact entrance points at both ends', () {
      final route = RoutingService.parseOsrm({
        'code': 'Ok',
        'routes': [
          {
            'distance': 160.0,
            'duration': 120.0,
            'geometry': {
              'coordinates': [
                [77.5947, 12.9717],
                [77.5955, 12.9725],
              ],
            },
          },
        ],
      }, from, to);
      expect(route.points.first, from);
      expect(route.points[1], (12.9717, 77.5947)); // [lng, lat] swapped into (lat, lng)
      expect(route.points.last, to);
      expect(route.distanceMeters, closeTo(polylineMeters(route.points), 1e-9));
      expect(route.durationSeconds, 120);
      expect(route.source, 'osrm');
    });

    test('reports when there is no route', () {
      expect(
        () => RoutingService.parseOsrm({'code': 'NoRoute', 'routes': []}, from, to),
        throwsA(isA<RoutingException>()),
      );
    });

    test('a straight-line fallback is measured too', () {
      final r = WalkingRoute.straight(from, to);
      expect(r.points, [from, to]);
      expect(r.distanceMeters, closeTo(haversineMeters(from, to), 1e-9));
    });
  });

  group('places and connections', () {
    test('entrance GPS survives storage and renumbering but not equality', () {
      final e = entrance(4, 'North Gate');
      final back = Waypoint.fromJson(e.toJson());
      expect((back.latitude, back.longitude), (10, 20));
      expect(e.withIndex(7).hasGps, isTrue);
      expect(Waypoint(4, 'North Gate', category: Waypoint.entranceCategory), e);
      expect(Waypoint(1, 'Main', category: Waypoint.entranceCategory).displayName, 'Entrance Main');
      expect(Waypoint(1, 'Main Gate', category: Waypoint.entranceCategory).displayName, 'Main Gate');
    });

    test('a connection stores its route and can be walked either way', () {
      final c = link('Library', 'Front', 'Lab', 'Side', 120);
      final back = BuildingConnection.fromJson(c.toJson());
      expect(back.id, c.id);
      expect(back.route, c.route);
      expect(back.routeFrom('Lab'), c.route.reversed.toList());
      expect(back.otherEnd('Lab').building, 'Library');
      expect(back.connects('Lab', 'Library'), isTrue);
    });
  });

  group('trips between buildings', () {
    // Library: floor 0 has the entrance at the start of its corridor and a lift
    // at the end; floor 1 has the same lift and a reading room.
    // Lab: one floor, entrance at the start, office at the end.
    final graphs = {
      'Library': {0: corridor(10, 0), 1: corridor(10, 1)},
      'Lab': {0: corridor(20, 0)},
    };
    final reading = Waypoint(2, 'Reading Room', floor: 1);
    final office = Waypoint(20, 'Office');
    final waypoints = {
      'Library': {
        0: [entrance(0, 'Front'), Waypoint(10, 'A', floor: 0, category: Waypoint.liftCategory)],
        1: [Waypoint(10, 'A', floor: 1, category: Waypoint.liftCategory), reading],
      },
      'Lab': {
        0: [entrance(0, 'Side'), entrance(15, 'Back'), office],
      },
    };

    OutdoorTrip? plan(List<BuildingConnection> links) => OutdoorRoutePlanner.plan(
          graphs: graphs,
          waypoints: waypoints,
          connections: links,
          startBuilding: 'Library',
          start: reading,
          destinationBuilding: 'Lab',
          destination: office,
          preferLift: true,
        );

    test('goes down by lift, out the entrance, and on inside the other building', () {
      final trip = plan([link('Lab', 'Side', 'Library', 'Front', 100)])!;
      expect([for (final l in trip.legs) (l.building, l.floor, l.from.label, l.to.label)], [
        ('Library', 1, 'Reading Room', 'A'),
        ('Library', 0, 'A', 'Front'),
        ('Lab', 0, 'Side', 'Office'),
      ]);
      final hop = trip.outdoorAfterLeg[1]!;
      expect((hop.fromBuilding, hop.toBuilding, hop.arrival.label), ('Library', 'Lab', 'Side'));
      // Seen from the Library, the stored Lab -> Library route runs backwards.
      expect(hop.route.first, hop.connection.route.last);
      // 8 m to the lift + 10 m to the entrance + 100 m outside + 20 m to the office.
      expect(trip.distanceMeters, closeTo(138, 1e-9));
    });

    test('picks the link with the shortest total walk', () {
      final trip = plan([
        link('Library', 'Front', 'Lab', 'Side', 100), // 18 + 100 + 20 = 138
        link('Library', 'Front', 'Lab', 'Back', 90), // 18 + 90 + 5 = 113
      ])!;
      expect(trip.legs.last.from.label, 'Back');
      expect(trip.distanceMeters, closeTo(113, 1e-9));
    });

    test('no link, or a link to an entrance that no longer exists, means no trip', () {
      expect(plan([]), isNull);
      expect(plan([link('Library', 'Front', 'Lab', 'Renamed', 50)]), isNull);
    });
  });
}
