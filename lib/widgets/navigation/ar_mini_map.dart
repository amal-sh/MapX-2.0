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

                            // Static North Indicator Badge
                            Positioned(
                              bottom: 6,
                              left: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.white24, width: 0.8),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      CupertinoIcons.arrow_up,
                                      size: 8,
                                      color: Color(0xFFEF4444),
                                    ),
                                    SizedBox(width: 2),
                                    Text(
                                      'N',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 8,
                                        fontWeight: FontWeight.w900,
                                        height: 1.0,
                                      ),
                                    ),
                                  ],
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
    this.walls = const [],
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

    // Bounding box centered on route + user position in fixed North-Up coordinates
    double minE = userEast;
    double maxE = userEast;
    double minN = userNorth;
    double maxN = userNorth;
    for (final node in route) {
      minE = math.min(minE, node.east);
      maxE = math.max(maxE, node.east);
      minN = math.min(minN, node.north);
      maxN = math.max(maxN, node.north);
    }

    final spanE = (maxE - minE).clamp(8.0, double.infinity);
    final spanN = (maxN - minN).clamp(8.0, double.infinity);
    final centerE = (minE + maxE) / 2;
    final centerN = (minN + maxN) / 2;
    const pad = 16.0;
    final scale = math.min(
      (size.width - 2 * pad) / spanE,
      (size.height - 2 * pad) / spanN,
    );

    // North-pointing screen mapping: North is -Y (Up), East is +X (Right)
    Offset toScreen(double east, double north) {
      final screenX = size.width / 2 + (east - centerE) * scale;
      final screenY = size.height / 2 - (north - centerN) * scale;
      return Offset(screenX, screenY);
    }

    // 1. Draw Full Route Background Line (unrevealed context, North-Up)
    final fullRoutePath = Path();
    final p0 = toScreen(route.first.east, route.first.north);
    fullRoutePath.moveTo(p0.dx, p0.dy);
    for (var i = 1; i < route.length; i++) {
      final p = toScreen(route[i].east, route[i].north);
      fullRoutePath.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      fullRoutePath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.20)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 2. Highlight currently revealed segment
    double accum = 0.0;
    final revealedPath = Path();
    revealedPath.moveTo(p0.dx, p0.dy);

    for (var i = 1; i < route.length; i++) {
      final prev = route[i - 1];
      final cur = route[i];
      final d = math.sqrt(math.pow(cur.east - prev.east, 2) + math.pow(cur.north - prev.north, 2));
      accum += d;

      if (accum <= revealedEndDistance + 0.5) {
        final p = toScreen(cur.east, cur.north);
        revealedPath.lineTo(p.dx, p.dy);
      } else {
        final overflow = accum - revealedEndDistance;
        final t = (d > 0.001) ? (1.0 - (overflow / d)).clamp(0.0, 1.0) : 1.0;
        final interE = prev.east + (cur.east - prev.east) * t;
        final interN = prev.north + (cur.north - prev.north) * t;
        final p = toScreen(interE, interN);
        revealedPath.lineTo(p.dx, p.dy);
        break;
      }
    }

    // Glowing active revealed route
    canvas.drawPath(
      revealedPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );

    canvas.drawPath(
      revealedPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 3. Draw Turn Points (Junction Markers)
    final turnPaint = Paint()
      ..color = const Color(0xFFE4E4E7)
      ..style = PaintingStyle.fill;
    final turnBorder = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (final tp in turnPoints) {
      if (tp.nodeIndex < route.length) {
        final node = route[tp.nodeIndex];
        final pt = toScreen(node.east, node.north);
        canvas.drawCircle(pt, 2.5, turnPaint);
        canvas.drawCircle(pt, 2.5, turnBorder);
      }
    }

    // 4. Draw Start & Destination Markers
    final startPt = toScreen(route.first.east, route.first.north);
    canvas.drawCircle(startPt, 4.0, Paint()..color = Colors.white);
    canvas.drawCircle(startPt, 2.0, Paint()..color = Colors.black);

    final destPt = toScreen(route.last.east, route.last.north);
    canvas.drawCircle(destPt, 4.5, Paint()..color = const Color(0xFFEF4444));
    canvas.drawCircle(destPt, 2.0, Paint()..color = Colors.white);

    // 5. Draw User Chevron Arrow rotating according to userHeadingDegrees relative to North
    final userPos = toScreen(userEast, userNorth);

    canvas.save();
    canvas.translate(userPos.dx, userPos.dy);
    canvas.rotate(userHeadingDegrees * math.pi / 180.0);

    // Subtle forward field-of-view viewing cone
    final fovPath = Path()
      ..moveTo(0, 0)
      ..lineTo(-18, -26)
      ..lineTo(18, -26)
      ..close();
    canvas.drawPath(
      fovPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(const Rect.fromLTWH(-18, -26, 36, 26)),
    );

    const tipDist = 9.0;
    const backDist = 5.5;
    const sideDist = 5.0;
    const notchDist = 2.5;

    final tip = const Offset(0, -tipDist);
    final leftWing = const Offset(-sideDist, backDist);
    final rightWing = const Offset(sideDist, backDist);
    final notch = const Offset(0, notchDist);

    final arrowPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(rightWing.dx, rightWing.dy)
      ..lineTo(notch.dx, notch.dy)
      ..lineTo(leftWing.dx, leftWing.dy)
      ..close();

    // Shadow
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.60)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );

    // Border
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );

    // Body
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Center pivot dot
    canvas.drawCircle(
      Offset.zero,
      1.5,
      Paint()..color = Colors.black,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter oldDelegate) => true;
}
