import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mapx/models/saved_place.dart';
import 'package:mapx/services/saved_places_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('save and load keeps newest first with no duplicates', () async {
    final service = SavedPlacesService.instance;
    await service.save(SavedPlace.forBuilding('Alpha'));
    await service.save(
        SavedPlace.forFloor('Alpha', 1, mapKey: 'map_Alpha#1'));
    await service.save(SavedPlace.forBuilding('Alpha'));

    final places = await service.load();
    expect(places.length, 2);
    // Re-saving Alpha building moves it to the front.
    expect(places.first.kind, SavedPlaceKind.building);
    expect(await service.isSaved(SavedPlace.idForBuilding('Alpha')), isTrue);
  });

  test('toggle removes an existing save', () async {
    final service = SavedPlacesService.instance;
    final place = SavedPlace.forPlace('Beta', 2, 'Lab 201',
        mapKey: 'map_Beta#2');
    expect(await service.toggle(place), isTrue);
    expect(await service.toggle(place), isFalse);
    expect(await service.load(), isEmpty);
  });

  test('round trip json preserves fields', () {
    final place = SavedPlace.forFloor('Gamma', 0, mapKey: 'map_Gamma#0');
    final restored =
        SavedPlace.fromJson(Map<String, dynamic>.from(place.toJson()));
    expect(restored, place);
    expect(restored.building, 'Gamma');
    expect(restored.floor, 0);
  });

  test('clear empties the store', () async {
    final service = SavedPlacesService.instance;
    await service.save(SavedPlace.forBuilding('Delta'));
    await service.clear();
    expect(await service.load(), isEmpty);
  });
}
