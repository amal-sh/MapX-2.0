/// One completed indoor/outdoor navigation, stored offline on the device
/// in SharedPreferences (no account, so nothing is pushed to Firebase).
class NavigationTrip {
  final String id;
  final String fromBuilding;
  final int? fromFloor;
  final String fromLabel;
  final String toBuilding;
  final int? toFloor;
  final String toLabel;
  final double? distanceMeters;
  final DateTime completedAt;

  const NavigationTrip({
    required this.id,
    required this.fromBuilding,
    this.fromFloor,
    required this.fromLabel,
    required this.toBuilding,
    this.toFloor,
    required this.toLabel,
    this.distanceMeters,
    required this.completedAt,
  });

  String get title => '$fromLabel → $toLabel';

  String get routeSummary {
    final fromFloorBit = fromFloor == null ? '' : ' · F$fromFloor';
    final toFloorBit = toFloor == null ? '' : ' · F$toFloor';
    if (fromBuilding == toBuilding) {
      return '$fromBuilding$fromFloorBit → $toLabel$toFloorBit';
    }
    return '$fromBuilding$fromFloorBit → $toBuilding$toFloorBit';
  }

  String get destinationDisplay => toLabel;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromBuilding': fromBuilding,
        'fromFloor': fromFloor,
        'fromLabel': fromLabel,
        'toBuilding': toBuilding,
        'toFloor': toFloor,
        'toLabel': toLabel,
        'distanceMeters': distanceMeters,
        'completedAt': completedAt.toIso8601String(),
      };

  factory NavigationTrip.fromJson(Map<String, dynamic> json) =>
      NavigationTrip(
        id: json['id'] as String? ?? '',
        fromBuilding: json['fromBuilding'] as String? ?? '',
        fromFloor: json['fromFloor'] as int?,
        fromLabel: json['fromLabel'] as String? ?? '',
        toBuilding: json['toBuilding'] as String? ?? '',
        toFloor: json['toFloor'] as int?,
        toLabel: json['toLabel'] as String? ?? '',
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
        completedAt:
            DateTime.tryParse(json['completedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  bool operator ==(Object other) =>
      other is NavigationTrip && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
