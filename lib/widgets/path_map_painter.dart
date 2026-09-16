import 'dart:math';
import 'package:flutter/material.dart';
import '../models/map_models.dart';

class PathMapPainter extends CustomPainter {
  final List<PathNode> nodes;
  final List<Waypoint> waypoints;
  final List<PathNode>? routeNodes;

  PathMapPainter(this.nodes, this.waypoints, {this.routeNodes});

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
        ..color = Colors.teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
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
          ..color = Colors.orange
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 6.0, // Thicker line for the route
      );
    }

    final dot = Paint()..color = Colors.teal.shade700;
    for (final n in nodes) {
      canvas.drawCircle(toScreen(n.east, n.north), 3, dot);
    }

    final markerPaint = Paint()..color = Colors.blue;
    for (final wp in waypoints) {
      if (wp.globalStepIndex < nodes.length) {
        final node = nodes[wp.globalStepIndex];
        final pos = toScreen(node.east, node.north);
        canvas.drawCircle(pos, 8, markerPaint);
        _paintLabel(canvas, wp.label, pos + const Offset(10, -10), Colors.blue.shade900);
      }
    }

    canvas.drawCircle(toScreen(nodes.first.east, nodes.first.north), 6,
        Paint()..color = Colors.green);
    if (nodes.length > 1) {
      canvas.drawCircle(toScreen(nodes.last.east, nodes.last.north), 6,
          Paint()..color = Colors.deepOrange);
    }

    _paintNorthArrow(canvas, size);
  }

  void _paintGrid(Canvas canvas, Size size, double scale, double centreEast,
      double centreNorth, Offset Function(double, double) toScreen) {
    final halfEast = size.width / 2 / scale;
    final halfNorth = size.height / 2 / scale;
    final step = (max(halfEast, halfNorth) * 2) > 20 ? 5.0 : 1.0;
    final paint = Paint()
      ..color = Colors.grey.shade300
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
        Offset(6, size.height - 18), Colors.grey.shade600);
  }

  void _paintNorthArrow(Canvas canvas, Size size) {
    final top = Offset(size.width - 20, 12);
    final bottom = Offset(size.width - 20, 34);
    final paint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 2;
    canvas.drawLine(bottom, top, paint);
    canvas.drawLine(top, top + const Offset(-5, 7), paint);
    canvas.drawLine(top, top + const Offset(5, 7), paint);
    _paintLabel(canvas, 'N', Offset(size.width - 25, 36), Colors.black54);
  }

  void _paintLabel(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(PathMapPainter oldDelegate) => true;
}
