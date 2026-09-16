import 'dart:math';

class PathNode {
  final int index;
  final double heading;
  final double east;
  final double north;

  PathNode(this.index, this.heading, this.east, this.north);
}

class RawStep {
  final double heading;
  final double length;
  RawStep(this.heading, this.length);

  Map<String, dynamic> toJson() => {
    'heading': heading,
    'length': length,
  };

  factory RawStep.fromJson(Map<String, dynamic> json) => RawStep(
    (json['heading'] as num).toDouble(),
    (json['length'] as num).toDouble(),
  );
}

class PathSegment {
  PathSegment();
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
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  factory PathSegment.fromJson(Map<String, dynamic> json) {
    final segment = PathSegment();
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

  Waypoint(this.globalStepIndex, this.label);

  Map<String, dynamic> toJson() => {
    'globalStepIndex': globalStepIndex,
    'label': label,
  };

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
    json['globalStepIndex'] as int,
    json['label'] as String,
  );
}
