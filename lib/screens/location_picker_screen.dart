import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/location_service.dart';
import '../widgets/osm_layers.dart';

/// Picks a spot on the street map: the user pans the map until the pin in
/// the middle sits on the right spot (e.g. a building's door), then confirms.
/// Pops the chosen [LatLng], or null when cancelled.
class LocationPickerScreen extends StatefulWidget {
  final LatLng? initial;
  final String title;

  const LocationPickerScreen({super.key, this.initial, this.title = 'Pick location'});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _map = MapController();
  LatLng? _center;
  LatLng? _gps;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _center = widget.initial;
    _locate(moveMap: widget.initial == null);
  }

  Future<void> _locate({required bool moveMap}) async {
    final loc = await LocationService.instance.getCurrentLocation();
    if (loc == null || !mounted) return;
    final here = LatLng(loc.latitude, loc.longitude);
    setState(() {
      _gps = here;
      if (moveMap) _center = here;
    });
    if (moveMap && _mapReady) _map.move(here, 18);
  }

  @override
  Widget build(BuildContext context) {
    final center = _center;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: 'Go to my location',
            onPressed: () => _locate(moveMap: true),
          ),
        ],
      ),
      body: center == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.black),
                  SizedBox(height: 12),
                  Text('Finding your location...'),
                ],
              ),
            )
          : Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 18,
                    maxZoom: 20,
                    onMapReady: () => _mapReady = true,
                    onPositionChanged: (camera, _) => setState(() => _center = camera.center),
                  ),
                  children: [
                    osmTileLayer(),
                    if (_gps != null)
                      MarkerLayer(markers: [Marker(point: _gps!, width: 72, height: 72, child: userLocationDot())]),
                    osmAttribution(),
                  ],
                ),
                // Fixed pin in the middle; its tip marks the chosen spot.
                const IgnorePointer(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 44),
                      child: Icon(Icons.location_on, size: 48, color: Colors.black),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: center == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Move the map so the pin is on the exact spot.\n'
                      '${center.latitude.toStringAsFixed(6)}, ${center.longitude.toStringAsFixed(6)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      onPressed: () => Navigator.pop(context, center),
                      child: const Text('Use this location', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
