import 'dart:math';

import '../models/map_models.dart';

/// A turn along a route, at a given arc-length distance from the route's
/// start.
class TurnInstruction {
  final double distance;
  final double angleDeltaDeg; // signed: positive = right, negative = left
  final String label;

  const TurnInstruction({
    required this.distance,
    required this.angleDeltaDeg,
    required this.label,
  });
}

/// Finds turns along [route] by looking for where the stored per-node
/// heading changes from one node to the next. Turns in this project are
/// explicitly marked by the admin while mapping (see mapping_screen.dart's
/// "Register Turn" flow, which starts a new recorded segment with its own
/// averaged heading) rather than inferred from noisy raw motion, so a
/// heading change between consecutive nodes is a real, deliberate turn, not
/// a threshold guess.
List<TurnInstruction> computeTurnInstructions(List<PathNode> route) {
  final instructions = <TurnInstruction>[];
  double dist = 0;
  for (var i = 1; i < route.length; i++) {
    final prev = route[i - 1];
    final cur = route[i];
    dist += sqrt(pow(cur.east - prev.east, 2) + pow(cur.north - prev.north, 2));

    if (i < 2) continue;
    var delta = route[i].heading - route[i - 1].heading;
    delta = ((delta + 180) % 360 + 360) % 360 - 180; // normalize to [-180, 180)
    if (delta.abs() > 15) {
      instructions.add(TurnInstruction(distance: dist, angleDeltaDeg: delta, label: _classify(delta)));
    }
  }
  return instructions;
}

String _classify(double delta) {
  final magnitude = delta.abs();
  final dir = delta > 0 ? 'right' : 'left';
  if (magnitude > 150) return 'Make a U-turn';
  if (magnitude > 100) return 'Sharp turn $dir';
  if (magnitude > 45) return 'Turn $dir';
  return 'Bear $dir';
}
