import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/outdoor_models.dart';
import '../models/saved_place.dart';
import '../services/building_repository.dart';
import '../services/location_service.dart';
import '../services/user_preferences_service.dart';
import '../widgets/osm_layers.dart';
import '../widgets/save_place_button.dart';
import 'map_viewer_screen.dart';
import 'preferences_screen.dart';

/// Outdoor map view of every mapped building and the outdoor routes
/// linking them. Tap a building to open its floors.
class OutdoorMapScreen extends StatefulWidget {
  /// Shared Hero tag with the dashboard preview map so opening the full
  /// map looks like the preview expands into place.
  static const heroTag = 'outdoor-map-hero';

  const OutdoorMapScreen({super.key});

  @override
  State<OutdoorMapScreen> createState() => _OutdoorMapScreenState();
}

class _OutdoorMapScreenState extends State<OutdoorMapScreen> {
  final _map = MapController();
  final _repo = BuildingRepository.instance;

  Map<String, MappedBuilding> _buildings = {};
  List<BuildingConnection> _connections = [];
  bool _loading = true;
  GeoPoint? _me;

  /// Active basemap style. Defaults to the saved preference (dark when
  /// unset, matching the dashboard preview map); the layers control
  /// switches between dark, light and standard OSM for this session.
  String _basemap = UserPreferencesService.basemapDark;

  /// The CARTO dark style is the only dark basemap; light and standard
  /// OSM both use the light chrome (dot, casing, background).
  bool get _darkMode => _basemap == UserPreferencesService.basemapDark;

  BasemapTheme get _basemapTheme {
    switch (_basemap) {
      case UserPreferencesService.basemapStandard:
        return BasemapTheme.standard;
      case UserPreferencesService.basemapLight:
        return BasemapTheme.light;
      case UserPreferencesService.basemapDark:
      default:
        return BasemapTheme.dark;
    }
  }

  String get _basemapLabel {
    switch (_basemap) {
      case UserPreferencesService.basemapStandard:
        return 'Standard OSM';
      case UserPreferencesService.basemapLight:
        return 'Light';
      case UserPreferencesService.basemapDark:
      default:
        return 'Dark';
    }
  }

  IconData get _basemapIcon {
    switch (_basemap) {
      case UserPreferencesService.basemapStandard:
        return CupertinoIcons.globe;
      case UserPreferencesService.basemapLight:
        return CupertinoIcons.sun_max_fill;
      case UserPreferencesService.basemapDark:
      default:
        return CupertinoIcons.moon_fill;
    }
  }

  @override
  void initState() {
    super.initState();
    _load(sync: true);
    UserPreferencesService.instance.loadBasemapTheme().then((basemap) {
      if (mounted) setState(() => _basemap = basemap);
    });
    LocationService.instance.getCurrentLocation().then((loc) {
      if (loc != null && mounted) setState(() => _me = (loc.latitude, loc.longitude));
    });
  }

  Future<void> _load({bool sync = false}) async {
    final buildings = await _repo.loadBuildings();
    final connections = await _repo.loadConnections(sync: sync);
    if (!mounted) return;
    setState(() {
      _buildings = buildings;
      _connections = connections;
      _loading = false;
    });
  }

  LatLng _ll(GeoPoint p) => LatLng(p.$1, p.$2);

  void _onBuildingTap(MappedBuilding building) =>
      _showBuildingSheet(building);

  Future<void> _delete(BuildingConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this link?'),
        content: Text('${c.a.building} and ${c.b.building} will no longer be routed between.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteConnection(c);
    await _load();
  }

  String _describe(BuildingConnection c) {
    final minutes = (c.durationSeconds / 60).ceil();
    return '${c.distanceMeters.toStringAsFixed(0)} m walk, about $minutes min'
        '${c.source == 'straight' ? ' (straight line)' : ''}';
  }

  void _setBasemap(String basemap) {
    setState(() => _basemap = basemap);
  }

  /// Basemap picker: dark / light monochrome plus standard OSM.
  /// Changes apply to this session only; the default lives in
  /// Preferences.
  void _showBasemapPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Map style',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Current: $_basemapLabel',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final option in [
                (
                  value: UserPreferencesService.basemapDark,
                  icon: CupertinoIcons.moon_fill,
                  title: 'Dark',
                  subtitle: 'Monochrome dark basemap',
                ),
                (
                  value: UserPreferencesService.basemapLight,
                  icon: CupertinoIcons.sun_max_fill,
                  title: 'Light',
                  subtitle: 'Monochrome light basemap',
                ),
                (
                  value: UserPreferencesService.basemapStandard,
                  icon: CupertinoIcons.globe,
                  title: 'Standard OSM',
                  subtitle: 'Full-color OpenStreetMap',
                ),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(option.icon, color: Colors.black, size: 22),
                  title: Text(option.title),
                  subtitle: Text(option.subtitle),
                  trailing: _basemap == option.value
                      ? const Icon(CupertinoIcons.checkmark,
                          color: Colors.black, size: 20)
                      : null,
                  onTap: () {
                    _setBasemap(option.value);
                    Navigator.pop(context);
                  },
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const PreferencesScreen()),
                    ).then((_) async {
                      final basemap = await UserPreferencesService
                          .instance
                          .loadBasemapTheme();
                      if (mounted) setState(() => _basemap = basemap);
                    });
                  },
                  child: const Text('Set default'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- building sheet ----------------------------------------------------

  void _showBuildingSheet(MappedBuilding b) {
    final links = _connections.where((c) => c.involves(b.name)).toList();
    final floors = b.floorKeys.keys.toList()..sort();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(b.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700)),
                ),
                SavePlaceButton(
                    place: SavedPlace.forBuilding(b.name)),
              ],
            ),
            Text(
              '${floors.length} floor${floors.length == 1 ? '' : 's'} · '
              '${b.entrancesWithGps.length} entrance${b.entrancesWithGps.length == 1 ? '' : 's'} on the map',
              style: const TextStyle(color: Color(0xFF71717A)),
            ),
            const SizedBox(height: 8),
            for (final f in floors)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.layers_outlined),
                title: Text('Floor $f'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SavePlaceButton(
                      place: SavedPlace.forFloor(b.name, f,
                          mapKey: b.floorKeys[f]),
                      iconSize: 18,
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    this.context,
                    MaterialPageRoute(
                      builder: (_) => MapViewerScreen(mapKey: b.floorKeys[f]!, mapName: '${b.name} · Floor $f'),
                    ),
                  ).then((_) => _load());
                },
              ),
            if (links.isNotEmpty) ...[
              const Divider(),
              const Text('Linked buildings', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final c in links)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.directions_walk),
                  title: Text(c.otherEnd(b.name).building),
                  subtitle: Text(
                    'From ${c.entranceIn(b.name).label} to ${c.otherEnd(b.name).label} · ${_describe(c)}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.link_off, color: Colors.red),
                    tooltip: 'Remove link',
                    onPressed: () {
                      Navigator.pop(context);
                      _delete(c);
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- map ---------------------------------------------------------------

  LatLng get _initialCenter {
    final pins = _buildings.values.map((b) => b.pinLocation).whereType<GeoPoint>().toList();
    if (pins.isNotEmpty) {
      return LatLng(
        pins.map((p) => p.$1).reduce((a, b) => a + b) / pins.length,
        pins.map((p) => p.$2).reduce((a, b) => a + b) / pins.length,
      );
    }
    return _me == null ? const LatLng(20, 78) : _ll(_me!);
  }

  @override
  Widget build(BuildContext context) {
    final placed = _buildings.values.where((b) => b.pinLocation != null).toList();
    final unplaced = _buildings.values.where((b) => b.pinLocation == null).map((b) => b.name).toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor:
          _darkMode ? const Color(0xFF18181B) : Colors.white,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : Stack(
              children: [
                Positioned.fill(
                  child: Hero(
                    tag: OutdoorMapScreen.heroTag,
                    // ClipRect keeps tiles inside the flight bounds while
                    // the hero expands between routes.
                    child: ClipRect(
                      child: Material(
                        type: MaterialType.transparency,
                        child: FlutterMap(
                          mapController: _map,
                          options: MapOptions(
                            initialCenter: _initialCenter,
                            initialZoom:
                                placed.isEmpty && _me == null ? 4 : 17,
                            maxZoom: 20,
                            backgroundColor: _darkMode
                                ? const Color(0xFF18181B)
                                : const Color(0xFFF4F4F5),
                          ),
                          children: [
                            basemapTileLayer(_basemapTheme),
                            PolylineLayer(
                              polylines: [
                                // Casing under each route so the line reads on the
                                // basemap (polished nav look). Colors invert with
                                // the light/dark theme.
                                for (final c in _connections)
                                  Polyline(
                                    points: [
                                      for (final p in c.route) _ll(p)
                                    ],
                                    strokeWidth: 8,
                                    color: _darkMode
                                        ? const Color(0xFF18181B)
                                        : Colors.white,
                                    pattern: c.source == 'straight'
                                        ? StrokePattern.dashed(
                                            segments: const [12, 8])
                                        : const StrokePattern.solid(),
                                  ),
                                for (final c in _connections)
                                  Polyline(
                                    points: [
                                      for (final p in c.route) _ll(p)
                                    ],
                                    strokeWidth: 5,
                                    color: _darkMode
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
                                for (final b in placed)
                                  for (final e in b.entrancesWithGps)
                                    Marker(
                                      point: LatLng(
                                          e.latitude!, e.longitude!),
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
                                if (_me != null)
                                  Marker(
                                      point: _ll(_me!),
                                      width: 72,
                                      height: 72,
                                      child: userLocationDot(
                                          dark: _darkMode)),
                                for (final b in placed)
                                  Marker(
                                    point: _ll(b.pinLocation!),
                                    width: 150,
                                    height: 70,
                                    alignment: Alignment.topCenter,
                                    child: GestureDetector(
                                      onTap: () => _onBuildingTap(b),
                                      child:
                                          _BuildingPin(name: b.name),
                                    ),
                                  ),
                              ],
                            ),
                            basemapAttribution(_basemapTheme),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Floating header matching the dashboard:
                // separate circular back button + perfectly-rounded pill.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Row(
                        children: [
                          _GlassCircleButton(
                            icon: CupertinoIcons.back,
                            tooltip: 'Back',
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _GlassPill(
                              child: Text(
                                'Outdoor Map',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Map controls docked in a vertical stack on the right
                // edge, nudged a little above center, clear of the header.
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: SafeArea(
                    child: Align(
                      alignment: const Alignment(1.0, -0.35),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _GlassCircleButton(
                            icon: _basemapIcon,
                            tooltip: 'Map style: $_basemapLabel',
                            onPressed: _showBasemapPicker,
                          ),
                          const SizedBox(height: 10),
                          _GlassCircleButton(
                            icon: Icons.my_location,
                            tooltip: 'My location',
                            onPressed: _me == null
                                ? null
                                : () => _map.move(_ll(_me!), 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (unplaced.isNotEmpty)
                  Positioned(
                    top: 76,
                    left: 12,
                    right: 12,
                    child: _Banner(
                      text: 'Not on the map yet: ${unplaced.join(', ')}. '
                          'Add an Entrance with GPS in the map editor to place them.',
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Separate circular floating button (dashboard style).
/// Plain white background with a 1px zinc border.
/// Null [onPressed] renders a disabled muted icon.
class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _GlassCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
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
              child: Icon(
                icon,
                color: enabled ? Colors.black : const Color(0xFFA1A1AA),
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Perfectly-rounded (stadium) pill (dashboard style).
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

class _BuildingPin extends StatelessWidget {
  final String name;
  const _BuildingPin({required this.name});

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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Icon(Icons.apartment, color: Colors.white, size: 20),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: const Color(0xFFE4E4E7),
              width: 1,
            ),
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black),
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Text(text,
            style: const TextStyle(color: Colors.black, fontSize: 13)),
      ),
    );
  }
}
