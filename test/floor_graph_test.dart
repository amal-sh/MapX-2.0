import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/floor_graph.dart';
import 'package:mapx/models/map_models.dart';

/// A U-shaped walk in 1m steps: 10m east, 6m north, 10m west.
/// Node 0 is (0, 0), node 10 is (10, 0), node 16 is (10, 6), node 26 is (0, 6).
List<PathSegment> uWalk() {
  PathSegment leg(double heading, int steps) {
    final s = PathSegment();
    for (var i = 0; i < steps; i++) {
      s.steps.add(RawStep(heading, 1));
    }
    return s;
  }

  return [leg(90, 10), leg(0, 6), leg(270, 10)];
}

double pathLength(FloorGraph g, List<int> path) {
  var d = 0.0;
  for (var i = 1; i < path.length; i++) {
    final a = g.nodes[path[i - 1]], b = g.nodes[path[i]];
    d += (Offset(a.east, a.north) - Offset(b.east, b.north)).distance;
  }
  return d;
}

void main() {
  test('without links, the walk is followed end to end', () {
    final g = FloorGraph.build(uWalk(), 0);
    expect(g.nodes, hasLength(27));
    expect(g.distance(0, 26), closeTo(26, 1e-9));
  });

  test('a drawn straight path is measured from map metres and used as a shortcut', () {
    final g = FloorGraph.build(uWalk(), 0, [const PathLink(fromNode: 0, toNode: 26)]);
    // 6m resampled every 0.5m: 11 new interior nodes.
    expect(g.nodes, hasLength(27 + 11));
    expect(g.linkLength(0, const PathLink(fromNode: 0, toNode: 26)), closeTo(6, 1e-9));
    expect(g.distance(0, 26), closeTo(6, 1e-9));
    final path = g.shortestPath(0, 26)!;
    expect(pathLength(g, path), closeTo(6, 1e-9));
    expect(path.skip(1).take(path.length - 2).every((n) => g.linkOfNode(n) == 0), isTrue);
  });

  test('bends are part of the drawn path and its length', () {
    const link = PathLink(fromNode: 0, toNode: 26, bends: [(-3, 0), (-3, 6)]);
    final g = FloorGraph.build(uWalk(), 0, [link]);
    expect(g.linkLength(0, link), closeTo(12, 1e-9));
    // The bend corners are nodes, so the route keeps its shape.
    expect(g.nodes.any((n) => n.east == -3 && n.north == 0), isTrue);
    expect(g.nodes.any((n) => n.east == -3 && n.north == 6), isTrue);
    expect(g.distance(0, 26), closeTo(12, 1e-9));
  });

  test('the walk is still used when it is shorter than the drawn path', () {
    // Detour far to the west: 30 + 6 + 30 = 66m, longer than the 26m walk.
    final g = FloorGraph.build(uWalk(), 0, [
      const PathLink(fromNode: 0, toNode: 26, bends: [(-30, 0), (-30, 6)]),
    ]);
    expect(g.distance(0, 26), closeTo(26, 1e-9));
  });

  test('nearestNode finds points on drawn paths', () {
    final g = FloorGraph.build(uWalk(), 0, [const PathLink(fromNode: 0, toNode: 26)]);
    final hit = g.nearestNode(0.1, 3.0);
    expect(g.linkOfNode(hit.index), 0);
    expect(hit.distance, closeTo(0.1, 1e-9));
  });

  test('a walked dead-end path ends at its last recorded point', () {
    // Walked 2m south from the walk's start, in 0.5m steps.
    const link = PathLink(fromNode: 0, toNode: null, bends: [(0, -0.5), (0, -1), (0, -1.5), (0, -2)]);
    final g = FloorGraph.build(uWalk(), 0, [link]);
    expect(g.linkNodeRanges.single, (27, 31));
    expect(g.linkLength(0, link), closeTo(2, 1e-9));
    expect(g.distance(0, 30), closeTo(2, 1e-9));
    // Reachable from anywhere on the walk, through its start.
    expect(g.distance(26, 30), closeTo(28, 1e-9));
    final end = g.nodes[30];
    expect((end.east, end.north), (0, -2));
  });

  test('deleting a path renumbers a later dead-end path', () {
    const shortcut = PathLink(fromNode: 0, toNode: 26);
    const deadEnd = PathLink(fromNode: 10, toNode: null, bends: [(10.5, 0), (11, 0)]);
    final links = [shortcut, deadEnd];
    final g = FloorGraph.build(uWalk(), 0, links);
    final tip = Waypoint(g.linkNodeRanges[1].$2 - 1, 'Store');
    final r = g.withoutLink(0, [tip], links);
    expect(r.links.single.toNode, isNull);
    final g2 = FloorGraph.build(uWalk(), 0, r.links);
    expect(g2.nodes[r.waypoints.single.globalStepIndex].east, closeTo(11, 1e-9));
  });

  group('deleting a drawn path', () {
    const shortcut = PathLink(fromNode: 0, toNode: 26); // nodes 27..37
    const across = PathLink(fromNode: 10, toNode: 16); // straight 6m, 11 nodes

    test('renumbers places on later paths', () {
      final links = [shortcut, across];
      final g = FloorGraph.build(uWalk(), 0, links);
      final onAcross = Waypoint(g.linkNodeRanges[1].$1 + 2, 'Desk');
      final onWalk = Waypoint(5, 'Door');
      final r = g.withoutLink(0, [onWalk, onAcross], links);

      expect(r.links, hasLength(1));
      final g2 = FloorGraph.build(uWalk(), 0, r.links);
      final desk = r.waypoints.firstWhere((w) => w.label == 'Desk');
      // Same physical spot as before.
      expect(g2.nodes[desk.globalStepIndex].east, g.nodes[onAcross.globalStepIndex].east);
      expect(g2.nodes[desk.globalStepIndex].north, g.nodes[onAcross.globalStepIndex].north);
      expect(r.waypoints.firstWhere((w) => w.label == 'Door').globalStepIndex, 5);
    });

    test('removes places on it and paths drawn from them', () {
      final g0 = FloorGraph.build(uWalk(), 0, [shortcut]);
      final midShortcut = g0.linkNodeRanges[0].$1 + 5;
      final fromMid = PathLink(fromNode: midShortcut, toNode: 10);
      final links = [shortcut, fromMid];
      final g = FloorGraph.build(uWalk(), 0, links);
      final r = g.withoutLink(0, [Waypoint(midShortcut, 'Kiosk'), Waypoint(10, 'Lab')], links);

      expect(r.links, isEmpty);
      expect(r.waypoints.map((w) => w.label), ['Lab']);
    });
  });
}
