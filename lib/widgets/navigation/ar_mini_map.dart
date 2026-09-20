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

                            // Dynamic Rotating Compass needle pointing toward True North
                            Positioned(
                              bottom: 6,
                              left: 6,
                              child: Transform.rotate(
                                angle: -widget.userHeadingDegrees * math.pi / 180.0,
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.65),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white24, width: 0.8),
                                  ),
                                  child: const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          CupertinoIcons.arrowtriangle_up_fill,
                                          size: 8,
                                          color: Color(0xFFEF4444),
                                        ),
                                        Text(
                                          'N',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 7,
                                            fontWeight: FontWeight.w900,
                                            height: 1.0,
                                          ),
                                        ),
                                      ],
                                    ),
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

    final centerX = size.width / 2;
    final centerY = size.height * 0.58; // Center user slightly below middle for extended forward visibility

    final headingRad = userHeadingDegrees * math.pi / 180.0;
    final cosH = math.cos(headingRad);
    final sinH = math.sin(headingRad);

    // Compute viewing scale focused on route around the user
    double maxDistFromUser = 12.0;
    for (final node in route) {
      final d = math.sqrt(math.pow(node.east - userEast, 2) + math.pow(node.north - userNorth, 2));
      if (d > maxDistFromUser) {
        maxDistFromUser = d;
      }
    }
    final viewRadius = maxDistFromUser.clamp(12.0, 32.0);
    final scale = (math.min(size.width, size.height) / 2 - 16.0) / viewRadius;

    // Transforms world Map (East, North) to user-centric rotating heading-up screen coordinates
    Offset toScreen(double east, double north) {
      final de = east - userEast;
      final dn = north - userNorth;
      // Heading-up rotation: forward is straight ahead on the screen (-Y)
      final forward = dn * cosH + de * sinH;
      final right = de * cosH - dn * sinH;
      return Offset(
        centerX + right * scale,
        centerY - forward * scale,
      );
    }

    // 1. Draw subtle forward Field-of-View beam from user's current orientation
    final fovPath = Path()
      ..moveTo(centerX, centerY)
      ..lineTo(centerX - 35, centerY - 55)
      ..lineTo(centerX + 35, centerY - 55)
      ..close();
    canvas.drawPath(
      fovPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(centerX - 35, centerY - 55, 70, 55)),
    );

    // 2. Draw Full Route Background Line (unrevealed context, rotating with heading)
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

    // 3. Highlight currently revealed segment
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

    // 4. Draw Turn Points (Junction Markers)
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

    // 5. Draw Start & Destination Markers
    final startPt = toScreen(route.first.east, route.first.north);
    canvas.drawCircle(startPt, 4.0, Paint()..color = Colors.white);
    canvas.drawCircle(startPt, 2.0, Paint()..color = Colors.black);

    final destPt = toScreen(route.last.east, route.last.north);
    canvas.drawCircle(destPt, 4.5, Paint()..color = const Color(0xFFEF4444));
    canvas.drawCircle(destPt, 2.0, Paint()..color = Colors.white);

    // 6. Draw User Chevron Arrow (Centered and ALWAYS pointing UP in Heading-Up Mode)
    final userPos = Offset(centerX, centerY);
    const tipDist = 10.0;
    const backDist = 6.0;
    const sideDist = 5.5;
    const notchDist = 3.0;

    final tip = Offset(userPos.dx, userPos.dy - tipDist);
    final leftWing = Offset(userPos.dx - sideDist, userPos.dy + backDist);
    final rightWing = Offset(userPos.dx + sideDist, userPos.dy + backDist);
    final notch = Offset(userPos.dx, userPos.dy + notchDist);

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
        ..strokeWidth = 1.8
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
      userPos,
      1.5,
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter oldDelegate) => true;
}
