/// A user-saved location: a whole building, one floor/block of a
/// building, or a single room/place. Stored offline on the device in
/// SharedPreferences (no account, so nothing is pushed to Firebase).
enum SavedPlaceKind { building, floor, place }

class SavedPlace {
  final String id;
  final SavedPlaceKind kind;
  final String building;
  final int? floor;
  final String label;
  final String? mapKey;
  final DateTime createdAt;

  const SavedPlace({
    required this.id,
    required this.kind,
    required this.building,
    this.floor,
    required this.label,
    this.mapKey,
    required this.createdAt,
  });

  static String idForBuilding(String building) => 'building|$building';

  static String idForFloor(String building, int floor) =>
      'floor|$building|$floor';

  static String idForPlace(String building, int floor, String label) =>
      'place|$building|$floor|${label.trim().toLowerCase()}';

  factory SavedPlace.forBuilding(String building, {String? mapKey}) {
    final name = building.trim();
    return SavedPlace(
      id: idForBuilding(name),
      kind: SavedPlaceKind.building,
      building: name,
      label: name,
      mapKey: mapKey,
      createdAt: DateTime.now(),
    );
  }

  factory SavedPlace.forFloor(String building, int floor,
      {String? label, String? mapKey}) {
    final name = building.trim();
    return SavedPlace(
      id: idForFloor(name, floor),
      kind: SavedPlaceKind.floor,
      building: name,
      floor: floor,
      label: (label == null || label.trim().isEmpty)
          ? '$name · Floor $floor'
          : label.trim(),
      mapKey: mapKey,
      createdAt: DateTime.now(),
    );
  }

  factory SavedPlace.forPlace(String building, int floor, String label,
      {String? mapKey}) {
    final name = building.trim();
    final placeLabel = label.trim().isEmpty ? 'Place' : label.trim();
    return SavedPlace(
      id: idForPlace(name, floor, placeLabel),
      kind: SavedPlaceKind.place,
      building: name,
      floor: floor,
      label: placeLabel,
      mapKey: mapKey,
      createdAt: DateTime.now(),
    );
  }

  String get subtitle {
    switch (kind) {
      case SavedPlaceKind.building:
        return 'Building';
      case SavedPlaceKind.floor:
        return floor == null ? 'Floor' : 'Floor $floor';
      case SavedPlaceKind.place:
        return floor == null ? building : '$building · Floor $floor';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'building': building,
        'floor': floor,
        'label': label,
        'mapKey': mapKey,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SavedPlace.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'] as String?;
    final kind = SavedPlaceKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () => SavedPlaceKind.place,
    );
    return SavedPlace(
      id: json['id'] as String? ?? '',
      kind: kind,
      building: json['building'] as String? ?? '',
      floor: json['floor'] as int?,
      label: json['label'] as String? ?? '',
      mapKey: json['mapKey'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedPlace && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
