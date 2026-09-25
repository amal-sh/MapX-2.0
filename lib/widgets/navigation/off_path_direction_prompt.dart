import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// On-screen high-visibility guidance prompt displayed when the user faces away
/// from the route direction (beyond +/- 35 degrees).
class OffPathDirectionPrompt extends StatefulWidget {
  final double deltaDegrees; // signed: negative = turn left, positive = turn right
  final String turnDirection; // 'left' or 'right'
  final bool isAtTurn; // true if user is at the exact decision/turn vertex
  final bool isTravelingBackward;

  const OffPathDirectionPrompt({
    super.key,
    required this.deltaDegrees,
    required this.turnDirection,
    this.isAtTurn = false,
    this.isTravelingBackward = false,
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

    _slideAnimation = Tween<double>(begin: 0.0, end: 8.0).animate(
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
    final isBackward = widget.isTravelingBackward;
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
              color: Colors.black.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isBackward ? const Color(0xFFF59E0B) : Colors.white,
                width: isBackward ? 2.0 : 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: isBackward
                      ? const Color(0xFFF59E0B).withValues(alpha: 0.3)
                      : Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
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
                    if (isBackward)
                      Transform.scale(
                        scale: _pulseAnimation.value,
                        child: const Icon(
                          CupertinoIcons.arrow_uturn_down,
                          color: Color(0xFFF59E0B),
                          size: 30,
                        ),
                      )
                    else if (isLeft)
                      Transform.translate(
                        offset: Offset(slideOffset, 0),
                        child: Transform.scale(
                          scale: _pulseAnimation.value,
                          child: const Icon(
                            CupertinoIcons.arrow_left,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          isBackward
                              ? 'WRONG DIRECTION — TURN AROUND'
                              : (widget.isAtTurn
                                  ? (isLeft ? 'TURN LEFT NOW' : 'TURN RIGHT NOW')
                                  : (isLeft ? 'TURN LEFT ${angle.toStringAsFixed(0)}°' : 'TURN RIGHT ${angle.toStringAsFixed(0)}°')),
                          style: TextStyle(
                            color: isBackward ? const Color(0xFFF59E0B) : Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: isBackward ? 15 : 17,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isBackward
                              ? 'You are moving away from destination'
                              : (widget.isAtTurn
                                  ? 'Turn at the corner to follow path'
                                  : 'Face towards path to continue'),
                          style: const TextStyle(
                            color: Color(0xFFA1A1AA),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    if (isBackward)
                      Transform.scale(
                        scale: _pulseAnimation.value,
                        child: const Icon(
                          CupertinoIcons.arrow_uturn_down,
                          color: Color(0xFFF59E0B),
                          size: 30,
                        ),
                      )
                    else if (!isLeft)
                      Transform.translate(
                        offset: Offset(slideOffset, 0),
                        child: Transform.scale(
                          scale: _pulseAnimation.value,
                          child: const Icon(
                            CupertinoIcons.arrow_right,
                            color: Colors.white,
                            size: 28,
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
                        color: Colors.white,
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
