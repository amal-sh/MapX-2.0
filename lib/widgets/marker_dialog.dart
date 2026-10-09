import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_models.dart';
import '../screens/location_picker_screen.dart';
import '../services/location_service.dart';

/// Stairs/lifts already marked on [building]'s other floors, one per name,
/// offered in [MarkerDialog] so a connector gets the same name on every floor.
Future<List<Waypoint>> loadConnectorsOnOtherFloors(String building, int floor) async {
  final prefs = await SharedPreferences.getInstance();
  final found = <String, Waypoint>{};
  for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
    final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
    if (data['name'] != building || data['floor'] == floor) continue;
    for (final w in (data['waypoints'] as List? ?? const [])) {
      final wp = Waypoint.fromJson(Map<String, dynamic>.from(w as Map));
      if (wp.isConnector) found.putIfAbsent(wp.connectorKey, () => wp);
    }
  }
  return found.values.toList();
}

/// What the marker dialog decided.
class MarkerDialogResult {
  final String label;
  final String category;
  final bool delete;

  /// GPS position, for entrances.
  final double? latitude;
  final double? longitude;

  const MarkerDialogResult(this.label, this.category, {this.delete = false, this.latitude, this.longitude});

  /// The marked place at node [index] on [floor].
  Waypoint toWaypoint(int index, int floor) =>
      Waypoint(index, label, floor: floor, category: category, latitude: latitude, longitude: longitude);
}

/// Asks what is at a spot: a place, stairs/lift leading to other floors, or
/// an entrance to the outside (which records its GPS position).
/// Pass [initial] to edit an existing marker, which also offers Delete.
/// Returns null when cancelled.
class MarkerDialog extends StatefulWidget {
  final List<Waypoint> knownConnectors;
  final Waypoint? initial;
  const MarkerDialog({super.key, required this.knownConnectors, this.initial});

  @override
  State<MarkerDialog> createState() => _MarkerDialogState();
}

class _MarkerDialogState extends State<MarkerDialog> {
  late final _controller = TextEditingController(text: widget.initial?.label);
  late String _category =
      widget.initial?.isConnector == true || widget.initial?.isEntrance == true ? widget.initial!.category : 'room';
  String? _error;

  late double? _lat = widget.initial?.latitude;
  late double? _lng = widget.initial?.longitude;
  double? _gpsAccuracy;
  bool _gpsLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isConnector => _category == Waypoint.stairsCategory || _category == Waypoint.liftCategory;
  bool get _isEntrance => _category == Waypoint.entranceCategory;

  void _setCategory(String category) {
    setState(() => _category = category);
    if (_isEntrance && _lat == null && !_gpsLoading) _captureGps();
  }

  Future<void> _captureGps() async {
    setState(() => _gpsLoading = true);
    final loc = await LocationService.instance.getCurrentLocation();
    if (!mounted) return;
    setState(() {
      _gpsLoading = false;
      if (loc != null) {
        _lat = loc.latitude;
        _lng = loc.longitude;
        _gpsAccuracy = loc.accuracy;
      }
    });
  }

  Future<void> _adjustOnMap() async {
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initial: _lat == null ? null : LatLng(_lat!, _lng!),
          title: 'Place the entrance',
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lat = picked.latitude;
      _lng = picked.longitude;
      _gpsAccuracy = null; // placed by hand
    });
  }

  void _submit() {
    final label = _controller.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    Navigator.pop(
      context,
      MarkerDialogResult(label, _category, latitude: _isEntrance ? _lat : null, longitude: _isEntrance ? _lng : null),
    );
  }

  Widget _buildGpsSection() {
    const muted = TextStyle(fontSize: 12, color: Color(0xFF71717A));
    final String status;
    if (_gpsLoading) {
      status = 'Getting GPS position...';
    } else if (_lat == null) {
      status = 'No GPS position yet.';
    } else {
      final accuracy = _gpsAccuracy == null ? 'placed on map' : '±${_gpsAccuracy!.toStringAsFixed(0)} m';
      status = '${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)} ($accuracy)';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Entrances link this building to the street map and to other buildings.', style: muted),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(_lat == null ? Icons.location_off_outlined : Icons.location_on_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(status, style: const TextStyle(fontSize: 12))),
            ],
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: _gpsLoading ? null : _captureGps,
                icon: const Icon(Icons.gps_fixed, size: 16),
                label: const Text('Use current GPS'),
              ),
              TextButton.icon(
                onPressed: _adjustOnMap,
                icon: const Icon(Icons.map_outlined, size: 16),
                label: const Text('Adjust on map'),
              ),
            ],
          ),
          if (_gpsAccuracy != null && _gpsAccuracy! > 10)
            const Text('GPS is rough near buildings. Check the spot with "Adjust on map".', style: muted),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.knownConnectors.where((w) => w.category == _category).toList();
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add Marker' : 'Edit Marker'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (value, label, icon) in const [
                  ('room', 'Place', CupertinoIcons.placemark),
                  (Waypoint.stairsCategory, 'Stairs', Icons.stairs_outlined),
                  (Waypoint.liftCategory, 'Lift', Icons.elevator_outlined),
                  (Waypoint.entranceCategory, 'Entrance', Icons.door_front_door_outlined),
                ])
                  ChoiceChip(
                    avatar: Icon(icon, size: 18),
                    label: Text(label),
                    selected: _category == value,
                    showCheckmark: false,
                    onSelected: (_) => _setCategory(value),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: _isEntrance
                    ? 'e.g., Main Entrance'
                    : _isConnector
                        ? 'e.g., ${_category == Waypoint.liftCategory ? "Lift A" : "Main Stairs"}'
                        : 'e.g., Room 101',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_isEntrance) _buildGpsSection(),
            if (_isConnector) ...[
              const SizedBox(height: 8),
              const Text(
                'Use the same name on every floor it reaches. That is how floors get linked.',
                style: TextStyle(fontSize: 12, color: Color(0xFF71717A)),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Marked on other floors:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final w in suggestions)
                      ActionChip(
                        label: Text(w.label),
                        onPressed: () => setState(() {
                          _controller.text = w.label;
                          _error = null;
                        }),
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              MarkerDialogResult(widget.initial!.label, widget.initial!.category, delete: true),
            ),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
