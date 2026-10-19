import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../logic/geo_math.dart';
import '../models/map_models.dart';
import '../models/outdoor_models.dart';
import '../services/building_repository.dart';
import '../services/location_service.dart';
import '../services/routing_service.dart';
import '../services/user_preferences_service.dart';
import '../widgets/osm_layers.dart';
import 'map_viewer_screen.dart';
import 'preferences_screen.dart';

/// Admin screen for linking buildings across campus via outdoor walking routes.
/// Restores the campus building connection workflow from commit 0764faa.
class ConnectorLinksScreen extends StatefulWidget {
  final String? initialBuilding;

  const ConnectorLinksScreen({super.key, this.initialBuilding});

  @visibleForTesting
  static void resetStaticCache() => _ConnectorLinksScreenState.resetStaticCache();

  @override
  State<ConnectorLinksScreen> createState() => _ConnectorLinksScreenState();
}

class _ConnectorLinksScreenState extends State<ConnectorLinksScreen> {
  // Static screen-level cache so returning to this screen renders instantly
  static Map<String, MappedBuilding>? _cachedBuildings;
  static List<BuildingConnection>? _cachedConnections;
  static GeoPoint? _cachedLocation;
  static LatLng? _cachedCenter;
  static double? _cachedZoom;

  @visibleForTesting
  static void resetStaticCache() {
    _cachedBuildings = null;
    _cachedConnections = null;
    _cachedLocation = null;
    _cachedCenter = null;
    _cachedZoom = null;
  }

  final _map = MapController();
  final _repo = BuildingRepository.instance;
  final _routing = RoutingService();

  Map<String, MappedBuilding> _buildings = _cachedBuildings ?? {};
  List<BuildingConnection> _connections = _cachedConnections ?? [];
  late bool _loading = _buildings.isEmpty;
  GeoPoint? _me;
  bool _userHasPanned = false;

  /// Set while linking: the building chosen first.
  String? _connectFrom;

  String _basemap = UserPreferencesService.basemapStandard;

  bool get _darkMode => _basemap == UserPreferencesService.basemapDark;

  BasemapTheme get _basemapTheme {
    switch (_basemap) {
      case UserPreferencesService.basemapDark:
        return BasemapTheme.dark;
      case UserPreferencesService.basemapLight:
        return BasemapTheme.light;
      case UserPreferencesService.basemapStandard:
      default:
        return BasemapTheme.standard;
    }
  }

  String get _basemapLabel {
    switch (_basemap) {
      case UserPreferencesService.basemapDark:
        return 'Dark';
      case UserPreferencesService.basemapLight:
        return 'Light';
      case UserPreferencesService.basemapStandard:
      default:
        return 'Standard OSM';
    }
  }

  IconData get _basemapIcon {
    switch (_basemap) {
      case UserPreferencesService.basemapDark:
        return CupertinoIcons.moon_fill;
      case UserPreferencesService.basemapLight:
        return CupertinoIcons.sun_max_fill;
      case UserPreferencesService.basemapStandard:
      default:
        return CupertinoIcons.globe;
    }
  }

  @override
  void initState() {
    super.initState();
    // Restore cached location if known
    final cached = _cachedLocation ??
        (LocationService.instance.cachedLocation != null
            ? (
                LocationService.instance.cachedLocation!.latitude,
                LocationService.instance.cachedLocation!.longitude
              )
            : null);
    if (cached != null) {
      _me = cached;
    }

    _load(sync: _cachedBuildings == null);
    UserPreferencesService.instance.loadBasemapTheme().then((basemap) {
      if (mounted) setState(() => _basemap = basemap);
    });
    _loadUserLocation(moveToUser: widget.initialBuilding == null);
  }

  Future<void> _loadUserLocation({bool moveToUser = true}) async {
    // 1. Try restoring fast cached/persisted location
    final cached = await LocationService.instance.getLastKnownOrCachedLocation();
    if (cached != null && mounted) {
      final p = (cached.latitude, cached.longitude);
      _cachedLocation = p;
      setState(() => _me = p);
      if (moveToUser && !_userHasPanned && widget.initialBuilding == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _map.move(_ll(p), 17.5);
        });
      }
    }

    // 2. Refresh with high-accuracy live GPS fix
    try {
      final loc = await LocationService.instance.getCurrentLocation();
      if (loc != null && mounted) {
        final p = (loc.latitude, loc.longitude);
        _cachedLocation = p;
        final wasNull = _me == null;
        setState(() => _me = p);
        if ((wasNull || moveToUser) && !_userHasPanned && widget.initialBuilding == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _map.move(_ll(p), 17.5);
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _load({bool sync = false}) async {
    final buildings = await _repo.loadBuildings();
    final connections = await _repo.loadConnections(sync: sync);
    _cachedBuildings = buildings;
    _cachedConnections = connections;
    if (!mounted) return;
    setState(() {
      _buildings = buildings;
      _connections = connections;
      _loading = false;
    });

    if (widget.initialBuilding != null &&
        _buildings.containsKey(widget.initialBuilding) &&
        _connectFrom == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _connectFrom == null) {
          _showBuildingSheet(_buildings[widget.initialBuilding]!);
        }
      });
    }
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
    if (a.entrancesWithGps.isEmpty) {
      _explainNoEntrance(a);
      return;
    }
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
        content: Row(
          children: [
            CircularProgressIndicator(color: Colors.black),
            SizedBox(width: 16),
            Expanded(child: Text('Finding the walking route...')),
          ],
        ),
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
          content: Text(
            '${error ?? 'No route available'}\n\n'
            'Link the buildings with a straight line between the entrances instead?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use straight line'),
            ),
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
  Future<(Waypoint, Waypoint)?> _pickEntrances(
    MappedBuilding a,
    MappedBuilding b,
  ) async {
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
                      DropdownMenuItem(
                        value: w,
                        child: Text('${w.displayName} · Floor ${w.floor}'),
                      ),
                  ],
                  onChanged: (w) => setDialog(() => set(w!)),
                ),
              const SizedBox(height: 8),
              Text(
                '${_gap(ea, eb).toStringAsFixed(0)} m apart in a straight line',
                style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, (ea, eb)),
              child: const Text('Link'),
            ),
          ],
        ),
      ),
    );
  }

  double _gap(Waypoint x, Waypoint y) =>
      haversineMeters((x.latitude!, x.longitude!), (y.latitude!, y.longitude!));

  void _explainNoEntrance(MappedBuilding b) {
    final hasEntrance = b.entrances.isNotEmpty;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(hasEntrance
            ? '${b.name} entrance has no GPS position'
            : '${b.name} has no entrance on the map'),
        content: Text(
          hasEntrance
              ? 'Buildings are linked through their entrances with GPS coordinates. '
                  'Open ${b.name} in the floor editor and adjust the entrance place to set its GPS position on the map.'
              : 'Buildings are linked through their entrances. Open the building in MapX Studio, '
                  'open the floor editor, and add a place of type "Entrance" at the door. '
                  'Its GPS position is recorded so it can be placed on the street map.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildingConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this link?'),
        content: Text(
          '${c.a.building} and ${c.b.building} will no longer be routed between.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _connectFrom = null);
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
              Text('Map style', style: Theme.of(context).textTheme.titleMedium),
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
                  title: 'Dark Blue',
                  subtitle: 'Dark blue shade night basemap',
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
                      final basemap = await UserPreferencesService.instance
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(
              b.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
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
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    this.context,
                    MaterialPageRoute(
                      builder: (_) => MapViewerScreen(
                        mapKey: b.floorKeys[f]!,
                        mapName: '${b.name} · Floor $f',
                      ),
                    ),
                  ).then((_) => _load());
                },
              ),
            if (links.isNotEmpty) ...[
              const Divider(),
              const Text(
                'Linked buildings',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
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
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black,
                side: const BorderSide(color: Color(0xFFE4E4E7)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed:
                  _buildings.length < 2 ? null : () => _startConnecting(b),
              icon: const Icon(Icons.add_link),
              label: const Text('Link to another building'),
            ),
          ],
        ),
      ),
    );
  }

  LatLng get _initialCenter {
    if (widget.initialBuilding != null &&
        _buildings.containsKey(widget.initialBuilding)) {
      final pin = _buildings[widget.initialBuilding]!.pinLocation;
      if (pin != null) return _ll(pin);
    }
    if (_cachedCenter != null) return _cachedCenter!;
    if (_me != null) return _ll(_me!);
    final pins = _buildings.values
        .map((b) => b.pinLocation)
        .whereType<GeoPoint>()
        .toList();
    if (pins.isNotEmpty) {
      return LatLng(
        pins.map((p) => p.$1).reduce((a, b) => a + b) / pins.length,
        pins.map((p) => p.$2).reduce((a, b) => a + b) / pins.length,
      );
    }
    return const LatLng(20, 78);
  }

  @override
  Widget build(BuildContext context) {
    final placed =
        _buildings.values.where((b) => b.pinLocation != null).toList();
    final unplaced = _buildings.values
        .where((b) => b.pinLocation == null)
        .map((b) => b.name)
        .toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: _darkMode ? const Color(0xFF18181B) : Colors.white,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : Stack(
              children: [
                Positioned.fill(
                  child: ClipRect(
                    child: FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: _initialCenter,
                        initialZoom: _cachedZoom ??
                            (_me != null ? 17 : (placed.isEmpty ? 4 : 17)),
                        maxZoom: 20,
                        backgroundColor: _darkMode
                            ? const Color(0xFF18181B)
                            : const Color(0xFFF4F4F5),
                        onPositionChanged: (pos, hasGesture) {
                          if (hasGesture) {
                            _userHasPanned = true;
                            _cachedCenter = pos.center;
                            _cachedZoom = pos.zoom;
                          }
                        },
                      ),
                      children: [
                        basemapTileLayer(_basemapTheme),
                        PolylineLayer(
                          polylines: [
                            for (final c in _connections)
                              Polyline(
                                points: [for (final p in c.route) _ll(p)],
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
                                points: [for (final p in c.route) _ll(p)],
                                strokeWidth: 5,
                                color: _darkMode ? Colors.white : Colors.black,
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
                                  point: LatLng(e.latitude!, e.longitude!),
                                  width: 22,
                                  height: 22,
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.fromBorderSide(
                                        BorderSide(
                                            color: Color(0xFFE4E4E7), width: 1),
                                      ),
                                    ),
                                    child: Icon(Icons.door_front_door,
                                        size: 14, color: Colors.black),
                                  ),
                                ),
                            if (_me != null)
                              Marker(
                                point: _ll(_me!),
                                width: 72,
                                height: 72,
                                alignment: Alignment.center,
                                child: userLocationDot(dark: _darkMode),
                              ),
                            for (final b in placed)
                              Marker(
                                point: _ll(b.pinLocation!),
                                width: 150,
                                height: 70,
                                alignment: Alignment.topCenter,
                                child: GestureDetector(
                                  onTap: () => _onBuildingTap(b),
                                  child: _BuildingPin(
                                    name: b.name,
                                    selected: b.name == _connectFrom,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        basemapAttribution(_basemapTheme),
                      ],
                    ),
                  ),
                ),
                // Floating top header
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
                            tooltip: 'Back to Studio',
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _GlassPill(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Connector Links',
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'ADMIN',
                                      style: GoogleFonts.inter(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Floating right map controls
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
                            onPressed: () {
                              if (_me != null) {
                                _userHasPanned = false;
                                _cachedCenter = _ll(_me!);
                                _map.move(_ll(_me!), 18);
                              } else {
                                _loadUserLocation(moveToUser: true);
                              }
                            },
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
                        child: const Text('Cancel',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w600)),
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

class _GlassPill extends StatelessWidget {
  final Widget child;

  const _GlassPill({required this.child});

  @override
  Widget build(BuildContext context) {
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
  final bool selected;

  const _BuildingPin({required this.name, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final pinColor = selected ? Colors.black : const Color(0xFF27272A);
    final borderColor = selected ? Colors.black : const Color(0xFFE4E4E7);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: pinColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? const Color(0xFFE4E4E7) : Colors.white,
              width: selected ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.45 : 0.25),
                blurRadius: selected ? 10 : 8,
                spreadRadius: selected ? 2 : 1,
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
              color: borderColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 4),
                const Icon(CupertinoIcons.link, size: 11, color: Colors.black),
              ],
            ],
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
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}
