import 'dart:math';
import '../models/map_models.dart';

enum FloorTransitionState {
  navigatingFloor,
  approachingTransition,
  inTransition,
  completed,
}

/// Coordinates vertical transitions (stairs/elevators) between floors
/// and manages active floor state.
class FloorTransitionManager {
  int currentFloor;
  final List<FloorTransition> transitions;
  FloorTransitionState state = FloorTransitionState.navigatingFloor;
  FloorTransition? activeTransition;

  FloorTransitionManager({
    required this.currentFloor,
    this.transitions = const [],
  });

  /// Evaluates distance to any known floor transition on the current floor.
  ({bool isNearTransition, FloorTransition? transition, double distance}) checkTransitionProximity({
    required double userEast,
    required double userNorth,
    required List<PathNode> routeNodes,
    double triggerRadius = 2.5,
  }) {
    for (final trans in transitions) {
      if (trans.fromFloor != currentFloor) continue;

      if (trans.entryStepIndex < routeNodes.length) {
        final node = routeNodes[trans.entryStepIndex];
        final dist = sqrt(pow(node.east - userEast, 2) + pow(node.north - userNorth, 2));

        if (dist <= triggerRadius) {
          activeTransition = trans;
          state = FloorTransitionState.approachingTransition;
          return (isNearTransition: true, transition: trans, distance: dist);
        }
      }
    }

    if (state == FloorTransitionState.approachingTransition) {
      state = FloorTransitionState.navigatingFloor;
      activeTransition = null;
    }

    return (isNearTransition: false, transition: null, distance: double.infinity);
  }

  /// User confirms arrival on the new floor by tapping the button.
  void confirmArrivalAtTargetFloor(int targetFloor) {
    currentFloor = targetFloor;
    state = FloorTransitionState.completed;
    activeTransition = null;
  }

  /// Filters waypoints to only show those on the active floor.
  List<Waypoint> filterWaypointsForActiveFloor(List<Waypoint> waypoints) {
    return waypoints.where((wp) => wp.floor == currentFloor).toList();
  }

  /// Filters route nodes to only show those on the active floor.
  List<PathNode> filterNodesForActiveFloor(List<PathNode> nodes) {
    return nodes.where((n) => n.floor == currentFloor).toList();
  }
}
