import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../logic/geo_math.dart';
import '../models/outdoor_models.dart';
import '../models/map_models.dart';
import '../models/saved_place.dart';
import '../services/building_repository.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/user_preferences_service.dart';
import '../widgets/osm_layers.dart';
import '../widgets/save_place_button.dart';
import 'map_viewer_screen.dart';
import 'preferences_screen.dart';

/// Outdoor map view of every mapped building and the outdoor routes
/// linking them. Tap a building to open its floors or link it to another.
class OutdoorMapScreen extends StatefulWidget {
  const OutdoorMapScreen({super.key});

  @override
  State<OutdoorMapScreen> createState() => _OutdoorMapScreenState();
}

class _OutdoorMapScreenState extends State<OutdoorMapScreen> {
  final _map = MapController();
  final _repo = BuildingRepository.instance;
  final _routing = RoutingService();

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

  /// Set while linking: the building chosen first.
  String? _connectFrom;

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

  // ---- linking -----------------------------------------------------------

  void _onBuildingTap(MappedBuilding building) {
    final from = _connectFrom;
    if (from == null) {
      _showBuildingSheet(building);
    } else if (from == building.name) {
      _snack('Tap a different building to link ${building.name} to');
    } else {
      setState(() => _connectFrom = null);
      _connect(_buildings[from]!, building);
    }
  }

  void _startConnecting(MappedBuilding from) {
    Navigator.pop(context);
    if (from.entrancesWithGps.isEmpty) {
      _explainNoEntrance(from);
      return;
    }
    setState(() => _connectFrom = from.name);
  }

  Future<void> _connect(MappedBuilding a, MappedBuilding b) async {
    if (b.entrancesWithGps.isEmpty) {
      _explainNoEntrance(b);
      return;
    }
    final pair = await _pickEntrances(a, b);
    if (pair == null || !mounted) return;
    final (ea, eb) = pair;
    final from = (ea.latitude!, ea.longitude!), to = (eb.latitude!, eb.longitude!);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(color: Colors.black),
          SizedBox(width: 16),
          Expanded(child: Text('Finding the walking route...')),
        ]),
      ),
    );
    WalkingRoute? route;
    String? error;
    try {
      route = await _routing.walkingRoute(from, to);
    } on RoutingException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    Navigator.pop(context);

    if (route == null) {
      final straight = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No footpath route'),
          content: Text('$error\n\nLink the buildings with a straight line between the entrances instead?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use straight line')),
          ],
        ),
      );
      if (straight != true) return;
      route = WalkingRoute.straight(from, to);
    }

    final connection = BuildingConnection(
      a: EntranceRef(building: a.name, floor: ea.floor, label: ea.label),
      b: EntranceRef(building: b.name, floor: eb.floor, label: eb.label),
      distanceMeters: route.distanceMeters,
      durationSeconds: route.durationSeconds,
      route: route.points,
      source: route.source,
    );
    await _repo.saveConnection(connection);
    await _load();
    _snack('Linked ${a.name} and ${b.name}: ${_describe(connection)}');
  }

  /// The entrances to link. With one each there is nothing to choose;
  /// otherwise the closest pair is suggested.
  Future<(Waypoint, Waypoint)?> _pickEntrances(MappedBuilding a, MappedBuilding b) async {
    final as = a.entrancesWithGps, bs = b.entrancesWithGps;
    var best = (as.first, bs.first);
    for (final x in as) {
      for (final y in bs) {
        if (_gap(x, y) < _gap(best.$1, best.$2)) best = (x, y);
      }
    }
    if (as.length == 1 && bs.length == 1) return best;

    var (ea, eb) = best;
    return showDialog<(Waypoint, Waypoint)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Which entrances?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (building, options, selected, set) in [
                (a, as, ea, (Waypoint w) => ea = w),
                (b, bs, eb, (Waypoint w) => eb = w),
              ])
                DropdownButtonFormField<Waypoint>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: building.name),
                  items: [
                    for (final w in options)
                      DropdownMenuItem(value: w, child: Text('${w.displayName} · Floor ${w.floor}')),
                  ],
                  onChanged: (w) => setDialog(() => set(w!)),
                ),
              const SizedBox(height: 8),
              Text('${_gap(ea, eb).toStringAsFixed(0)} m apart in a straight line',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF71717A))),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, (ea, eb)), child: const Text('Link')),
          ],
        ),
      ),
    );
  }

  double _gap(Waypoint x, Waypoint y) => haversineMeters((x.latitude!, x.longitude!), (y.latitude!, y.longitude!));

  void _explainNoEntrance(MappedBuilding b) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${b.name} has no entrance on the map'),
        content: const Text(
          'Buildings are linked through their entrances. Open the building, tap the edit (pencil) button, '
          'and add a place of type "Entrance" at the door. Its GPS position is recorded so it can be '
          'placed on the street map.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

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

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _buildings.length < 2 ? null : () => _startConnecting(b),
              icon: const Icon(Icons.add_link),
              label: const Text('Link to another building'),
            ),
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
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _initialCenter,
                    initialZoom: placed.isEmpty && _me == null ? 4 : 17,
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
                            points: [for (final p in c.route) _ll(p)],
                            strokeWidth: 8,
                            color: _darkMode
                                ? const Color(0xFF18181B)
                                : Colors.white,
                            pattern: c.source == 'straight'
                                ? StrokePattern.dashed(segments: const [12, 8])
                                : const StrokePattern.solid(),
                          ),
                        for (final c in _connections)
                          Polyline(
                            points: [for (final p in c.route) _ll(p)],
                            strokeWidth: 5,
                            color: _darkMode ? Colors.white : Colors.black,
                            pattern: c.source == 'straight'
                                ? StrokePattern.dashed(segments: const [12, 8])
                                : const StrokePattern.solid(),
                          ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (final b in placed)
                          for (final e in b.entrancesWithGps)
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
                                child: Icon(Icons.door_front_door, size: 15, color: Colors.black),
                              ),
                            ),
                        if (_me != null) Marker(point: _ll(_me!), width: 72, height: 72, child: userLocationDot(dark: _darkMode)),
                        for (final b in placed)
                          Marker(
                            point: _ll(b.pinLocation!),
                            width: 150,
                            height: 70,
                            alignment: Alignment.topCenter,
                            child: GestureDetector(
                              onTap: () => _onBuildingTap(b),
                              child: _BuildingPin(name: b.name, selected: b.name == _connectFrom),
                            ),
                          ),
                      ],
                    ),
                    basemapAttribution(_basemapTheme),
                  ],
                ),
                // Floating frosted-glass header matching the dashboard:
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
                            icon: CupertinoIcons.location_fill,
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
                if (_connectFrom != null)
                  Positioned(
                    top: 76,
                    left: 12,
                    right: 12,
                    child: _Banner(
                      text: 'Tap the building to link $_connectFrom to',
                      action: TextButton(
                        onPressed: () => setState(() => _connectFrom = null),
                        child: const Text('Cancel', style: TextStyle(color: Colors.black)),
                      ),
                    ),
                  )
                else if (unplaced.isNotEmpty)
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

/// Separate circular floating frosted-glass button (dashboard style).
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
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.85),
                Colors.white.withValues(alpha: 0.55),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.65),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Top sheen for a frosted-glass highlight.
              Positioned(
                top: 6,
                left: 14,
                right: 14,
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.55),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
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
                    color: enabled
                        ? Colors.black
                        : const Color(0xFFA1A1AA),
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Perfectly-rounded (stadium) frosted-glass pill (dashboard style).
class _GlassPill extends StatelessWidget {
  final Widget child;

  const _GlassPill({required this.child});

  @override
  Widget build(BuildContext context) {
    // 52px tall -> 26px radius = fully rounded ends regardless of width.
    const radius = BorderRadius.all(Radius.circular(26));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.fromRGBO(255, 255, 255, 0.85),
                Color.fromRGBO(255, 255, 255, 0.55),
              ],
            ),
            border: Border.fromBorderSide(
              BorderSide(
                color: Color.fromRGBO(255, 255, 255, 0.65),
                width: 1.2,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.12),
                blurRadius: 20,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Top sheen for a frosted-glass highlight.
              Positioned(
                top: 5,
                left: 28,
                right: 28,
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.fromRGBO(255, 255, 255, 0.55),
                        Color.fromRGBO(255, 255, 255, 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _BuildingPin extends StatelessWidget {
  final String name;
  final bool selected;
  const _BuildingPin({required this.name, required this.selected});

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
              color: selected ? Colors.black : const Color(0xFFE4E4E7),
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
  final Widget? action;
  const _Banner({required this.text, this.action});

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
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          children: [
            Expanded(child: Text(text, style: const TextStyle(color: Colors.black, fontSize: 13))),
            ?action,
          ],
        ),
      ),
    );
  }
}
