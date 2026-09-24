import 'dart:collection';
import 'dart:math';

import '../models/map_models.dart';

/// One floor's walkable network: the originally walked path plus any paths
/// drawn in the map editor ([PathLink]s).
///
/// Node indices are what [Waypoint.globalStepIndex] refers to. The walked
/// path's nodes come first (index = step number, as before links existed),
/// followed by each link's nodes in link order. A link is resampled into a
/// node every [linkNodeSpacing] metres so places can be marked along it and
/// the AR route gets the same node density as a walked path.
class FloorGraph {
  /// Never change this: stored waypoints on links index into nodes whose
  /// count depends on it.
  static const double linkNodeSpacing = 0.5;

  final List<PathNode> nodes;
  final int walkNodeCount;

  /// Undirected edges as (a, b) node index pairs.
  final List<(int, int)> edges;

  /// For each link, the range [start, end) of node indices it added.
  final List<(int, int)> linkNodeRanges;

  final List<List<(int, double)>> _adjacency;
  final Map<(int, int), List<int>?> _pathCache = {};

  FloorGraph._(this.nodes, this.walkNodeCount, this.edges, this.linkNodeRanges)
      : _adjacency = List.generate(nodes.length, (_) => []) {
    for (final (a, b) in edges) {
      final d = _dist(nodes[a], nodes[b]);
      _adjacency[a].add((b, d));
      _adjacency[b].add((a, d));
    }
  }

  factory FloorGraph.build(List<PathSegment> segments, int floor, [List<PathLink> links = const []]) {
    final nodes = walkNodes(segments, floor);
    final walkCount = nodes.length;
    final edges = <(int, int)>[for (var i = 1; i < walkCount; i++) (i - 1, i)];
    final ranges = <(int, int)>[];

    for (final link in links) {
      final rangeStart = nodes.length;
      final toNode = link.toNode;
      if (link.fromNode >= rangeStart || (toNode != null && toNode >= rangeStart) || (toNode == null && link.bends.isEmpty)) {
        // Refers to a node that no longer exists (corrupt data): skip it.
        ranges.add((rangeStart, rangeStart));
        continue;
      }
      final a = nodes[link.fromNode];
      final b = toNode == null ? null : nodes[toNode];
      final corners = <(double, double)>[(a.east, a.north), ...link.bends, if (b != null) (b.east, b.north)];

      var prev = link.fromNode;
      for (var c = 1; c < corners.length; c++) {
        final (e0, n0) = corners[c - 1];
        final (e1, n1) = corners[c];
        final len = sqrt(pow(e1 - e0, 2) + pow(n1 - n0, 2));
        final heading = (atan2(e1 - e0, n1 - n0) * 180 / pi + 360) % 360;
        final pieces = max(1, (len / linkNodeSpacing).round());
        final endsOnExistingNode = b != null && c == corners.length - 1;
        // Interior points of this straight piece, plus the corner at its end
        // unless that is the existing node b.
        for (var k = 1; k <= pieces; k++) {
          if (endsOnExistingNode && k == pieces) break;
          final u = k / pieces;
          nodes.add(PathNode(nodes.length, heading, e0 + (e1 - e0) * u, n0 + (n1 - n0) * u, floor: floor));
          edges.add((prev, nodes.length - 1));
          prev = nodes.length - 1;
        }
      }
      if (toNode != null) edges.add((prev, toNode));
      ranges.add((rangeStart, nodes.length));
    }
    return FloorGraph._(nodes, walkCount, edges, ranges);
  }

  /// The walked path, dead-reckoned from its segments.
  static List<PathNode> walkNodes(List<PathSegment> segments, int floor) {
    final List<PathNode> nodes = [];
    double currentEast = 0;
    double currentNorth = 0;

    final initialHeading = segments.isNotEmpty && segments.first.steps.isNotEmpty
        ? segments.first.steps.first.heading
        : 0.0;
    nodes.add(PathNode(0, initialHeading, currentEast, currentNorth, floor: floor));

    int index = 1;
    for (final segment in segments) {
      final avgHeadingRad = segment.averageHeading * pi / 180.0;
      for (final step in segment.steps) {
        currentEast += step.length * sin(avgHeadingRad);
        currentNorth += step.length * cos(avgHeadingRad);
        nodes.add(PathNode(index++, segment.averageHeading, currentEast, currentNorth, floor: segment.floor));
      }
    }
    return nodes;
  }

  static double _dist(PathNode a, PathNode b) => sqrt(pow(a.east - b.east, 2) + pow(a.north - b.north, 2));

  /// Node indices of the shortest walk from [from] to [to], or null if they
  /// aren't connected.
  List<int>? shortestPath(int from, int to) {
    if (from < 0 || to < 0 || from >= nodes.length || to >= nodes.length) return null;
    return _pathCache.putIfAbsent((from, to), () => _dijkstra(from, to));
  }

  List<int>? _dijkstra(int from, int to) {
    final dist = List<double>.filled(nodes.length, double.infinity);
    final prev = List<int>.filled(nodes.length, -1);
    dist[from] = 0;
    final queue = SplayTreeSet<(double, int)>((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2))
      ..add((0, from));
    while (queue.isNotEmpty) {
      final (d, u) = queue.first;
      queue.remove(queue.first);
      if (u == to) break;
      if (d > dist[u]) continue;
      for (final (v, w) in _adjacency[u]) {
        final nd = d + w;
        if (nd < dist[v]) {
          queue.remove((dist[v], v));
          dist[v] = nd;
          prev[v] = u;
          queue.add((nd, v));
        }
      }
    }
    if (dist[to] == double.infinity) return null;
    final path = <int>[to];
    while (path.last != from) {
      path.add(prev[path.last]);
    }
    return path.reversed.toList();
  }

  /// Walking distance between two nodes, or infinity if unconnected.
  double distance(int from, int to) {
    final path = shortestPath(from, to);
    if (path == null) return double.infinity;
    var d = 0.0;
    for (var i = 1; i < path.length; i++) {
      d += _dist(nodes[path[i - 1]], nodes[path[i]]);
    }
    return d;
  }

  /// The node closest to a map point.
  ({int index, double distance}) nearestNode(double east, double north) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < nodes.length; i++) {
      final d = sqrt(pow(nodes[i].east - east, 2) + pow(nodes[i].north - north, 2));
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return (index: best, distance: bestD);
  }

  /// Which link a node belongs to, or null for the walked path.
  int? linkOfNode(int node) {
    for (var i = 0; i < linkNodeRanges.length; i++) {
      final (s, e) = linkNodeRanges[i];
      if (node >= s && node < e) return i;
    }
    return null;
  }

  /// Length in metres of the link at [linkIndex].
  double linkLength(int linkIndex, PathLink link) {
    final (s, e) = linkNodeRanges[linkIndex];
    final chain = [link.fromNode, for (var i = s; i < e; i++) i, ?link.toNode];
    var d = 0.0;
    for (var i = 1; i < chain.length; i++) {
      d += _dist(nodes[chain[i - 1]], nodes[chain[i]]);
    }
    return d;
  }

  /// [waypoints] and [links] with link [linkIndex] removed, along with
  /// anything anchored on its nodes (places, and links drawn from those
  /// places); nodes of later links are renumbered to match.
  ({List<Waypoint> waypoints, List<PathLink> links}) withoutLink(
      int linkIndex, List<Waypoint> waypoints, List<PathLink> links) {
    // A node as (link, offset within it); link -1 is the walked path.
    (int, int) ref(int node) {
      final l = linkOfNode(node);
      return l == null ? (-1, node) : (l, node - linkNodeRanges[l].$1);
    }

    final removed = {linkIndex};
    var grew = true;
    while (grew) {
      grew = false;
      for (var j = 0; j < links.length; j++) {
        if (removed.contains(j)) continue;
        final to = links[j].toNode;
        if (removed.contains(ref(links[j].fromNode).$1) || (to != null && removed.contains(ref(to).$1))) {
          removed.add(j);
          grew = true;
        }
      }
    }

    // New first-node index of each surviving link.
    final newStart = <int, int>{};
    var next = walkNodeCount;
    for (var j = 0; j < links.length; j++) {
      if (removed.contains(j)) continue;
      newStart[j] = next;
      next += linkNodeRanges[j].$2 - linkNodeRanges[j].$1;
    }
    int? remap(int node) {
      final (l, offset) = ref(node);
      if (l == -1) return node;
      final start = newStart[l];
      return start == null ? null : start + offset;
    }

    return (
      waypoints: [
        for (final w in waypoints)
          if (remap(w.globalStepIndex) case final n?) Waypoint(n, w.label, floor: w.floor, category: w.category),
      ],
      links: [
        for (var j = 0; j < links.length; j++)
          if (!removed.contains(j))
            PathLink(
              fromNode: remap(links[j].fromNode)!,
              toNode: links[j].toNode == null ? null : remap(links[j].toNode!)!,
              bends: links[j].bends,
            ),
      ],
    );
  }
}
