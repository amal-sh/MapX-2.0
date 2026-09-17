import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A sleek, futuristic AR scanning overlay shown while ARCore detects the
/// horizontal floor plane and anchors the 3D world space.
class ArWorldScannerOverlay extends StatefulWidget {
  final VoidCallback? onCancel;

  const ArWorldScannerOverlay({
    super.key,
    this.onCancel,
  });

  @override
  State<ArWorldScannerOverlay> createState() => _ArWorldScannerOverlayState();
}

class _ArWorldScannerOverlayState extends State<ArWorldScannerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: SafeArea(
        child: Column(
          children: [
            // Top HUD Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'ARCORE SPATIAL SCAN',
                          style: TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (widget.onCancel != null)
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: widget.onCancel,
                      tooltip: 'Exit AR Mode',
                    ),
                ],
              ),
            ),

            const Spacer(),

            // Center Scanning Reticle
            AnimatedBuilder(
              animation: _scanController,
              builder: (context, child) {
                return CustomPaint(
                  size: const Size(180, 180),
                  painter: _ScannerReticlePainter(progress: _scanController.value),
                );
              },
            ),

            const SizedBox(height: 24),

            // Bottom Informational Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.radar,
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Detecting 3D World & Floor...',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Point camera towards the floor and move slowly to anchor navigation to real surfaces',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _ScannerReticlePainter extends CustomPainter {
  final double progress;

  _ScannerReticlePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Expanding pulsing circles
    for (int i = 0; i < 3; i++) {
      final p = (progress + i / 3.0) % 1.0;
      final radius = maxRadius * (0.3 + 0.7 * p);
      final alpha = (1.0 - p).clamp(0.0, 1.0) * 0.45;

      final circlePaint = Paint()
        ..color = const Color(0xFF38BDF8).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(center, radius, circlePaint);
    }

    // Rotating scanner sweep arc
    final sweepAngle = math.pi * 0.4;
    final startAngle = progress * 2 * math.pi;

    final arcPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0.0,
        endAngle: sweepAngle,
        colors: [
          const Color(0xFF38BDF8).withValues(alpha: 0.0),
          const Color(0xFF38BDF8).withValues(alpha: 0.7),
        ],
        transform: GradientRotation(startAngle),
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius * 0.6))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: maxRadius * 0.6),
      startAngle,
      sweepAngle,
      false,
      arcPaint,
    );

    // Corner brackets
    final bracketPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    const cornerLen = 14.0;
    final r = maxRadius * 0.75;

    // Top-left
    canvas.drawLine(Offset(center.dx - r, center.dy - r + cornerLen), Offset(center.dx - r, center.dy - r), bracketPaint);
    canvas.drawLine(Offset(center.dx - r, center.dy - r), Offset(center.dx - r + cornerLen, center.dy - r), bracketPaint);

    // Top-right
    canvas.drawLine(Offset(center.dx + r - cornerLen, center.dy - r), Offset(center.dx + r, center.dy - r), bracketPaint);
    canvas.drawLine(Offset(center.dx + r, center.dy - r), Offset(center.dx + r, center.dy - r + cornerLen), bracketPaint);

    // Bottom-left
    canvas.drawLine(Offset(center.dx - r, center.dy + r - cornerLen), Offset(center.dx - r, center.dy + r), bracketPaint);
    canvas.drawLine(Offset(center.dx - r, center.dy + r), Offset(center.dx - r + cornerLen, center.dy + r), bracketPaint);

    // Bottom-right
    canvas.drawLine(Offset(center.dx + r - cornerLen, center.dy + r), Offset(center.dx + r, center.dy + r), bracketPaint);
    canvas.drawLine(Offset(center.dx + r, center.dy + r), Offset(center.dx + r, center.dy + r - cornerLen), bracketPaint);

    // Center dot
    final centerDotPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.5, centerDotPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerReticlePainter oldDelegate) => true;
}
