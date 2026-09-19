import 'dart:math';

enum TransitionType {
  stairs,
  elevator,
  ramp,
}

/// Represents a physical wall boundary in map coordinates (East/North meters).
class WallSegment {
  final double startEast;
  final double startNorth;
  final double endEast;
  final double endNorth;
  final double heightMeters;

  const WallSegment({
    required this.startEast,
    required this.startNorth,
    required this.endEast,
    required this.endNorth,
    this.heightMeters = 2.8,
  });

  Map<String, dynamic> toJson() => {
    'startEast': startEast,
    'startNorth': startNorth,
    'endEast': endEast,
    'endNorth': endNorth,
    'heightMeters': heightMeters,
  };

  factory WallSegment.fromJson(Map<String, dynamic> json) => WallSegment(
    startEast: (json['startEast'] as num).toDouble(),
    startNorth: (json['startNorth'] as num).toDouble(),
    endEast: (json['endEast'] as num).toDouble(),
    endNorth: (json['endNorth'] as num).toDouble(),
    heightMeters: (json['heightMeters'] as num?)?.toDouble() ?? 2.8,
  );
}

/// Defines a vertical floor transition (e.g. stairs or elevator) linking two floor graphs.
class FloorTransition {
  final String id;
  final TransitionType type;
  final int fromFloor;
  final int toFloor;
  final int entryStepIndex;
  final int exitStepIndex;
  final String label;

  const FloorTransition({
    required this.id,
    required this.type,
    required this.fromFloor,
    required this.toFloor,
    required this.entryStepIndex,
    required this.exitStepIndex,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'fromFloor': fromFloor,
    'toFloor': toFloor,
    'entryStepIndex': entryStepIndex,
    'exitStepIndex': exitStepIndex,
    'label': label,
  };

  factory FloorTransition.fromJson(Map<String, dynamic> json) => FloorTransition(
    id: json['id'] as String? ?? '',
    type: TransitionType.values.firstWhere(
      (t) => t.name == (json['type'] as String?),
      orElse: () => TransitionType.stairs,
    ),
    fromFloor: json['fromFloor'] as int? ?? 0,
    toFloor: json['toFloor'] as int? ?? 1,
    entryStepIndex: json['entryStepIndex'] as int? ?? 0,
    exitStepIndex: json['exitStepIndex'] as int? ?? 0,
    label: json['label'] as String? ?? 'Stairwell',
  );
}

class PathNode {
  final int index;
  final double heading;
  final double east;
  final double north;
  final int floor;
  final double elevation;

  PathNode(
    this.index,
    this.heading,
    this.east,
    this.north, {
    this.floor = 0,
    this.elevation = 0.0,
  });
}

class RawStep {
  final double heading;
  final double length;
  final int floor;

  RawStep(this.heading, this.length, {this.floor = 0});

  Map<String, dynamic> toJson() => {
    'heading': heading,
    'length': length,
    'floor': floor,
  };

  factory RawStep.fromJson(Map<String, dynamic> json) => RawStep(
    (json['heading'] as num).toDouble(),
    (json['length'] as num).toDouble(),
    floor: json['floor'] as int? ?? 0,
  );
}

class PathSegment {
  PathSegment({this.floor = 0});
  final int floor;
  final List<RawStep> steps = [];

  double get averageHeading {
    if (steps.isEmpty) return 0;
    double sumSin = 0;
    double sumCos = 0;
    for (final step in steps) {
      final rad = step.heading * pi / 180.0;
      sumSin += sin(rad);
      sumCos += cos(rad);
    }
    return atan2(sumSin, sumCos) * 180.0 / pi;
  }

  Map<String, dynamic> toJson() => {
    'floor': floor,
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  factory PathSegment.fromJson(Map<String, dynamic> json) {
    final segment = PathSegment(floor: json['floor'] as int? ?? 0);
    if (json['steps'] != null) {
      for (var s in json['steps']) {
        segment.steps.add(RawStep.fromJson(s));
      }
    }
    return segment;
  }
}

class Waypoint {
  final int globalStepIndex;
  final String label;
  final int floor;
  final String category;

  Waypoint(
    this.globalStepIndex,
    this.label, {
    this.floor = 0,
    this.category = 'room',
  });

  Map<String, dynamic> toJson() => {
    'globalStepIndex': globalStepIndex,
    'label': label,
    'floor': floor,
    'category': category,
  };

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
    json['globalStepIndex'] as int,
    json['label'] as String,
    floor: json['floor'] as int? ?? 0,
    category: json['category'] as String? ?? 'room',
  );
}
