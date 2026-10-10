import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models/outdoor_models.dart';
import '../providers/dashboard_providers.dart';
import '../services/location_service.dart';
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

  final _previewMap = MapController();
  final _sheetController = DraggableScrollableController();
  bool _previewCentered = false;

  /// Live sheet height as a fraction of the body. Tracked (without
  /// setState) so map centering can target the uncovered region.
  double _sheetFraction = 0.62;

  @override
  void initState() {
    super.initState();
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
    final granted = await LocationService.instance.requestPermission();
    if (granted && mounted) {
      final loc = await LocationService.instance.getCurrentLocation();
      if (loc != null && mounted) {
        setState(() => _userGps = (loc.latitude, loc.longitude));
        ref.read(dashboardProvider.notifier).loadMaps();
      }
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
    final pins = state.buildingLocations.values.toList();
    if (pins.isEmpty) return null;
    return LatLng(
      pins.map((p) => p.latitude).reduce((a, b) => a + b) / pins.length,
      pins.map((p) => p.longitude).reduce((a, b) => a + b) / pins.length,
    );
  }

  void _maybeRecenterPreview(DashboardState state) {
    if (_previewCentered) return;
    final target = _resolvePreviewTarget(state);
    if (target == null) return;
    _previewCentered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _centerOn(target, 16);
    });
  }

  /// Moves the map so [target] lands at the center of the *visible*
  /// region (the body area above the bottom sheet), not the exact
  /// screen center which the sheet covers.
  void _centerOn(LatLng target, double zoom) {
    try {
      final camera = _previewMap.camera;
      final world = camera.projectAtZoom(target, zoom);
      final media = MediaQuery.of(context);
      final bodyHeight = media.size.height -
          media.padding.top -
          kToolbarHeight;
      final shifted =
          world + Offset(0, _sheetFraction * bodyHeight / 2);
      _previewMap.move(camera.unprojectAtZoom(shifted, zoom), zoom);
    } catch (_) {}
  }

  void _goToMyLocation() {
    if (_userGps == null) return;
    _centerOn(LatLng(_userGps!.$1, _userGps!.$2), 17);
  }

  Future<void> _openFullOutdoorMap() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OutdoorMapScreen()),
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
    _maybeRecenterPreview(dashboardState);

    return Scaffold(
      backgroundColor: Colors.white,
      drawer: const DashboardSidebarDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (scaffoldContext) => IconButton(
            icon: const Icon(CupertinoIcons.bars, color: Colors.black, size: 22),
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(scaffoldContext).openDrawer(),
          ),
        ),
        title: Image.asset(
          'assets/images/transp_banner.png',
          height: 26,
          fit: BoxFit.contain,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(
              CupertinoIcons.map_fill,
              color: Colors.black,
              size: 21,
            ),
            tooltip: 'Outdoor map',
            onPressed: _openFullOutdoorMap,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Outdoor CARTO map directly below the app bar.
          Positioned.fill(
            child: FlutterMap(
              mapController: _previewMap,
              options: MapOptions(
                initialCenter: _resolvePreviewTarget(dashboardState) ??
                    _fallbackCenter(),
                initialZoom:
                    (_userGps != null || dashboardState.buildingLocations.isNotEmpty)
                        ? 16
                        : 4,
                maxZoom: 20,
                backgroundColor: const Color(0xFF18181B),
              ),
              children: [
                osmTileLayer(dark: true),
                MarkerLayer(
                  markers: [
                    for (final entry
                        in dashboardState.buildingLocations.entries)
                      Marker(
                        point: LatLng(
                            entry.value.latitude, entry.value.longitude),
                        width: 150,
                        height: 70,
                        alignment: Alignment.topCenter,
                        child: GestureDetector(
                          onTap: () {
                            final floors = dashboardState
                                    .groupedByBuilding[entry.key] ??
                                const <BuildingMapEntry>[];
                            if (floors.isNotEmpty) {
                              _openPreviewBuilding(entry.key, floors);
                            }
                          },
                          child: _PreviewBuildingPin(name: entry.key),
                        ),
                      ),
                    if (_userGps != null)
                      Marker(
                        point: LatLng(_userGps!.$1, _userGps!.$2),
                        width: 72,
                        height: 72,
                        child: userLocationDot(dark: true),
                      ),
                  ],
                ),
                osmAttribution(),
              ],
            ),
          ),
          // Map controls above the sheet.
          Positioned(
            top: 12,
            right: 12,
            child: Column(
              children: [
                _buildMapControlButton(
                  icon: CupertinoIcons.location_circle_fill,
                  tooltip: 'My location',
                  onPressed: _userGps == null ? null : _goToMyLocation,
                ),
                const SizedBox(height: 8),
                _buildMapControlButton(
                  icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                  tooltip: 'Expand outdoor map',
                  onPressed: _openFullOutdoorMap,
                ),
              ],
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

  Widget _buildMapControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 18,
            color: onPressed == null
                ? const Color(0xFFA1A1AA)
                : Colors.black,
          ),
        ),
      ),
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
