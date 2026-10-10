import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/providers/dashboard_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FloorMapStats derives real counts from stored payload', () {
    final payload = {
      'name': 'TowerA',
      'floor': 2,
      'stepCount': 3,
      'segments': [
        {
          'floor': 2,
          'steps': [
            {'heading': 0.0, 'length': 10.0, 'floor': 2},
            {'heading': 0.0, 'length': 20.0, 'floor': 2},
            {'heading': 90.0, 'length': 5.0, 'floor': 2},
          ],
        },
      ],
      'waypoints': [
        {'globalStepIndex': 0, 'label': 'Lobby', 'floor': 2, 'category': 'room'},
        {'globalStepIndex': 1, 'label': 'Lab 201', 'floor': 2, 'category': 'room'},
        {'globalStepIndex': 2, 'label': 'A', 'floor': 2, 'category': 'lift'},
        {'globalStepIndex': 3, 'label': 'Main', 'floor': 2, 'category': 'stairs'},
        {'globalStepIndex': 3, 'label': 'Gate', 'floor': 2, 'category': 'entrance'},
      ],
      'walls': [],
      'links': [],
    };

    final stats = FloorMapStats.fromPayload(payload);
    expect(stats.stepCount, 3);
    expect(stats.nodeCount, 4); // stepCount + 1 walk nodes, no links
    expect(stats.placeCount, 2);
    expect(stats.liftCount, 1);
    expect(stats.stairsCount, 1);
    expect(stats.entranceCount, 1);
    expect(stats.distanceMeters, 35.0);
    expect(stats.distanceLabel, '(35 m)');
    expect(stats.subtitle, '4 Nodes · 2 Places · 1 Lift · 1 Staircase · 1 Entrance');
  });

  test('FloorMapStats handles empty payload without throwing', () {
    const stats = FloorMapStats();
    expect(stats.subtitle, '0 Nodes');
    expect(stats.distanceLabel, isEmpty);
    expect(FloorMapStats.fromPayload(const {}).nodeCount, 1);
  });
}
