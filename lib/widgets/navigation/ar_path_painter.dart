import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/map_models.dart';

/// Projects the route (a flat sequence of east/north path nodes) into the
/// live camera view and draws it as a floor-hugging glowing line with
/// start/destination markers - using plain
/// pinhole-camera perspective math driven by the walker's live PDR position
/// and compass heading/tilt, not ARCore world tracking. See the AR
/// floor-detection investigation: this project's floor surfaces made ARCore
/// plane/depth tracking too unreliable to anchor 3D content on, so the path
/// is drawn as a 2D overlay computed directly from the same PDR data that
/// already renders the accurate 2D map.
class ArPathPainter extends CustomPainter {
  final List<PathNode> route;
  final double liveEast;
  final double liveNorth;
  final double headingDegrees;
  final double tiltDegrees;
  final double animationProgress;
  final String startLabel;
  final String destinationLabel;

  ArPathPainter({
    required this.route,
    required this.liveEast,
    required this.liveNorth,
    required this.headingDegrees,
    required this.tiltDegrees,
    required this.animationProgress,
    required this.startLabel,
    required this.destinationLabel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (route.length < 2) return;

    final width = size.width;
    final height = size.height;
    final originX = width * 0.5;
    final originY = height * 0.5;

    // Tilt is ~90 deg when the phone is held level with the horizon and
    // drops toward 0 as the top of the phone tips down toward the floor, so
    // this maps it onto a pitch where 0 = level and negative = looking down.
    final pitch = (tiltDegrees - 90.0) * math.pi / 180.0;
    const cameraHeight = 1.35;

    const fovV = 60.0 * math.pi / 180.0;
    final focalLength = (height * 0.5) / math.tan(fovV * 0.5);

    final heading = headingDegrees * math.pi / 180.0;
    final cosH = math.cos(heading);
    final sinH = math.sin(heading);
    final cosP = math.cos(pitch);
    final sinP = math.sin(pitch);
    const cosR = 1.0; // roll == 0.0
    const sinR = 0.0;

    final fx = sinH * cosP;
    final fy = sinP;
    final fz = cosH * cosP;

    final r0x = cosH;
    const r0y = 0.0;
    final r0z = -sinH;

    final u0x = -sinH * sinP;
    final u0y = cosP;
    final u0z = -cosH * sinP;

    final rx = r0x * cosR + u0x * sinR;
    final ry = r0y * cosR + u0y * sinR;
    final rz = r0z * cosR + u0z * sinR;

    final ux = -r0x * sinR + u0x * cosR;
    final uy = -r0y * sinR + u0y * cosR;
    final uz = -r0z * sinR + u0z * cosR;

    const nearPlane = 0.15;
    final dyTerm = -cameraHeight * fy;

    // Depth of a floor point along the camera's optical axis - used to test
    // whether it's in front of the camera before projecting it.
    double zCamAt(double east, double north) {
      final dx = east - liveEast;
      final dz = north - liveNorth;
      return dx * fx + dz * fz + dyTerm;
    }

    // Projects a floor point (east, north) into screen space, or returns
    // null if it falls behind the camera.
    Offset? project(double east, double north) {
      final dx = east - liveEast;
      final dy = -cameraHeight;
      final dz = north - liveNorth;

      final zCam = dx * fx + dy * fy + dz * fz;
      if (zCam < nearPlane) return null;

      final xCam = dx * rx + dy * ry + dz * rz;
      final yCam = dx * ux + dy * uy + dz * uz;

      return Offset(
        originX + (xCam / zCam) * focalLength,
        originY - (yCam / zCam) * focalLength,
      );
    }

    // Projects a route point along with how wide the line should be there:
    // width falls off with actual camera-space depth (zCam), not screen-
    // space position relative to a computed horizon line. The horizon
    // estimate (originY - tan(pitch)*focalLength) blows up toward infinity
    // as pitch approaches +-90 deg - at a tilt of 19 deg (pitch=-71 deg) it
    // lands miles off-screen, which used to poison a horizon-based ratio
    // into clamping at max thickness for nearly everything. zCam has no
    // such singularity at any pitch.
    ({Offset point, double widthScale})? projectWithWidth(double east, double north, double fade) {
      final p = project(east, north);
      if (p == null) return null;
      final z = zCamAt(east, north).clamp(nearPlane, double.infinity);
      const referenceZCam = 1.0;
      final depthRatio = (referenceZCam / z).clamp(0.12, 1.0);
      return (point: p, widthScale: depthRatio * fade);
    }

    // Builds one continuous filled ribbon (not a sequence of separately
    // stroked segments) spanning every point in [points], tapering smoothly
    // from each point's own widthScale - a single polygon has no per-segment
    // seams to show, unlike drawing each ~0.5m recorded step as its own
    // stroke did.
    Path? buildRibbon(List<({Offset point, double widthScale})> points, double baseHalfWidth) {
      if (points.length < 2) return null;
      final left = <Offset>[];
      final right = <Offset>[];
      for (var i = 0; i < points.length; i++) {
        final Offset dir;
        if (i == 0) {
          dir = points[1].point - points[0].point;
        } else if (i == points.length - 1) {
          dir = points[i].point - points[i - 1].point;
        } else {
          // Average of the incoming and outgoing directions, so the ribbon
          // doesn't kink sharply where the recorded route bends slightly.
          dir = points[i + 1].point - points[i - 1].point;
        }
        final len = dir.distance;
        final perp = len > 0.0001 ? Offset(-dir.dy / len, dir.dx / len) : const Offset(1, 0);
        final halfWidth = baseHalfWidth * points[i].widthScale;
        left.add(points[i].point + perp * halfWidth);
        right.add(points[i].point - perp * halfWidth);
      }
      final path = Path()..moveTo(left.first.dx, left.first.dy);
      for (final p in left.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      for (final p in right.reversed) {
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      return path;
    }

    // Distance-along-path for each route node, used to find the walker's
    // nearest point on the route and cap how far ahead is drawn.
    final distances = <double>[0];
    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = math.sqrt(
        math.pow(cur.east - prev.east, 2) + math.pow(cur.north - prev.north, 2),
      );
      distances.add(distances.last + d);
    }
    final totalDistance = distances.last;

    // Closest route node to the walker's current position - the line ahead
    // of this point is what should still be visible on screen.
    var nearestIdx = 0;
    var nearestD = double.infinity;
    for (var i = 0; i < route.length; i++) {
      final d = math.pow(route[i].east - liveEast, 2) +
          math.pow(route[i].north - liveNorth, 2);
      if (d < nearestD) {
        nearestD = d.toDouble();
        nearestIdx = i;
      }
    }

    // Cap how far ahead the path is drawn: rendering the entire remaining
    // route for a long corridor clutters the view and pushes points near
    // the horizon, where a small pitch/heading error swings the projection
    // by meters instead of centimeters (see the AR anchoring research).
    // Fading out over the last couple of meters instead of stopping dead
    // reads as the path continuing out of view, not glitching away.
    const maxVisibleMeters = 8.0;
    const fadeZoneMeters = 2.5;
    final startDist = distances[nearestIdx];
    final visibleEndDist = math.min(totalDistance, startDist + maxVisibleMeters);

    double fadeFor(double distAlongPath) {
      final remaining = visibleEndDist - distAlongPath;
      return (remaining / fadeZoneMeters).clamp(0.0, 1.0);
    }

    // 1. Floor-hugging path line from the walker's position to the cutoff,
    // as one continuous ribbon rather than one stroke per recorded step.
    const glowColor = Color(0xFF00E5FF);
    const lineColor = Color(0xFF00E5FF);

    final visiblePoints = <({Offset point, double widthScale})>[];
    for (var i = nearestIdx; i < route.length; i++) {
      if (distances[i] > visibleEndDist) break;
      final node = route[i];
      final sample = projectWithWidth(node.east, node.north, fadeFor(distances[i]));
      if (sample == null) continue; // behind the camera
      visiblePoints.add(sample);
    }

    final shadowPath = buildRibbon(visiblePoints, 15.0);
    final glowPath = buildRibbon(visiblePoints, 10.0);
    final linePath = buildRibbon(visiblePoints, 3.5);
    if (shadowPath != null) {
      canvas.drawPath(
        shadowPath,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
          ..style = PaintingStyle.fill,
      );
    }
    if (glowPath != null) {
      canvas.drawPath(glowPath, Paint()..color = glowColor.withValues(alpha: 0.28));
    }
    if (linePath != null) {
      canvas.drawPath(linePath, Paint()..color = lineColor);
    }

    // 2. Start marker.
    final start = route.first;
    final startPos = project(start.east, start.north);
    if (startPos != null &&
        startPos.dx >= -60 &&
        startPos.dx <= width + 60 &&
        startPos.dy >= -60 &&
        startPos.dy <= height + 60) {
      _drawFloorMarker(canvas, startPos, const Color(0xFF10B981), startLabel, 'START');
    }

    // 3. Destination marker, or an off-screen cue pointing toward it.
    final dest = route.last;
    final destPos = project(dest.east, dest.north);
    if (destPos != null &&
        destPos.dx >= -40 &&
        destPos.dx <= width + 40 &&
        destPos.dy >= -60 &&
        destPos.dy <= height + 60) {
      _drawFloorMarker(canvas, destPos, const Color(0xFFEF4444), destinationLabel, 'DESTINATION');
    } else {
      final ddx = dest.east - liveEast;
      final ddz = dest.north - liveNorth;
      final destDist = math.sqrt(ddx * ddx + ddz * ddz);
      if (destDist > 0.4) {
        final bearing = math.atan2(ddx, ddz);
        var relAngle = bearing - heading;
        while (relAngle < -math.pi) {
          relAngle += 2 * math.pi;
        }
        while (relAngle > math.pi) {
          relAngle -= 2 * math.pi;
        }
        _drawOffScreenCue(canvas, size, relAngle, destDist, destinationLabel);
      }
    }
  }

  void _drawFloorMarker(Canvas canvas, Offset pos, Color color, String label, String prefix) {
    final pulseRing = Paint()
      ..color = color.withValues(alpha: (0.5 * (1.0 - animationProgress)).clamp(0.0, 0.5))
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final baseRing = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final innerFill = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;

    final pulseRadius = 16.0 + 12.0 * (1.0 - animationProgress);
    canvas.drawCircle(pos, pulseRadius, pulseRing);
    canvas.drawCircle(pos, 14.0, baseRing);
    canvas.drawCircle(pos, 8.0, innerFill);

    final badgeY = pos.dy - 50.0;
    final beamGlow = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..strokeWidth = 5.0;
    final beamCore = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.5;
    canvas.drawLine(pos, Offset(pos.dx, badgeY + 14), beamGlow);
    canvas.drawLine(pos, Offset(pos.dx, badgeY + 14), beamCore);

    final textSpan = TextSpan(
      children: [
        TextSpan(
          text: '$prefix  ',
          style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.0, fontSize: 11),
        ),
        TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
        ),
      ],
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();

    final pillWidth = textPainter.width + 20.0;
    final pillHeight = textPainter.height + 10.0;
    final pillRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(pos.dx, badgeY), width: pillWidth, height: pillHeight),
      Radius.circular(pillHeight / 2),
    );
    canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.92));
    canvas.drawRRect(
      pillRect,
      Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    textPainter.paint(canvas, Offset(pos.dx - textPainter.width / 2, badgeY - textPainter.height / 2));
  }

  void _drawOffScreenCue(Canvas canvas, Size size, double angleDelta, double distance, String label) {
    final isLeft = angleDelta < 0;
    final edgeY = size.height * 0.40;

    final textSpan = TextSpan(
      children: [
        TextSpan(text: isLeft ? '◀  ' : ''),
        TextSpan(
          text: '$label  ',
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 12),
        ),
        TextSpan(
          text: '${distance.toStringAsFixed(1)}m',
          style: const TextStyle(color: Color(0xFFEF4444), fontSize: 11, fontWeight: FontWeight.w700),
        ),
        TextSpan(text: isLeft ? '' : '  ▶'),
      ],
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();

    final pillWidth = textPainter.width + 18.0;
    const pillHeight = 28.0;
    final centerX = isLeft ? pillWidth / 2 + 12.0 : size.width - (pillWidth / 2 + 12.0);
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(centerX, edgeY), width: pillWidth, height: pillHeight),
      const Radius.circular(14),
    );

    canvas.drawRRect(rect, Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.90));
    canvas.drawRRect(
      rect,
      Paint()
        ..color = const Color(0xFFEF4444).withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    textPainter.paint(
      canvas,
      Offset(rect.center.dx - textPainter.width / 2, rect.center.dy - textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant ArPathPainter oldDelegate) => true;
}
