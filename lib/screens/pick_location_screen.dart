import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../services/location_service.dart';
import '../widgets/osm_layers.dart';

/// Full-screen OSM picker: tap anywhere to drop the building pin,
/// then confirm. Returns the picked [LatLng] via `Navigator.pop`.
class PickLocationScreen extends StatefulWidget {
  /// Initial pin position (existing building fix, GPS, or map default).
  final LatLng initial;

  const PickLocationScreen({super.key, required this.initial});

  @override
  State<PickLocationScreen> createState() => _PickLocationScreenState();
}

class _PickLocationScreenState extends State<PickLocationScreen> {
  final _map = MapController();
  final _mapKey = GlobalKey();
  late LatLng _picked;
  LatLng? _me;
  bool _locatingMe = false;
  bool _draggingPin = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
    _locateMe(move: false);
  }

  Future<void> _locateMe({bool move = true}) async {
    if (_locatingMe) return;
    setState(() => _locatingMe = true);
    try {
      final cached = await LocationService.instance.getLastKnownOrCachedLocation();
      if (cached != null && mounted && _me == null) {
        final p = LatLng(cached.latitude, cached.longitude);
        setState(() => _me = p);
        if (move) _map.move(p, 17);
      }

      final loc = await LocationService.instance.getCurrentLocation();
      if (!mounted || loc == null) return;
      final p = LatLng(loc.latitude, loc.longitude);
      setState(() {
        _me = p;
        _locatingMe = false;
      });
      if (move) _map.move(p, 17);
    } catch (_) {
      if (mounted) setState(() => _locatingMe = false);
    }
    if (mounted && _locatingMe) setState(() => _locatingMe = false);
  }

  /// Long-press-drag on the pin: converts the finger's map-local offset
  /// back to a LatLng on every move so the pin follows the finger.
  void _onPinDragUpdate(LongPressMoveUpdateDetails details) {
    final box =
        _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(details.globalPosition);
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > box.size.width ||
        local.dy > box.size.height) {
      return;
    }
    setState(() {
      _picked = _map.camera.screenOffsetToLatLng(local);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left,
              color: Colors.black, size: 22),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          'Pin Location',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.black,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                _draggingPin
                    ? 'Release to drop the pin here, then confirm.'
                    : 'Tap to place the pin, or hold the pin and drag it, then confirm.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF71717A),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    key: _mapKey,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0xFFE4E4E7), width: 1),
                    ),
                    child: FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: _picked,
                        initialZoom: 17,
                        maxZoom: 20,
                        backgroundColor: const Color(0xFFF4F4F5),
                        // Freeze map panning while the pin is being
                        // dragged so the finger moves the pin, not the map.
                        interactionOptions: InteractionOptions(
                          flags: _draggingPin
                              ? InteractiveFlag.none
                              : InteractiveFlag.all,
                        ),
                        onTap: (_, latLng) =>
                            setState(() => _picked = latLng),
                      ),
                      children: [
                        basemapTileLayer(BasemapTheme.standard),
                        MarkerLayer(
                          markers: [
                            if (_me != null)
                              Marker(
                                point: _me!,
                                width: 72,
                                height: 72,
                                alignment: Alignment.center,
                                child: userLocationDot(dark: false),
                              ),
                            Marker(
                              point: _picked,
                              width: 88,
                              height: 88,
                              alignment: Alignment.topCenter,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPressStart: (_) =>
                                    setState(() => _draggingPin = true),
                                onLongPressMoveUpdate: _onPinDragUpdate,
                                onLongPressEnd: (_) =>
                                    setState(() => _draggingPin = false),
                                child:
                                    _PickedPin(dragging: _draggingPin),
                              ),
                            ),
                          ],
                        ),
                        basemapAttribution(BasemapTheme.standard),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: const Color(0xFFE4E4E7)),
                    ),
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.map_pin,
                            size: 18, color: Color(0xFF27272A)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${_picked.latitude.toStringAsFixed(6)}, ${_picked.longitude.toStringAsFixed(6)}',
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color: const Color(0xFF27272A)),
                          ),
                        ),
                        IconButton(
                          icon: _locatingMe
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(CupertinoIcons.location,
                                  size: 18,
                                  color: Color(0xFF27272A)),
                          tooltip: 'My location',
                          onPressed: () => _locateMe(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, _picked),
                      child: Text(
                        'Use this location',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickedPin extends StatelessWidget {
  final bool dragging;
  const _PickedPin({this.dragging = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          scale: dragging ? 1.35 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: Colors.black,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: dragging
                  ? const [
                      BoxShadow(
                        color: Color(0x6627272A),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: const Icon(CupertinoIcons.map_pin,
                color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }
}
