import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../providers/service_providers.dart';
import '../services/location_service.dart';
import 'dashboard_screen.dart';

/// Monochrome splash screen that displays the MapX logo animation
/// and fetches user GPS coordinates concurrently during startup.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _xOpacityAnimation;
  late final Animation<double> _xScaleAnimation;
  late final Animation<double> _mapRevealAnimation;
  late final Animation<double> _mapOpacityAnimation;

  bool _animationDone = false;
  bool _locationDone = false;
  bool _hasNavigated = false;
  Timer? _maxWaitTimer;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    // Phase 1 (0.00 - 0.35): 'X' fades and scales in at the center.
    _xOpacityAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.30, curve: Curves.easeOut),
    );

    _xScaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOutCubic),
      ),
    );

    // Phase 2 (0.45 - 0.85): 'Map' scrolls out from behind 'X' towards the left.
    _mapRevealAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.45, 0.85, curve: Curves.easeInOutCubic),
    );

    _mapOpacityAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.45, 0.65, curve: Curves.easeIn),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _animationDone = true;
        _checkAndNavigate();
      }
    });

    // Start logo animation
    _controller.forward();

    // Start fetching location coordinates starting from splash screen itself
    _startLocationFetch();

    // Safety timeout: never block on splash longer than 3.5s total
    _maxWaitTimer = Timer(const Duration(milliseconds: 3500), () {
      _locationDone = true;
      if (_animationDone) {
        _checkAndNavigate();
      }
    });
  }

  Future<void> _startLocationFetch() async {
    try {
      final loc = await LocationService.instance.getCurrentLocation();
      if (loc != null && mounted) {
        ref.read(userLocationProvider.notifier).state = loc;
      }
    } catch (e) {
      debugPrint('SplashScreen: Location fetch error: $e');
    } finally {
      if (mounted) {
        _locationDone = true;
        if (_animationDone) {
          _checkAndNavigate();
        }
      }
    }
  }

  void _checkAndNavigate() {
    if (_hasNavigated || !mounted) return;

    // Both animation must be done, and either location has resolved or max wait reached
    if (_animationDone && _locationDone) {
      _hasNavigated = true;
      _maxWaitTimer?.cancel();

      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const DashboardScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeInOut,
              ),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    }
  }

  @override
  void dispose() {
    _maxWaitTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return _buildAnimatedLogo();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedLogo() {
    final xOpacity = _xOpacityAnimation.value;
    final xScale = _xScaleAnimation.value;
    final mapProgress = _mapRevealAnimation.value;
    final mapOpacity = _mapOpacityAnimation.value;

    const double logoHeight = 78.0;
    // Overlap distance to bring 'Map' and the transparent 'X' close together
    const double overlap = 22.0;
    final double currentOverlap = overlap * mapProgress;

    return Opacity(
      opacity: xOpacity,
      child: Transform.scale(
        scale: xScale,
        child: Transform.translate(
          // Keep the combined [Map + X] visual lockup centered as they overlap
          offset: Offset(currentOverlap / 2, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 'Map' emerging from behind 'X', scrolling from right to left
              ClipRect(
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: mapProgress,
                  child: Transform.translate(
                    // Translates from right to left as progress advances
                    offset: Offset((1.0 - mapProgress) * 50.0, 0),
                    child: Opacity(
                      opacity: mapOpacity,
                      child: Text(
                        'Map',
                        style: GoogleFonts.inter(
                          fontSize: 56,
                          fontWeight: FontWeight.w400,
                          color: Colors.white,
                          letterSpacing: -1.8,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Stylized 'X' (brought closer to Map via negative offset)
              Transform.translate(
                offset: Offset(-currentOverlap, 0),
                child: Image.asset(
                  'assets/images/x_light.png',
                  height: logoHeight,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
