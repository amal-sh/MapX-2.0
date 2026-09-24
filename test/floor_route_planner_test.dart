import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/floor_graph.dart';
import 'package:mapx/logic/floor_route_planner.dart';
import 'package:mapx/models/map_models.dart';

/// A straight 1m-per-step corridor heading east, [steps] long.
FloorGraph corridor(int steps, int floor) {
  final segment = PathSegment(floor: floor);
  for (var i = 0; i < steps; i++) {
    segment.steps.add(RawStep(90, 1, floor: floor));
  }
  return FloorGraph.build([segment], floor);
}

void main() {
  final nodes = {0: corridor(20, 0), 2: corridor(20, 2)};

  test('same floor is a single leg', () {
    final a = Waypoint(0, 'Entrance', floor: 0);
    final b = Waypoint(10, 'Office', floor: 0);
    final legs = FloorRoutePlanner.plan(
      graphs: nodes,
      waypointsByFloor: {0: [a, b]},
      start: a,
      destination: b,
      preferLift: true,
    )!;
    expect(legs, hasLength(1));
    expect(legs.single.to, b);
  });

  test('links floors through connectors with the same type and name', () {
    final start = Waypoint(0, 'Entrance', floor: 0);
    final lift0 = Waypoint(5, 'Lift A', floor: 0, category: Waypoint.liftCategory);
    final lift2 = Waypoint(8, 'lift a ', floor: 2, category: Waypoint.liftCategory);
    final dest = Waypoint(15, 'Library', floor: 2);
    final legs = FloorRoutePlanner.plan(
      graphs: nodes,
      waypointsByFloor: {0: [start, lift0], 2: [lift2, dest]},
      start: start,
      destination: dest,
      preferLift: true,
    )!;
    expect(legs, hasLength(2));
    expect((legs[0].floor, legs[0].to), (0, lift0));
    expect((legs[1].floor, legs[1].from, legs[1].to), (2, lift2, dest));
  });

  test('returns null when no connector links the floors', () {
    final start = Waypoint(0, 'Entrance', floor: 0);
    final stairs0 = Waypoint(5, 'North', floor: 0, category: Waypoint.stairsCategory);
    final lift2 = Waypoint(8, 'North', floor: 2, category: Waypoint.liftCategory);
    final dest = Waypoint(15, 'Library', floor: 2);
    expect(
      FloorRoutePlanner.plan(
        graphs: nodes,
        waypointsByFloor: {0: [start, stairs0], 2: [lift2, dest]},
        start: start,
        destination: dest,
        preferLift: true,
      ),
      isNull,
    );
  });

  group('choosing between connectors', () {
    final start = Waypoint(0, 'Entrance', floor: 0);
    final dest = Waypoint(2, 'Library', floor: 2);
    // Stairs are near both ends; the lift is at the far end of each corridor.
    final stairs0 = Waypoint(1, 'Main', floor: 0, category: Waypoint.stairsCategory);
    final stairs2 = Waypoint(1, 'Main', floor: 2, category: Waypoint.stairsCategory);
    final lift0 = Waypoint(20, 'Lift', floor: 0, category: Waypoint.liftCategory);
    final lift2 = Waypoint(20, 'Lift', floor: 2, category: Waypoint.liftCategory);
    final waypoints = {0: [start, stairs0, lift0], 2: [stairs2, lift2, dest]};

    List<TripLeg> plan({required bool preferLift, Map<int, List<Waypoint>>? wps}) => FloorRoutePlanner.plan(
          graphs: nodes,
          waypointsByFloor: wps ?? waypoints,
          start: start,
          destination: dest,
          preferLift: preferLift,
        )!;

    test('uses the preferred type even when it is a longer walk', () {
      expect(plan(preferLift: true).first.to, lift0);
      expect(plan(preferLift: false).first.to, stairs0);
    });

    test('falls back to the other type when the preferred one is missing', () {
      final noLift = {0: [start, stairs0], 2: [stairs2, dest]};
      expect(plan(preferLift: true, wps: noLift).first.to, stairs0);
    });

    test('picks the shortest walk among the preferred type', () {
      final far0 = Waypoint(18, 'Back', floor: 0, category: Waypoint.stairsCategory);
      final far2 = Waypoint(18, 'Back', floor: 2, category: Waypoint.stairsCategory);
      final wps = {0: [start, far0, stairs0], 2: [far2, stairs2, dest]};
      expect(plan(preferLift: false, wps: wps).first.to, stairs0);
    });
  });

  test('waypoints compare by value so reloaded maps keep the selection', () {
    expect(Waypoint(3, 'Lift A', floor: 1, category: 'lift'), Waypoint(3, 'Lift A', floor: 1, category: 'lift'));
    expect(Waypoint(3, 'A', floor: 1, category: 'lift').displayName, 'Lift A');
    expect(Waypoint(3, 'Main Stairs', floor: 1, category: 'stairs').displayName, 'Main Stairs');
  });
}
