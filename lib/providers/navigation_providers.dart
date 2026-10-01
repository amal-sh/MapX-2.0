import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/floor_route_planner.dart';
import '../logic/route_instructions.dart';
import '../logic/spatial_sensor_fusion.dart';
import '../models/map_models.dart';

/// Immutable state describing an active navigation session.
class NavigationSessionState {
  final int currentFloor;
  final bool preferLift;
  final List<TripLeg>? activeLegs;
  final int currentLegIndex;
  final bool isAtConnector;
  final Waypoint? startLocation;
  final Waypoint? destination;
  final bool isArMode;
  final TrackingConfidence trackingConfidence;
  final bool isDrifting;
  final String driftReason;
  final List<TurnInstruction> turnInstructions;
  final bool isFacingPath;
  final bool isTravelingBackward;
  final double extraTurnDistance;
  final double offPathAngleDelta;
  final String turnDirection;
  final double liveProgress;
  final double routeTotalDistance;

  const NavigationSessionState({
    this.currentFloor = 0,
    this.preferLift = true,
    this.activeLegs,
    this.currentLegIndex = 0,
    this.isAtConnector = false,
    this.startLocation,
    this.destination,
    this.isArMode = false,
    this.trackingConfidence = TrackingConfidence.medium,
    this.isDrifting = false,
    this.driftReason = '',
    this.turnInstructions = const [],
    this.isFacingPath = true,
    this.isTravelingBackward = false,
    this.extraTurnDistance = 0.0,
    this.offPathAngleDelta = 0.0,
    this.turnDirection = 'straight',
    this.liveProgress = 0.0,
    this.routeTotalDistance = 0.0,
  });

  TripLeg? get currentLeg {
    if (activeLegs == null || currentLegIndex >= activeLegs!.length) return null;
    return activeLegs![currentLegIndex];
  }

  bool get isMultiFloorRoute => activeLegs != null && activeLegs!.length > 1;

  NavigationSessionState copyWith({
    int? currentFloor,
    bool? preferLift,
    List<TripLeg>? activeLegs,
    int? currentLegIndex,
    bool? isAtConnector,
    Waypoint? startLocation,
    Waypoint? destination,
    bool? isArMode,
    TrackingConfidence? trackingConfidence,
    bool? isDrifting,
    String? driftReason,
    List<TurnInstruction>? turnInstructions,
    bool? isFacingPath,
    bool? isTravelingBackward,
    double? extraTurnDistance,
    double? offPathAngleDelta,
    String? turnDirection,
    double? liveProgress,
    double? routeTotalDistance,
  }) {
    return NavigationSessionState(
      currentFloor: currentFloor ?? this.currentFloor,
      preferLift: preferLift ?? this.preferLift,
      activeLegs: activeLegs ?? this.activeLegs,
      currentLegIndex: currentLegIndex ?? this.currentLegIndex,
      isAtConnector: isAtConnector ?? this.isAtConnector,
      startLocation: startLocation ?? this.startLocation,
      destination: destination ?? this.destination,
      isArMode: isArMode ?? this.isArMode,
      trackingConfidence: trackingConfidence ?? this.trackingConfidence,
      isDrifting: isDrifting ?? this.isDrifting,
      driftReason: driftReason ?? this.driftReason,
      turnInstructions: turnInstructions ?? this.turnInstructions,
      isFacingPath: isFacingPath ?? this.isFacingPath,
      isTravelingBackward: isTravelingBackward ?? this.isTravelingBackward,
      extraTurnDistance: extraTurnDistance ?? this.extraTurnDistance,
      offPathAngleDelta: offPathAngleDelta ?? this.offPathAngleDelta,
      turnDirection: turnDirection ?? this.turnDirection,
      liveProgress: liveProgress ?? this.liveProgress,
      routeTotalDistance: routeTotalDistance ?? this.routeTotalDistance,
    );
  }
}

/// Notifier managing high-level navigation routing, cross-floor legs, and AR mode.
class NavigationNotifier extends Notifier<NavigationSessionState> {
  @override
  NavigationSessionState build() {
    return const NavigationSessionState();
  }

  void setCurrentFloor(int floor) {
    state = state.copyWith(currentFloor: floor);
  }

  void setPreferLift(bool prefer) {
    state = state.copyWith(preferLift: prefer);
  }

  void setRoute({
    required Waypoint? start,
    required Waypoint? destination,
    required List<TripLeg>? legs,
    required double totalDistance,
    required List<TurnInstruction> instructions,
  }) {
    state = state.copyWith(
      startLocation: start,
      destination: destination,
      activeLegs: legs,
      currentLegIndex: 0,
      isAtConnector: false,
      routeTotalDistance: totalDistance,
      turnInstructions: instructions,
    );
  }

  void setArMode(bool isAr) {
    state = state.copyWith(isArMode: isAr);
  }

  void setAtConnector(bool atConnector) {
    state = state.copyWith(isAtConnector: atConnector);
  }

  void proceedToNextLeg() {
    if (state.activeLegs != null && state.currentLegIndex + 1 < state.activeLegs!.length) {
      final nextIdx = state.currentLegIndex + 1;
      final nextFloor = state.activeLegs![nextIdx].floor;
      state = state.copyWith(
        currentLegIndex: nextIdx,
        currentFloor: nextFloor,
        isAtConnector: false,
      );
    }
  }

  void updateTrackingStatus({
    required TrackingConfidence confidence,
    required bool isDrifting,
    required String driftReason,
    required double liveProgress,
    required bool isFacingPath,
    required bool isTravelingBackward,
    required double extraTurnDistance,
    required double offPathAngleDelta,
    required String turnDirection,
  }) {
    state = state.copyWith(
      trackingConfidence: confidence,
      isDrifting: isDrifting,
      driftReason: driftReason,
      liveProgress: liveProgress,
      isFacingPath: isFacingPath,
      isTravelingBackward: isTravelingBackward,
      extraTurnDistance: extraTurnDistance,
      offPathAngleDelta: offPathAngleDelta,
      turnDirection: turnDirection,
    );
  }

  void resetNavigation() {
    state = NavigationSessionState(currentFloor: state.currentFloor);
  }
}

/// Provider for the active navigation session.
final navigationProvider = NotifierProvider<NavigationNotifier, NavigationSessionState>(
  NavigationNotifier.new,
);
