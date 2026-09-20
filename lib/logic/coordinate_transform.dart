import 'dart:math';

/// Manages spatial transformations between Map Coordinate Frame {M}
/// (East, North, Floor Level in meters) and ARCore World Frame {W}
/// (Right-handed 3D Cartesian coordinates where Y is gravity Up).
class CoordinateTransform {
  // Yaw rotation angle in radians between Map North and ARCore World Z
  double _yawOffsetRad;

  // Translation vector in ARCore world frame (tx, ty, tz)
  double _tx;
  double _ty;
  double _tz;

  bool _isCalibrated = false;
  bool get isCalibrated => _isCalibrated;

  CoordinateTransform({
    double yawOffsetRad = 0.0,
    double tx = 0.0,
    double ty = 0.0,
    double tz = 0.0,
  })  : _yawOffsetRad = yawOffsetRad,
        _tx = tx,
        _ty = ty,
        _tz = tz;

  /// Resets calibration state.
  void reset() {
    _isCalibrated = false;
    _yawOffsetRad = 0.0;
    _tx = 0.0;
    _ty = 0.0;
    _tz = 0.0;
  }

  /// Initializes the transformation matrix matching the user's starting map
  /// position (startEast, startNorth) and route heading (startHeadingDeg)
  /// with the active ARCore camera pose (camX, camY, camZ, camYawDeg)
  /// and detected floor height.
  void calibrate({
    required double startEast,
    required double startNorth,
    required double startHeadingDeg,
    required double camX,
    required double camY,
    required double camZ,
    required double camYawDeg,
    required double floorHeight,
  }) {
    // Rotation mapping map bearing to ARCore world orientation
    final mapHeadingRad = startHeadingDeg * pi / 180.0;
    final arYawRad = camYawDeg * pi / 180.0;
    _yawOffsetRad = arYawRad - mapHeadingRad;

    // Floor elevation in ARCore world frame
    _ty = camY - floorHeight;

    // Compute translation so (startEast, startNorth) maps exactly to (camX, camZ)
    final cosY = cos(_yawOffsetRad);
    final sinY = sin(_yawOffsetRad);

    final rotatedEast = startEast * cosY + startNorth * sinY;
    final rotatedNorth = -startEast * sinY + startNorth * cosY;

    _tx = camX - rotatedEast;
    _tz = camZ - rotatedNorth;
    _isCalibrated = true;
  }

  /// Updates floor height elevation reference when ARCore re-locks the plane.
  void updateFloorHeight(double camY, double measuredFloorHeight) {
    _ty = camY - measuredFloorHeight;
  }

  /// Transforms a 2D Map position (East, North) into 3D ARCore World Coordinates.
  ({double x, double y, double z}) mapToWorld(double east, double north, [double altitudeOffset = 0.0]) {
    final cosY = cos(_yawOffsetRad);
    final sinY = sin(_yawOffsetRad);

    final wx = east * cosY + north * sinY + _tx;
    final wy = _ty + altitudeOffset;
    final wz = -east * sinY + north * cosY + _tz;

    return (x: wx, y: wy, z: wz);
  }

  /// Transforms 3D ARCore World coordinates back into 2D Map Coordinates (East, North).
  ({double east, double north}) worldToMap(double wx, double wz) {
    final cosY = cos(_yawOffsetRad);
    final sinY = sin(_yawOffsetRad);

    final dx = wx - _tx;
    final dz = wz - _tz;

    final east = dx * cosY - dz * sinY;
    final north = dx * sinY + dz * cosY;

    return (east: east, north: north);
  }

  /// Smoothly adjusts the translation offset during relocalization without causing visual popping.
  void applyRelocalizationCorrection({
    required double deltaEast,
    required double deltaNorth,
    double alpha = 0.25,
  }) {
    final cosY = cos(_yawOffsetRad);
    final sinY = sin(_yawOffsetRad);

    final targetDeltaTx = deltaEast * cosY + deltaNorth * sinY;
    final targetDeltaTz = -deltaEast * sinY + deltaNorth * cosY;

    _tx += targetDeltaTx * alpha;
    _tz += targetDeltaTz * alpha;
  }
}
