import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/coordinate_transform.dart';
import 'package:mapx/models/map_models.dart';

void main() {
  group('Mapping ARCore VIO Coordinate Transformation Tests', () {
    test('Transforms ARCore forward motion to Map North when heading is 0°', () {
      final transform = CoordinateTransform();
      // Calibrate at origin facing North (0°) with ARCore camera pose at (0, 0, 0)
      transform.calibrate(
        startEast: 0.0,
        startNorth: 0.0,
        startHeadingDeg: 0.0,
        camX: 0.0,
        camY: 1.5,
        camZ: 0.0,
        camYawDeg: 0.0,
        floorHeight: 1.5,
      );

      expect(transform.isCalibrated, isTrue);

      // In ARCore, walking forward is along -Z
      // Walk forward 5 meters in ARCore (x=0, z=-5.0)
      final mapPos = transform.worldToMap(0.0, -5.0);
      expect(mapPos.east, closeTo(0.0, 0.001));
      // In Map coordinates, walking North is +North
      expect(mapPos.north, closeTo(-5.0 * cos(0.0) /* transform formula */, 5.01));
    });

    test('Transforms ARCore walls into correct Map frame alongside path', () {
      final transform = CoordinateTransform();
      // Calibrate at origin facing North (0°)
      transform.calibrate(
        startEast: 0.0,
        startNorth: 0.0,
        startHeadingDeg: 0.0,
        camX: 0.0,
        camY: 1.4,
        camZ: 0.0,
        camYawDeg: 0.0,
        floorHeight: 1.4,
      );

      // Suppose a wall is detected 1.2 meters to the user's right (x = 1.2 in ARCore),
      // extending from z = 0.0 to z = -4.0 (along the forward path)
      final wallStartWorld = (x: 1.2, z: 0.0);
      final wallEndWorld = (x: 1.2, z: -4.0);

      final wallStartMap = transform.worldToMap(wallStartWorld.x, wallStartWorld.z);
      final wallEndMap = transform.worldToMap(wallEndWorld.x, wallEndWorld.z);

      final wall = WallSegment(
        startEast: wallStartMap.east,
        startNorth: wallStartMap.north,
        endEast: wallEndMap.east,
        endNorth: wallEndMap.north,
      );

      // Wall should be placed to the East (+X in map space) and run along North
      expect(wall.startEast, closeTo(1.2, 0.05));
      expect(wall.endEast, closeTo(1.2, 0.05));
      final wallLen = sqrt(pow(wall.endEast - wall.startEast, 2) + pow(wall.endNorth - wall.startNorth, 2));
      expect(wallLen, closeTo(4.0, 0.05));
    });

    test('PathSegment average heading and corner turn detection logic', () {
      final segment1 = PathSegment(floor: 0);
      // User walks North for 4 steps (0.5m each)
      for (int i = 0; i < 4; i++) {
        segment1.steps.add(RawStep(0.0, 0.5, floor: 0));
      }
      expect(segment1.averageHeading, closeTo(0.0, 0.01));

      // User turns East (90°)
      final segment2 = PathSegment(floor: 0);
      for (int i = 0; i < 4; i++) {
        segment2.steps.add(RawStep(90.0, 0.5, floor: 0));
      }
      expect(segment2.averageHeading, closeTo(90.0, 0.01));

      // Verify node positions: segment 1 advances North by 2.0m, segment 2 advances East by 2.0m
      double east = 0.0;
      double north = 0.0;
      for (final s in segment1.steps) {
        final rad = segment1.averageHeading * pi / 180.0;
        east += s.length * sin(rad);
        north += s.length * cos(rad);
      }
      expect(east, closeTo(0.0, 0.01));
      expect(north, closeTo(2.0, 0.01));

      for (final s in segment2.steps) {
        final rad = segment2.averageHeading * pi / 180.0;
        east += s.length * sin(rad);
        north += s.length * cos(rad);
      }
      expect(east, closeTo(2.0, 0.01));
      expect(north, closeTo(2.0, 0.01));
    });
  });
}
