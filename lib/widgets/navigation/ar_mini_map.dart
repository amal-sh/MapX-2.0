import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/map_models.dart';
import '../../logic/route_segment_manager.dart';

/// A persistent, semi-transparent top-right 2D schematic mini-map overlay for AR navigation.
///
/// Displays the full route, turn points, wall boundaries, and live user position with heading,
/// allowing the user to maintain full spatial route context even while AR view reveals
/// path segments progressively.
class ArMiniMap extends StatefulWidget {
  final List<PathNode> route;
  final List<WallSegment> walls;
  final List<RouteTurnPoint> turnPoints;
  final double userEast;
  final double userNorth;
  final double userHeadingDegrees;
  final double revealedEndDistance;
  final double currentProgress;

  const ArMiniMap({
    super.key,
    required this.route,
    this.walls = const [],
    this.turnPoints = const [],
    required this.userEast,
    required this.userNorth,
    required this.userHeadingDegrees,
    required this.revealedEndDistance,
    required this.currentProgress,
  });

  @override
  State<ArMiniMap> createState() => _ArMiniMapState();
}

class _ArMiniMapState extends State<ArMiniMap> {
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    if (widget.route.isEmpty) return const SizedBox.shrink();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: _isExpanded ? 154 : 44,
      height: _isExpanded ? 154 : 44,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: _isExpanded ? 0.85 : 0.90),
        borderRadius: BorderRadius.circular(_isExpanded ? 18 : 22),
        border: Border.all(
          color: Colors.white24,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_isExpanded ? 18 : 22),
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_isExpanded ? 18 : 22),
            child: OverflowBox(
              minWidth: 0,
              maxWidth: 154,
              minHeight: 0,
              maxHeight: 154,
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _isExpanded
                    ? SizedBox(
                        key: const ValueKey('expanded'),
                        width: 154,
                        height: 154,
                        child: Stack(
                          children: [
                            // Canvas 2D schematic
                            CustomPaint(
                              size: const Size(154, 154),
                              painter: _MiniMapPainter(
                                route: widget.route,
                                walls: widget.walls,
                                turnPoints: widget.turnPoints,
                                userEast: widget.userEast,
                                userNorth: widget.userNorth,
                                userHeadingDegrees: widget.userHeadingDegrees,
                                revealedEndDistance: widget.revealedEndDistance,
                                currentProgress: widget.currentProgress,
                              ),
                            ),

                            // Top header: Title and collapse icon
                            Positioned(
                              top: 4,
                              left: 8,
                              right: 6,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'MAP',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    CupertinoIcons.chevron_down,
                                    size: 14,
                                    color: Colors.white.withValues(alpha: 0.75),
                                  ),
                                ],
                              ),
                            ),

                            // North Compass Tag
                            Positioned(
                              bottom: 4,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'N ↑',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : SizedBox(
                        key: const ValueKey('collapsed'),
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.map_fill,
                            color: Colors.white.withValues(alpha: 0.9),
                            size: 20,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  final List<PathNode> route;
  final List<WallSegment> walls;
  final List<RouteTurnPoint> turnPoints;
  final double userEast;
  final double userNorth;
  final double userHeadingDegrees;
  final double revealedEndDistance;
  final double currentProgress;

  _MiniMapPainter({
    required this.route,
    required this.walls,
    required this.turnPoints,
    required this.userEast,
    required this.userNorth,
    required this.userHeadingDegrees,
    required this.revealedEndDistance,
    required this.currentProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (route.isEmpty) return;

    // 1. Compute bounds of route + user + walls with padding
    double minE = route.first.east;
    double maxE = route.first.east;
    double minN = route.first.north;
    double maxN = route.first.north;

    for (final node in route) {
      minE = math.min(minE, node.east);
      maxE = math.max(maxE, node.east);
      minN = math.min(minN, node.north);
      maxN = math.max(maxN, node.north);
    }
    minE = math.min(minE, userEast);
    maxE = math.max(maxE, userEast);
    minN = math.min(minN, userNorth);
    maxN = math.max(maxN, userNorth);

    const padMeters = 2.0;
    final spanE = math.max(maxE - minE, 4.0) + padMeters * 2;
    final spanN = math.max(maxN - minN, 4.0) + padMeters * 2;
    final centerE = (minE + maxE) / 2;
    final centerN = (minN + maxN) / 2;

    const screenPadding = 18.0;
    final scale = math.min(
      (size.width - 2 * screenPadding) / spanE,
      (size.height - 2 * screenPadding) / spanN,
    );

    Offset toScreen(double east, double north) {
      return Offset(
        size.width / 2 + (east - centerE) * scale,
        size.height / 2 - (north - centerN) * scale,
      );
    }

    // 2. Draw Mapped Walls
    final wallPaint = Paint()
      ..color = const Color(0xFF475569).withValues(alpha: 0.70)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    for (final w in walls) {
      canvas.drawLine(
        toScreen(w.startEast, w.startNorth),
        toScreen(w.endEast, w.endNorth),
        wallPaint,
      );
    }

    // 3. Draw Full Route Background Line (unrevealed context)
    final fullRoutePath = Path();
    fullRoutePath.moveTo(toScreen(route.first.east, route.first.north).dx, toScreen(route.first.east, route.first.north).dy);
    for (var i = 1; i < route.length; i++) {
      final p = toScreen(route[i].east, route[i].north);
      fullRoutePath.lineTo(p.dx, p.dy);
    }

    // Dim route line
    canvas.drawPath(
      fullRoutePath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // 4. Highlight currently revealed segment
    // Calculate cumulative distances
    double accum = 0.0;
    final revealedPath = Path();
    revealedPath.moveTo(toScreen(route.first.east, route.first.north).dx, toScreen(route.first.east, route.first.north).dy);

    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = math.sqrt(math.pow(cur.east - prev.east, 2) + math.pow(cur.north - prev.north, 2));
      accum += d;

      if (accum <= revealedEndDistance + 0.5) {
        revealedPath.lineTo(toScreen(cur.east, cur.north).dx, toScreen(cur.east, cur.north).dy);
      } else {
        // Interpolate last point
        final overflow = accum - revealedEndDistance;
        final t = (d > 0.001) ? (1.0 - (overflow / d)).clamp(0.0, 1.0) : 1.0;
        final interE = prev.east + (cur.east - prev.east) * t;
        final interN = prev.north + (cur.north - prev.north) * t;
        revealedPath.lineTo(toScreen(interE, interN).dx, toScreen(interE, interN).dy);
        break;
      }
    }

    // Glow under revealed line
    canvas.drawPath(
      revealedPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );

    // Active revealed path line
    canvas.drawPath(
      revealedPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round,
    );

    // 5. Draw Turn Points (Junction Markers)
    final turnPaint = Paint()
      ..color = const Color(0xFFD4D4D8)
      ..style = PaintingStyle.fill;
    for (final tp in turnPoints) {
      if (tp.nodeIndex < route.length) {
        final node = route[tp.nodeIndex];
        canvas.drawCircle(toScreen(node.east, node.north), 2.5, turnPaint);
      }
    }

    // 6. Draw Start & Destination Markers
    final startPt = toScreen(route.first.east, route.first.north);
    canvas.drawCircle(startPt, 4.0, Paint()..color = Colors.white);
    canvas.drawCircle(startPt, 2.0, Paint()..color = Colors.black);

    final destPt = toScreen(route.last.east, route.last.north);
    canvas.drawCircle(destPt, 4.0, Paint()..color = Colors.white);
    canvas.drawCircle(destPt, 2.0, Paint()..color = const Color(0xFF52525B));

    // 7. Draw Live User Position and Heading Indicator
    final userPos = toScreen(userEast, userNorth);
    final headingRad = userHeadingDegrees * math.pi / 180.0;

    // Direction Cone
    final coneLength = 14.0;
    const coneHalfAngle = 28.0 * math.pi / 180.0;
    final leftAngle = headingRad - coneHalfAngle;
    final rightAngle = headingRad + coneHalfAngle;

    final conePath = Path()
      ..moveTo(userPos.dx, userPos.dy)
      ..lineTo(
        userPos.dx + math.sin(leftAngle) * coneLength,
        userPos.dy - math.cos(leftAngle) * coneLength,
      )
      ..lineTo(
        userPos.dx + math.sin(rightAngle) * coneLength,
        userPos.dy - math.cos(rightAngle) * coneLength,
      )
      ..close();

    canvas.drawPath(
      conePath,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.40),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: userPos, radius: coneLength)),
    );

    // User Position Dot
    canvas.drawCircle(
      userPos,
      4.5,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      userPos,
      2.5,
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter oldDelegate) => true;
}
