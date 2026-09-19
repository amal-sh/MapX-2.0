import 'package:flutter/material.dart';

/// On-screen high-visibility guidance prompt displayed when the user faces away
/// from the route direction (beyond +/- 35 degrees).
class OffPathDirectionPrompt extends StatefulWidget {
  final double deltaDegrees; // signed: negative = turn left, positive = turn right
  final String turnDirection; // 'left' or 'right'

  const OffPathDirectionPrompt({
    super.key,
    required this.deltaDegrees,
    required this.turnDirection,
  });

  @override
  State<OffPathDirectionPrompt> createState() => _OffPathDirectionPromptState();
}

class _OffPathDirectionPromptState extends State<OffPathDirectionPrompt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  late final Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _slideAnimation = Tween<double>(begin: -6.0, end: 6.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLeft = widget.turnDirection == 'left';
    final angle = widget.deltaDegrees.abs();

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final slideOffset = isLeft ? -_slideAnimation.value : _slideAnimation.value;

        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.85),
                width: 1.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.35 * _pulseAnimation.value),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Directional Pulsing Arrow Banner
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLeft)
                      Transform.translate(
                        offset: Offset(slideOffset, 0),
                        child: Transform.scale(
                          scale: _pulseAnimation.value,
                          child: const Icon(
                            Icons.arrow_back_rounded,
                            color: Color(0xFF00E5FF),
                            size: 34,
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          isLeft ? 'TURN LEFT ${angle.toStringAsFixed(0)}°' : 'TURN RIGHT ${angle.toStringAsFixed(0)}°',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Face towards path to continue',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    if (!isLeft)
                      Transform.translate(
                        offset: Offset(slideOffset, 0),
                        child: Transform.scale(
                          scale: _pulseAnimation.value,
                          child: const Icon(
                            Icons.arrow_forward_rounded,
                            color: Color(0xFF00E5FF),
                            size: 34,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                // Heading alignment progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 4,
                    width: 180,
                    color: Colors.white.withValues(alpha: 0.15),
                    child: Align(
                      alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
                      child: Container(
                        width: (180 * (angle / 180.0)).clamp(20.0, 180.0),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF00E5FF),
                              isLeft ? Colors.cyanAccent : Colors.tealAccent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
