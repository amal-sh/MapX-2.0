import 'dart:math';
import 'package:flutter/material.dart';
import '../models/map_models.dart';

class PathMapPainter extends CustomPainter {
  final List<PathNode> nodes;
  final List<Waypoint> waypoints;
  final List<PathNode>? routeNodes;
  final List<WallSegment> walls;

  PathMapPainter(this.nodes, this.waypoints, {this.routeNodes, this.walls = const []});

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

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
    final centreEast = (minEast + maxEast) / 2;
    final centreNorth = (minNorth + maxNorth) / 2;

    Offset toScreen(double east, double north) => Offset(
          size.width / 2 + (east - centreEast) * scale,
          size.height / 2 - (north - centreNorth) * scale,
        );

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

    final path = Path()
      ..moveTo(toScreen(nodes.first.east, nodes.first.north).dx,
          toScreen(nodes.first.east, nodes.first.north).dy);
    for (final n in nodes.skip(1)) {
      final p = toScreen(n.east, n.north);
      path.lineTo(p.dx, p.dy);
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
        canvas.drawCircle(pos, 8, Paint()..color = Colors.black);
        canvas.drawCircle(pos, 4, Paint()..color = Colors.white);
        _paintLabel(canvas, wp.label, pos + const Offset(10, -10), Colors.black);
      }
    }

    // Start node: High contrast concentric indicator
    final startPos = toScreen(nodes.first.east, nodes.first.north);
    canvas.drawCircle(startPos, 7, Paint()..color = Colors.black);
    canvas.drawCircle(startPos, 4, Paint()..color = Colors.white);
    canvas.drawCircle(startPos, 2, Paint()..color = Colors.black);

    if (nodes.length > 1) {
      final endPos = toScreen(nodes.last.east, nodes.last.north);
      canvas.drawCircle(endPos, 7, Paint()..color = Colors.black);
      canvas.drawCircle(endPos, 3, Paint()..color = Colors.white);
    }

    _paintNorthArrow(canvas, size);
  }

  void _paintGrid(Canvas canvas, Size size, double scale, double centreEast,
      double centreNorth, Offset Function(double, double) toScreen) {
    final halfEast = size.width / 2 / scale;
    final halfNorth = size.height / 2 / scale;
    final step = (max(halfEast, halfNorth) * 2) > 20 ? 5.0 : 1.0;
    final paint = Paint()
      ..color = const Color(0xFFE4E4E7)
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

    _paintLabel(canvas, '${step.toStringAsFixed(0)} m grid',
        Offset(6, size.height - 18), const Color(0xFF71717A));
  }

  void _paintNorthArrow(Canvas canvas, Size size) {
    final top = Offset(size.width - 20, 12);
    final bottom = Offset(size.width - 20, 34);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    canvas.drawLine(bottom, top, paint);
    canvas.drawLine(top, top + const Offset(-5, 7), paint);
    canvas.drawLine(top, top + const Offset(5, 7), paint);
    _paintLabel(canvas, 'N', Offset(size.width - 25, 36), Colors.black);
  }

  void _paintLabel(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(PathMapPainter oldDelegate) => true;
}
