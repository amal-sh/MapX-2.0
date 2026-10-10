import 'dart:math';
import 'package:flutter/material.dart';
import '../models/map_models.dart';

/// How map metres (east, north) are fitted onto a canvas. Shared by the
/// painter and anything that needs to turn a tap back into map metres.
class MapViewport {
  final Size size;
  final double scale; // pixels per metre
  final double centreEast;
  final double centreNorth;

  const MapViewport._(this.size, this.scale, this.centreEast, this.centreNorth);

  factory MapViewport.fit(List<PathNode> nodes, List<WallSegment> walls, Size size) {
    var minEast = nodes.first.east, maxEast = nodes.first.east;
    var minNorth = nodes.first.north, maxNorth = nodes.first.north;
    for (final n in nodes) {
      minEast = min(minEast, n.east);
      maxEast = max(maxEast, n.east);
      minNorth = min(minNorth, n.north);
      maxNorth = max(maxNorth, n.north);
    }
    for (final w in walls) {
      minEast = min(minEast, min(w.startEast, w.endEast));
      maxEast = max(maxEast, max(w.startEast, w.endEast));
      minNorth = min(minNorth, min(w.startNorth, w.endNorth));
      maxNorth = max(maxNorth, max(w.startNorth, w.endNorth));
    }

    const minSpan = 3.0;
    const padding = 20.0;
    final spanEast = max(maxEast - minEast, minSpan);
    final spanNorth = max(maxNorth - minNorth, minSpan);
    final scale = min((size.width - 2 * padding) / spanEast,
        (size.height - 2 * padding) / spanNorth);
    return MapViewport._(size, scale, (minEast + maxEast) / 2, (minNorth + maxNorth) / 2);
  }

  Offset toScreen(double east, double north) => Offset(
        size.width / 2 + (east - centreEast) * scale,
        size.height / 2 - (north - centreNorth) * scale,
      );

  (double, double) toMap(Offset p) => (
        centreEast + (p.dx - size.width / 2) / scale,
        centreNorth - (p.dy - size.height / 2) / scale,
      );
}

class PathMapPainter extends CustomPainter {
  final List<PathNode> nodes;
  final List<Waypoint> waypoints;
  final List<PathNode>? routeNodes;
  final List<WallSegment> walls;

  /// Path network edges (node index pairs). When null, [nodes] is drawn as
  /// one continuous walk.
  final List<(int, int)>? edges;

  /// Index of the walk's last node, marked as its end. Defaults to the last
  /// node.
  final int? walkEnd;

  PathMapPainter(this.nodes, this.waypoints, {this.routeNodes, this.walls = const [], this.edges, this.walkEnd});

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final viewport = MapViewport.fit(nodes, walls, size);
    final scale = viewport.scale;
    final centreEast = viewport.centreEast;
    final centreNorth = viewport.centreNorth;
    final toScreen = viewport.toScreen;

    _paintGrid(canvas, size, scale, centreEast, centreNorth, toScreen);

    // Draw walls as solid dark slate boundary lines
    final wallPaint = Paint()
      ..color = const Color(0xFF09090B)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.5;
    for (final w in walls) {
      canvas.drawLine(toScreen(w.startEast, w.startNorth), toScreen(w.endEast, w.endNorth), wallPaint);
    }

    final path = Path();
    if (edges != null) {
      for (final (a, b) in edges!) {
        final pa = toScreen(nodes[a].east, nodes[a].north);
        final pb = toScreen(nodes[b].east, nodes[b].north);
        path
          ..moveTo(pa.dx, pa.dy)
          ..lineTo(pb.dx, pb.dy);
      }
    } else {
      final first = toScreen(nodes.first.east, nodes.first.north);
      path.moveTo(first.dx, first.dy);
      for (final n in nodes.skip(1)) {
        final p = toScreen(n.east, n.north);
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF71717A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    if (routeNodes != null && routeNodes!.isNotEmpty) {
      final routePath = Path()
        ..moveTo(toScreen(routeNodes!.first.east, routeNodes!.first.north).dx,
            toScreen(routeNodes!.first.east, routeNodes!.first.north).dy);
      for (final n in routeNodes!.skip(1)) {
        final p = toScreen(n.east, n.north);
        routePath.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        routePath,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 5.5,
      );
    }

    final dot = Paint()..color = const Color(0xFF27272A);
    for (final n in nodes) {
      canvas.drawCircle(toScreen(n.east, n.north), 2.5, dot);
    }

    for (final wp in waypoints) {
      if (wp.globalStepIndex < nodes.length) {
        final node = nodes[wp.globalStepIndex];
        final pos = toScreen(node.east, node.north);
        if (wp.isConnector) {
          // Stairs/lift: a square, so floor links stand out from places.
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: pos, width: 16, height: 16), const Radius.circular(3)),
            Paint()..color = Colors.black,
          );
          canvas.drawRect(Rect.fromCenter(center: pos, width: 7, height: 7), Paint()..color = Colors.white);
          _paintBadge(canvas, wp.displayName, pos + const Offset(10, -10));
        } else {
          final isStartWp = routeNodes != null &&
              routeNodes!.isNotEmpty &&
              (node.east - routeNodes!.first.east).abs() < 0.05 &&
              (node.north - routeNodes!.first.north).abs() < 0.05;
          final isEndWp = routeNodes != null &&
              routeNodes!.isNotEmpty &&
              (node.east - routeNodes!.last.east).abs() < 0.05 &&
              (node.north - routeNodes!.last.north).abs() < 0.05;

          if (isStartWp) {
            canvas.drawCircle(pos, 8, Paint()..color = Colors.black);
            canvas.drawCircle(pos, 5, Paint()..color = Colors.white);
            canvas.drawCircle(pos, 2.5, Paint()..color = Colors.black);
            _paintBadge(canvas, wp.label, pos + const Offset(10, 8), hasDot: true);
          } else if (isEndWp) {
            canvas.drawCircle(pos, 9, Paint()..color = Colors.black);
            canvas.drawCircle(pos, 5, Paint()..color = Colors.white);
            canvas.drawCircle(pos, 2.5, Paint()..color = Colors.black);
            _paintBadge(canvas, '🚩 End', pos + const Offset(12, -12), isBlack: true);
          } else {
            canvas.drawCircle(pos, 6, Paint()..color = Colors.black);
            canvas.drawCircle(pos, 4, Paint()..color = Colors.white);
            _paintBadge(canvas, wp.label, pos + const Offset(8, -10));
          }
        }
      }
    }

    // Start node indicator if no start waypoint already drew one
    if (routeNodes != null && routeNodes!.isNotEmpty) {
      final rStart = routeNodes!.first;
      final rStartPos = toScreen(rStart.east, rStart.north);
      canvas.drawCircle(rStartPos, 8, Paint()..color = Colors.black);
      canvas.drawCircle(rStartPos, 5, Paint()..color = Colors.white);
      canvas.drawCircle(rStartPos, 2.5, Paint()..color = Colors.black);

      final rEnd = routeNodes!.last;
      final rEndPos = toScreen(rEnd.east, rEnd.north);
      canvas.drawCircle(rEndPos, 9, Paint()..color = Colors.black);
      canvas.drawCircle(rEndPos, 5, Paint()..color = Colors.white);
      canvas.drawCircle(rEndPos, 2.5, Paint()..color = Colors.black);
      _paintBadge(canvas, '🚩 End', rEndPos + const Offset(12, -12), isBlack: true);
    } else {
      final startPos = toScreen(nodes.first.east, nodes.first.north);
      canvas.drawCircle(startPos, 7, Paint()..color = Colors.black);
      canvas.drawCircle(startPos, 4, Paint()..color = Colors.white);
      canvas.drawCircle(startPos, 2, Paint()..color = Colors.black);

      final end = nodes[(walkEnd ?? nodes.length - 1).clamp(0, nodes.length - 1)];
      if (nodes.length > 1) {
        final endPos = toScreen(end.east, end.north);
        canvas.drawCircle(endPos, 7, Paint()..color = Colors.black);
        canvas.drawCircle(endPos, 3, Paint()..color = Colors.white);
      }
    }

    _paintNorthArrow(canvas, size);
  }

  void _paintGrid(Canvas canvas, Size size, double scale, double centreEast,
      double centreNorth, Offset Function(double, double) toScreen) {
    final halfEast = size.width / 2 / scale;
    final halfNorth = size.height / 2 / scale;
    final step = (max(halfEast, halfNorth) * 2) > 20 ? 5.0 : 1.0;
    final paint = Paint()
      ..color = const Color(0xFFF0F0F3)
      ..strokeWidth = 1;

    for (var e = ((centreEast - halfEast) / step).ceil() * step;
        e <= centreEast + halfEast;
        e += step) {
      final x = toScreen(e, centreNorth).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var n = ((centreNorth - halfNorth) / step).ceil() * step;
        n <= centreNorth + halfNorth;
        n += step) {
      final y = toScreen(centreEast, n).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paintBadge(
    Canvas canvas,
    String text,
    Offset at, {
    bool isBlack = false,
    bool hasDot = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: isBlack ? Colors.white : const Color(0xFF18181B),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final dotWidth = hasDot ? 12.0 : 0.0;
    const padH = 6.0;
    const padV = 3.0;
    final width = tp.width + padH * 2 + dotWidth;
    final height = tp.height + padV * 2;
    final rect = Rect.fromLTWH(at.dx, at.dy, width, height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(5));

    if (isBlack) {
      canvas.drawRRect(rrect, Paint()..color = const Color(0xFF09090B));
    } else {
      canvas.drawRRect(
        rrect.shift(const Offset(0, 1)),
        Paint()..color = Colors.black.withValues(alpha: 0.05),
      );
      canvas.drawRRect(rrect, Paint()..color = Colors.white);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFFE4E4E7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    if (hasDot) {
      canvas.drawCircle(
        Offset(at.dx + padH + 3.0, at.dy + height / 2),
        3.0,
        Paint()..color = isBlack ? Colors.white : Colors.black,
      );
    }

    tp.paint(canvas, Offset(at.dx + padH + dotWidth, at.dy + padV));
  }

  void _paintNorthArrow(Canvas canvas, Size size) {
    final top = Offset(size.width - 20, 12);
    final bottom = Offset(size.width - 20, 34);
    final paint = Paint()
      ..color = const Color(0xFF71717A)
      ..strokeWidth = 1.5;
    canvas.drawLine(bottom, top, paint);
    canvas.drawLine(top, top + const Offset(-4, 6), paint);
    canvas.drawLine(top, top + const Offset(4, 6), paint);
  }

  @override
  bool shouldRepaint(PathMapPainter oldDelegate) => true;
}
