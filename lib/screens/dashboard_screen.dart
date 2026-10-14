import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models/outdoor_models.dart';
import '../providers/dashboard_providers.dart';
import '../providers/service_providers.dart';
import '../services/location_service.dart';
import '../services/user_preferences_service.dart';
import '../widgets/dashboard_bottom_sheet.dart';
import '../widgets/dashboard_sidebar_drawer.dart';
import '../widgets/osm_layers.dart';
import 'map_viewer_screen.dart';
import 'outdoor_map_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget content = const _DashboardScreenContent();
    try {
      ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      content = ProviderScope(child: content);
    }
    return content;
  }
}

class _DashboardScreenContent extends ConsumerStatefulWidget {
  const _DashboardScreenContent();

  @override
  ConsumerState<_DashboardScreenContent> createState() =>
      _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<_DashboardScreenContent> {
  static const _methodChannel = MethodChannel('mapx/arcore');

  GeoPoint? _userGps;

  /// True while the initial GPS fix is being fetched. Drives the circular
  /// loader floating over the map.
  bool _locating = true;

  final _previewMap = MapController();
  final _sheetController = DraggableScrollableController();

  /// Set once flutter_map reports readiness; moves issued before this are
  /// silently dropped on mobile, so pending targets wait for it.
  bool _mapReady = false;

  /// True once the user manually pans/zooms the preview; delayed
  /// re-applies never fight an intentional gesture.
  bool _userInteracted = false;

  /// Last target successfully shifted into the visible region.
  LatLng? _appliedCenter;

  /// Newest target waiting for the map to be ready / laid out.
  LatLng? _pendingTarget;

  static const double _previewZoom = 16;

  /// Live sheet height as a fraction of the body. Tracked (without
  /// setState) so map centering can target the uncovered region.
  double _sheetFraction = 0.62;

  @override
  void initState() {
    super.initState();
    final cached = LocationService.instance.cachedLocation;
    if (cached != null) {
      _userGps = (cached.latitude, cached.longitude);
      _locating = false;
    }
    _sheetController.addListener(() {
      final size = _sheetController.size;
      if (size > 0) _sheetFraction = size;
    });
    _requestInitialLocationPermission();
    _checkArCoreSupport();
  }

  @override
  void dispose() {
    _previewMap.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _requestInitialLocationPermission() async {
    try {
      if (_userGps != null) {
        ref.read(dashboardProvider.notifier).loadMaps();
        return;
      }
      final granted = await LocationService.instance.requestPermission();
      if (granted && mounted) {
        final loc = await LocationService.instance.getCurrentLocation();
        if (loc != null && mounted) {
          setState(() => _userGps = (loc.latitude, loc.longitude));
          ref.read(dashboardProvider.notifier).loadMaps();
        }
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _checkArCoreSupport() async {
    try {
      final availability =
          await _methodChannel.invokeMethod<String>('checkAvailability');
      if (availability != 'SUPPORTED_INSTALLED') {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showUnsupportedDeviceDialog();
          }
        });
      }
    } on MissingPluginException {
      // Platform or tests without plugin: do not block unless mocked.
    } on PlatformException {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUnsupportedDeviceDialog();
        }
      });
    } catch (_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUnsupportedDeviceDialog();
        }
      });
    }
  }

  void _showUnsupportedDeviceDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(CupertinoIcons.exclamationmark_triangle_fill,
                  color: Color(0xFFDC2626), size: 24),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Device Not Supported',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'This device isn\'t supported. MapX requires ARCore support to function properly.',
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFF52525B),
              height: 1.4,
            ),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => SystemNavigator.pop(),
              child: const Text('Exit App',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  // ---- outdoor preview map (CARTO) -----------------------------------------

  LatLng _fallbackCenter() {
    if (_userGps != null) return LatLng(_userGps!.$1, _userGps!.$2);
    return const LatLng(20, 78);
  }

  /// Best currently-known center: user GPS first, else the mean of the
  /// cached building fixes. Null while nothing is known (keeps the fallback).
  LatLng? _resolvePreviewTarget(DashboardState state) {
    if (_userGps != null) return LatLng(_userGps!.$1, _userGps!.$2);
    final pins = [
      for (final name in state.allBuildingNames)
        if (state.buildingPinLocation(name) != null)
          state.buildingPinLocation(name)!
    ];
    if (pins.isEmpty) return null;
    return LatLng(
      pins.map((p) => p.$1).reduce((a, b) => a + b) / pins.length,
      pins.map((p) => p.$2).reduce((a, b) => a + b) / pins.length,
    );
  }

  void _ensurePreviewCentered(DashboardState state) {
    final target = _resolvePreviewTarget(state);
    if (target == null) return;
    // Skip rebuilds on the same spot, but DO recenter when a better fix
    // arrives (e.g. buildings-mean first, live GPS second).
    if (_appliedCenter != null) {
      final moved = const Distance().distance(_appliedCenter!, target);
      if (moved < 25) return;
    }
    if (_pendingTarget != null) {
      final pendingMoved = const Distance().distance(_pendingTarget!, target);
      if (pendingMoved < 25 && _appliedCenter == null) {
        if (!_mapReady) return;
      }
    }
    _pendingTarget = target;
    if (!_mapReady) return;
    _applyPendingCenter();
  }

  void _applyPendingCenter() {
    final target = _pendingTarget;
    if (target == null || !_mapReady) return;
    _pendingTarget = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _centerOn(target, _previewZoom);
      _appliedCenter = target;
      // Mobile layout settles late (sheet snap, first tiles): one delayed
      // re-apply so the dot reliably ends in the visible region center.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted || _userInteracted) return;
        if (_appliedCenter == target && _pendingTarget == null) {
          _centerOn(target, _previewZoom);
        }
      });
    });
  }

  /// Moves the map so [target] lands at the center of the *visible*
  /// region (the body area between the floating header and the bottom
  /// sheet), not the exact screen center which the sheet covers.
  void _centerOn(LatLng target, double zoom) {
    try {
      if (!_mapReady) return;
      final camera = _previewMap.camera;
      final world = camera.projectAtZoom(target, zoom);
      final media = MediaQuery.of(context);
      // Floating header (~52px pill + 8px margin) replaces kToolbarHeight.
      const floatingHeaderHeight = 68.0;
      // DraggableScrollableSheet fractions are relative to the full screen
      // height, so the covered height ~= fraction * screen height.
      final sheetHeightPx = _sheetFraction * media.size.height;
      final shiftPx =
          (sheetHeightPx - media.padding.top - floatingHeaderHeight) / 2;
      final shift = shiftPx < 0 ? 0.0 : shiftPx;
      final shifted = world + Offset(0, shift);
      _previewMap.move(camera.unprojectAtZoom(shifted, zoom), zoom);
    } catch (_) {}
  }

  void _openFullOutdoorMap() async {
    await Navigator.push(
      context,
      // Scale + fade makes the Hero's map-continuity read as an expand
      // (the Hero keeps the tiles continuous while the page scales
      // from 0.96 to full). Hero still shrinks back on pop.
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 450),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const OutdoorMapScreen(),
        transitionsBuilder:
            (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInOut,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (mounted) ref.read(dashboardProvider.notifier).loadMaps();
  }

  void _openPreviewBuilding(String name, List<BuildingMapEntry> floors) {
    if (floors.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewerScreen(
          mapKey: floors.first.key,
          mapName: floors.first.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardProvider);
    final basemapPref = ref.watch(basemapPreferenceProvider);
    final isDark = basemapPref == UserPreferencesService.basemapDark;
    final basemapTheme = basemapPref == UserPreferencesService.basemapLight
        ? BasemapTheme.light
        : (basemapPref == UserPreferencesService.basemapStandard
            ? BasemapTheme.standard
            : BasemapTheme.dark);
    _ensurePreviewCentered(dashboardState);

    return Scaffold(
      backgroundColor: Colors.white,
      extendBodyBehindAppBar: true,
      drawer: const DashboardSidebarDrawer(),
      body: Stack(
        children: [
          // Outdoor preview map with user-selected basemap theme.
          // Wrapped in a Hero matching OutdoorMapScreen.heroTag so the
          // preview visually expands into the full map on push (and
          // shrinks back on pop).
          Positioned.fill(
            child: Hero(
              tag: OutdoorMapScreen.heroTag,
              // ClipRect keeps tiles inside the flight bounds while the
              // hero expands between routes.
              child: ClipRect(
                child: Material(
                  type: MaterialType.transparency,
                  child: FlutterMap(
                    mapController: _previewMap,
                    options: MapOptions(
                      initialCenter:
                          _resolvePreviewTarget(dashboardState) ??
                              _fallbackCenter(),
                      initialZoom: (_userGps != null ||
                              dashboardState
                                  .buildingLocations.isNotEmpty)
                          ? 16
                          : 4,
                      maxZoom: 20,
                      backgroundColor: isDark
                          ? const Color(0xFF080E18)
                          : const Color(0xFFF4F4F5),
                      onMapReady: () {
                        _mapReady = true;
                        _applyPendingCenter();
                      },
                      onPositionChanged: (_, hasGesture) {
                        if (hasGesture) _userInteracted = true;
                      },
                    ),
                    children: [
                      basemapTileLayer(basemapTheme),
                      if (dashboardState.connections.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            // Casing under each route so the line reads on the
                            // basemap (polished nav look). Colors invert with
                            // the light/dark theme.
                            for (final c in dashboardState.connections)
                              Polyline(
                                points: [
                                  for (final p in c.route) LatLng(p.$1, p.$2)
                                ],
                                strokeWidth: 8,
                                color: isDark
                                    ? const Color(0xFF18181B)
                                    : Colors.white,
                                pattern: c.source == 'straight'
                                    ? StrokePattern.dashed(
                                        segments: const [12, 8])
                                    : const StrokePattern.solid(),
                              ),
                            for (final c in dashboardState.connections)
                              Polyline(
                                points: [
                                  for (final p in c.route) LatLng(p.$1, p.$2)
                                ],
                                strokeWidth: 5,
                                color: isDark
                                    ? Colors.white
                                    : Colors.black,
                                pattern: c.source == 'straight'
                                    ? StrokePattern.dashed(
                                        segments: const [12, 8])
                                    : const StrokePattern.solid(),
                              ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          for (final e in dashboardState.entrancesWithGps)
                            Marker(
                              point: LatLng(e.latitude!, e.longitude!),
                              width: 22,
                              height: 22,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Color(0xFF18181B),
                                      blurRadius: 0,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: Icon(Icons.door_front_door,
                                    size: 15, color: Colors.black),
                              ),
                            ),
                          for (final name in dashboardState.allBuildingNames)
                            if (dashboardState.buildingPinLocation(name) != null)
                              Marker(
                                point: LatLng(
                                  dashboardState.buildingPinLocation(name)!.$1,
                                  dashboardState.buildingPinLocation(name)!.$2,
                                ),
                                width: 150,
                                height: 70,
                                alignment: Alignment.topCenter,
                                child: GestureDetector(
                                  onTap: () {
                                    final floors = dashboardState
                                            .groupedByBuilding[name] ??
                                        const <BuildingMapEntry>[];
                                    if (floors.isNotEmpty) {
                                      _openPreviewBuilding(
                                          name, floors);
                                    }
                                  },
                                  child: _PreviewBuildingPin(
                                      name: name),
                                ),
                              ),
                          if (_userGps != null)
                            Marker(
                              point:
                                  LatLng(_userGps!.$1, _userGps!.$2),
                              width: 72,
                              height: 72,
                              child: userLocationDot(dark: isDark),
                            ),
                        ],
                      ),
                      osmAttribution(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Floating header: separate circular buttons +
          // rounded center pill, all floating over the map.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Builder(
                  builder: (scaffoldContext) => Row(
                    children: [
                      _GlassCircleButton(
                        icon: CupertinoIcons.bars,
                        tooltip: 'Menu',
                        onPressed: () =>
                            Scaffold.of(scaffoldContext).openDrawer(),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlassPill(
                          child: Image.asset(
                            'assets/images/transp_banner.png',
                            height: 34,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _GlassCircleButton(
                        icon: CupertinoIcons.map_fill,
                        tooltip: 'Outdoor map',
                        onPressed: _openFullOutdoorMap,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Circular loader floating over the map while the initial GPS
          // fix is being fetched. Centered in the visible band between
          // the header and the bottom sheet.
          if (_locating)
            Positioned(
              top: 140,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Semantics(
                    label: 'Finding your location',
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.fromBorderSide(
                          BorderSide(
                              color: Color(0xFFE4E4E7), width: 1),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            key: ValueKey(
                                'location-loading-indicator'),
                            strokeWidth: 3,
                            backgroundColor: Color(0xFFF4F4F5),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(
                                    Colors.black),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Directory content lives in a moveable bottom sheet covering
          // most of the screen.
          DashboardBottomSheet(
            dashboardState: dashboardState,
            userGps: _userGps,
            controller: _sheetController,
          ),
        ],
      ),
    );
  }

}

/// Separate circular floating button for the dashboard header.
/// Plain white background with a 1px zinc border, black icon.
class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _GlassCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.fromBorderSide(
          BorderSide(color: Color(0xFFE4E4E7), width: 1),
        ),
      ),
      child: Stack(
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Tooltip(
                message: tooltip,
                child: const SizedBox(width: 52, height: 52),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Icon(icon, color: Colors.black, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating perfectly-rounded (stadium) pill for the banner.
/// Plain white background with a 1px zinc border.
class _GlassPill extends StatelessWidget {
  final Widget child;

  const _GlassPill({required this.child});

  @override
  Widget build(BuildContext context) {
    // 52px tall -> 26px radius = fully rounded ends regardless of width.
    const radius = BorderRadius.all(Radius.circular(26));
    return Container(
      height: 52,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        borderRadius: radius,
        color: Colors.white,
        border: Border.fromBorderSide(
          BorderSide(color: Color(0xFFE4E4E7), width: 1),
        ),
      ),
      child: child,
    );
  }
}

/// Compact monochrome pin for the dashboard preview map.
class _PreviewBuildingPin extends StatelessWidget {
  final String name;
  const _PreviewBuildingPin({required this.name});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: const Icon(Icons.apartment, color: Colors.white, size: 18),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black),
          ),
        ),
      ],
    );
  }
}
