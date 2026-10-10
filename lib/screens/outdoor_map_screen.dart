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
import '../widgets/osm_layers.dart';
import '../widgets/save_place_button.dart';
import 'map_viewer_screen.dart';

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

  /// Set while linking: the building chosen first.
  String? _connectFrom;

  @override
  void initState() {
    super.initState();
    _load(sync: true);
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
      appBar: AppBar(
        title: const Text('Outdoor Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: 'My location',
            onPressed: _me == null ? null : () => _map.move(_ll(_me!), 18),
          ),
        ],
      ),
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
                    backgroundColor: const Color(0xFFF4F4F5),
                  ),
                  children: [
                    osmTileLayer(),
                    PolylineLayer(
                      polylines: [
                        // White casing under each route so the black line
                        // reads on the light basemap (polished nav look).
                        for (final c in _connections)
                          Polyline(
                            points: [for (final p in c.route) _ll(p)],
                            strokeWidth: 8,
                            color: Colors.white,
                            pattern: c.source == 'straight'
                                ? StrokePattern.dashed(segments: const [12, 8])
                                : const StrokePattern.solid(),
                          ),
                        for (final c in _connections)
                          Polyline(
                            points: [for (final p in c.route) _ll(p)],
                            strokeWidth: 5,
                            color: Colors.black,
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
                        if (_me != null) Marker(point: _ll(_me!), width: 20, height: 20, child: userLocationDot()),
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
                    osmAttribution(),
                  ],
                ),
                if (_connectFrom != null)
                  Positioned(
                    top: 12,
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
                    top: 12,
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
