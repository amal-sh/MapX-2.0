import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../logic/outdoor_route_planner.dart';
import '../logic/geo_math.dart';
import '../models/outdoor_models.dart';
import '../services/location_service.dart';
import '../widgets/osm_layers.dart';

/// The outdoor part of a trip between buildings: the street map with the
/// walking route and a live GPS dot, like a walking-directions app. Pops
/// true once the walker confirms they're at the next building's entrance,
/// false if they stop navigating.
class OutdoorNavigationScreen extends StatefulWidget {
  final OutdoorHop hop;

  const OutdoorNavigationScreen({super.key, required this.hop});

  @override
  State<OutdoorNavigationScreen> createState() => _OutdoorNavigationScreenState();
}

class _OutdoorNavigationScreenState extends State<OutdoorNavigationScreen> {
  // Phone GPS is typically good to 5-10 m outdoors, so "arrived" and "off
  // route" use generous margins.
  static const double _arrivalRadiusMeters = 15;
  static const double _offRouteMeters = 30;

  static const _channel = MethodChannel('mapx/arcore');

  final _map = MapController();
  StreamSubscription<Position>? _gpsSub;
  bool _mapReady = false;
  bool _following = true;

  GeoPoint? _here;
  double? _accuracy;
  double? _course;

  late final List<GeoPoint> _route = widget.hop.route;

  @override
  void initState() {
    super.initState();
    _startGps();
    try {
      _channel.invokeMethod('setKeepScreenOn', {'enabled': true});
    } catch (_) {}
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    try {
      _channel.invokeMethod('setKeepScreenOn', {'enabled': false});
    } catch (_) {}
    super.dispose();
  }

  Future<void> _startGps() async {
    if (!await LocationService.instance.requestPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission is needed to guide you between buildings.')),
        );
      }
      return;
    }
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1),
    ).listen((p) {
      if (!mounted) return;
      final here = (p.latitude, p.longitude);
      setState(() {
        _here = here;
        _accuracy = p.accuracy;
        // GPS course is only meaningful while moving.
        if (p.speed > 0.5) _course = p.heading;
      });
      if (_following && _mapReady) _map.move(LatLng(here.$1, here.$2), _map.camera.zoom);
    });
  }

  Future<bool> _confirmStop() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop navigation?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return stop == true;
  }

  @override
  Widget build(BuildContext context) {
    final hop = widget.hop;
    final here = _here;
    final progress = here == null ? null : progressAlongRoute(_route, here);
    final toEnd = here == null ? null : haversineMeters(here, _route.last);
    final arrived = toEnd != null && (toEnd <= _arrivalRadiusMeters || progress!.remainingMeters <= _arrivalRadiusMeters);
    final offRoute = progress != null && progress.offRouteMeters > _offRouteMeters;
    final remaining = progress?.remainingMeters ?? polylineMeters(_route);
    final entranceName = hop.arrival.label;

    // Grey for the part already walked, blue for what's left.
    final walked = progress == null
        ? <LatLng>[]
        : [for (final p in _route.take(progress.segment + 1)) LatLng(p.$1, p.$2), _ll(progress.closest)];
    final ahead = progress == null
        ? [for (final p in _route) _ll(p)]
        : [_ll(progress.closest), for (final p in _route.skip(progress.segment + 1)) _ll(p)];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmStop() && context.mounted) Navigator.pop(context, false);
      },
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: _ll(_route.first),
                initialZoom: 18,
                maxZoom: 20,
                backgroundColor: const Color(0xFF080E18),
                onMapReady: () => _mapReady = true,
                onPositionChanged: (_, hasGesture) {
                  if (hasGesture && _following) setState(() => _following = false);
                },
              ),
              children: [
                customDarkTileLayer(),
                PolylineLayer(
                  polylines: [
                    if (walked.length > 1)
                      Polyline(
                        points: walked,
                        strokeWidth: 8,
                        color: const Color(0xFF080E18),
                      ),
                    if (walked.length > 1)
                      Polyline(
                        points: walked,
                        strokeWidth: 5,
                        color: const Color(0xFF52525B),
                      ),
                    Polyline(
                      points: ahead,
                      strokeWidth: 9,
                      color: const Color(0xFF080E18),
                    ),
                    Polyline(
                      points: ahead,
                      strokeWidth: 6,
                      color: const Color(0xFF3B82F6),
                    ),
                  ],
                ),
                if (here != null && _accuracy != null)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: _ll(here),
                      radius: _accuracy!,
                      useRadiusInMeter: true,
                      color: const Color(0x223B82F6),
                      borderColor: const Color(0x553B82F6),
                      borderStrokeWidth: 1,
                    ),
                  ]),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _ll(_route.last),
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_on, size: 40, color: Colors.white),
                    ),
                    if (here != null)
                      Marker(
                        point: _ll(here),
                        width: _course == null ? 72 : 36,
                        height: _course == null ? 72 : 36,
                        child: _course == null
                            ? userLocationDot(dark: true)
                            : Transform.rotate(
                                angle: _course! * pi / 180,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(color: Color(0x66000000), blurRadius: 8),
                                    ],
                                  ),
                                  child: const Icon(Icons.navigation, color: Color(0xFF2563EB), size: 22),
                                ),
                              ),
                      ),
                  ],
                ),
                osmAttribution(),
              ],
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              right: 12,
              child: _InstructionCard(
                icon: arrived ? Icons.flag : (offRoute ? Icons.warning_amber_rounded : Icons.directions_walk),
                title: arrived
                    ? 'You\'re at ${hop.toBuilding}'
                    : offRoute
                        ? 'You\'re off the route'
                        : 'Walk to ${hop.toBuilding}',
                subtitle: arrived
                    ? 'Go in through $entranceName'
                    : offRoute
                        ? 'Head back to the blue line'
                        : here == null
                            ? 'Waiting for GPS...'
                            : '${remaining.toStringAsFixed(0)} m to $entranceName · about ${(remaining / 1.3 / 60).ceil()} min',
                onClose: () async {
                  if (await _confirmStop() && context.mounted) Navigator.pop(context, false);
                },
              ),
            ),
            if (!_following)
              Positioned(
                right: 16,
                bottom: MediaQuery.of(context).padding.bottom + 96,
                child: FloatingActionButton.small(
                  heroTag: 'recenter',
                  tooltip: 'My location',
                  backgroundColor: const Color(0xFF18181B),
                  foregroundColor: Colors.white,
                  onPressed: here == null
                      ? null
                      : () {
                          setState(() => _following = true);
                          _map.move(_ll(here), 18);
                        },
                  child: const Icon(Icons.my_location),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: arrived ? Colors.white : const Color(0xFF18181B),
                  foregroundColor: arrived ? Colors.black : Colors.white,
                  side: const BorderSide(color: Color(0xFF27272A)),
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.door_front_door_outlined),
                label: Text(
                  arrived ? 'Continue inside' : 'I\'m at $entranceName',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static LatLng _ll(GeoPoint p) => LatLng(p.$1, p.$2);
}

class _InstructionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  const _InstructionCard({required this.icon, required this.title, required this.subtitle, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Color(0xFFA1A1AA), fontSize: 13)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Stop navigation',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
