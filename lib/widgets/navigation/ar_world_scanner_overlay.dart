import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// A sleek monochromatic AR scanning overlay shown while ARCore detects the
/// horizontal floor plane and anchors the 3D world space.
class ArWorldScannerOverlay extends StatefulWidget {
  final VoidCallback? onCancel;
  final double floorConfidence;
  final String? statusMessage;

  const ArWorldScannerOverlay({
    super.key,
    this.onCancel,
    this.floorConfidence = 0.0,
    this.statusMessage,
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
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white24,
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
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.floorConfidence > 0.0
                              ? 'LOCKING FLOOR ${(widget.floorConfidence * 100).toInt()}%'
                              : 'ARCORE SPATIAL SCAN',
                          style: const TextStyle(
                            color: Colors.white,
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
                      icon: const Icon(CupertinoIcons.xmark, color: Colors.white70),
                      onPressed: widget.onCancel,
                      tooltip: 'Exit AR Mode',
                    ),
                ],
              ),
            ),

            const Spacer(),

            // Center Scanning Animation: Mobile surface scanning
            Center(
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
                child: Lottie.asset(
                  'assets/animations/mobile_surface_scanning.json',
                  width: 220,
                  height: 220,
                  fit: BoxFit.contain,
                  repeat: true,
                  errorBuilder: (context, error, stackTrace) {
                    return AnimatedBuilder(
                      animation: _scanController,
                      builder: (context, child) {
                        return CustomPaint(
                          size: const Size(180, 180),
                          painter: _ScannerReticlePainter(progress: _scanController.value),
                        );
                      },
                    );
                  },
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Bottom Informational Card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white24,
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
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
                          CupertinoIcons.scope,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.statusMessage ??
                              (widget.floorConfidence > 0.3
                                  ? 'Validating Floor Stability...'
                                  : 'Detecting Floor & Walls...'),
                          style: const TextStyle(
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
                      'Point camera towards the floor and move slowly. Navigation objects will appear once the floor is locked.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFA1A1AA),
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                    if (widget.floorConfidence > 0.0) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: widget.floorConfidence.clamp(0.0, 1.0),
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          minHeight: 4,
                        ),
                      ),
                    ],
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
        ..color = Colors.white.withValues(alpha: alpha)
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
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.7),
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
      ..color = Colors.white
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
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.5, centerDotPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerReticlePainter oldDelegate) => true;
}
