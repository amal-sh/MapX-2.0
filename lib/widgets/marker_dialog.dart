import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_models.dart';
import '../screens/location_picker_screen.dart';
import '../services/location_service.dart';

/// Stairs/lifts already marked on [building]'s other floors, one per name,
/// offered in [MarkerDialog] so a connector gets the same name on every floor.
Future<List<Waypoint>> loadConnectorsOnOtherFloors(
    String building, int floor) async {
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

  const MarkerDialogResult(
    this.label,
    this.category, {
    this.delete = false,
    this.latitude,
    this.longitude,
  });

  /// The marked place at node [index] on [floor].
  Waypoint toWaypoint(int index, int floor) => Waypoint(
        index,
        label,
        floor: floor,
        category: category,
        latitude: latitude,
        longitude: longitude,
      );
}

/// Asks what is at a spot: a place, stairs/lift leading to other floors, or
/// an entrance to the outside (which records its GPS position).
/// Pass [initial] to edit an existing marker, which also offers Delete.
/// Returns null when cancelled.
///
/// Refactored to follow MapX monochrome minimal design tokens.
class MarkerDialog extends StatefulWidget {
  final List<Waypoint> knownConnectors;
  final Waypoint? initial;

  const MarkerDialog({
    super.key,
    required this.knownConnectors,
    this.initial,
  });

  @override
  State<MarkerDialog> createState() => _MarkerDialogState();
}

class _MarkerDialogState extends State<MarkerDialog> {
  late final _controller = TextEditingController(text: widget.initial?.label);
  late String _category = widget.initial?.isConnector == true ||
          widget.initial?.isEntrance == true
      ? widget.initial!.category
      : 'room';
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

  bool get _isConnector =>
      _category == Waypoint.stairsCategory || _category == Waypoint.liftCategory;
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
      MarkerDialogResult(
        label,
        _category,
        latitude: _isEntrance ? _lat : null,
        longitude: _isEntrance ? _lng : null,
      ),
    );
  }

  IconData _getCategoryIcon(String cat) {
    switch (cat) {
      case Waypoint.stairsCategory:
        return Icons.stairs_outlined;
      case Waypoint.liftCategory:
        return Icons.elevator_outlined;
      case Waypoint.entranceCategory:
        return Icons.door_front_door_outlined;
      default:
        return CupertinoIcons.placemark;
    }
  }

  Widget _buildGpsSection() {
    final String status;
    if (_gpsLoading) {
      status = 'Acquiring GPS coordinates...';
    } else if (_lat == null) {
      status = 'No GPS position attached yet.';
    } else {
      final accuracy = _gpsAccuracy == null
          ? 'placed manually'
          : '±${_gpsAccuracy!.toStringAsFixed(0)} m';
      status =
          '${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)} ($accuracy)';
    }

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE4E4E7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _lat == null
                    ? CupertinoIcons.location_slash
                    : CupertinoIcons.location_solid,
                size: 16,
                color: _lat == null
                    ? const Color(0xFF71717A)
                    : const Color(0xFF18181B),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF18181B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Entrances link this building to the outdoor street map and nearby buildings.',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF71717A),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _gpsLoading ? null : _captureGps,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF18181B),
                    side: const BorderSide(color: Color(0xFFE4E4E7)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(CupertinoIcons.location_fill, size: 14),
                  label: Text(
                    'Use current GPS',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _adjustOnMap,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF18181B),
                    side: const BorderSide(color: Color(0xFFE4E4E7)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(CupertinoIcons.map, size: 14),
                  label: Text(
                    'Adjust on map',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_gpsAccuracy != null && _gpsAccuracy! > 10) ...[
            const SizedBox(height: 8),
            Text(
              'GPS is rough near buildings. Check the spot with "Adjust on map".',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF71717A),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.knownConnectors
        .where((w) => w.category == _category)
        .toList();
    final isEditing = widget.initial != null;
    final titleText = isEditing ? 'Edit Marker' : 'Add Marker';

    const categories = [
      ('room', 'Place', CupertinoIcons.placemark),
      (Waypoint.stairsCategory, 'Stairs', Icons.stairs_outlined),
      (Waypoint.liftCategory, 'Lift', Icons.elevator_outlined),
      (Waypoint.entranceCategory, 'Entrance', Icons.door_front_door_outlined),
    ];

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE4E4E7), width: 1),
      ),
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F4F5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE4E4E7)),
                    ),
                    child: Icon(
                      _getCategoryIcon(_category),
                      size: 20,
                      color: const Color(0xFF18181B),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titleText,
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          isEditing
                              ? 'Modify waypoint details, floor connector or GPS anchor.'
                              : 'Label this spot or set it as a multi-floor / entrance link.',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: const Color(0xFF71717A),
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Category Selector
              Text(
                'MARKER TYPE',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: const Color(0xFF71717A),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: categories.map((cat) {
                  final isSelected = _category == cat.$1;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _setCategory(cat.$1),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.black
                                : const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.black
                                  : const Color(0xFFE4E4E7),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                cat.$3,
                                size: 18,
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFF27272A),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                cat.$2,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF27272A),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),

              // Marker Name Input
              Text(
                'NAME',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: const Color(0xFF71717A),
                ),
              ),
              const SizedBox(height: 7),
              TextField(
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => _submit(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF18181B),
                ),
                decoration: InputDecoration(
                  hintText: _isEntrance
                      ? 'e.g., Main Entrance'
                      : _isConnector
                          ? 'e.g., ${_category == Waypoint.liftCategory ? "Lift A" : "Main Stairs"}'
                          : 'e.g., Room 101 or Lab 4',
                  prefixIcon: const Icon(
                    CupertinoIcons.tag,
                    size: 18,
                    color: Color(0xFF71717A),
                  ),
                  errorText: _error,
                ),
              ),

              // GPS section
              if (_isEntrance) _buildGpsSection(),

              // Connector info & suggestions
              if (_isConnector) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE4E4E7)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        CupertinoIcons.info_circle,
                        size: 16,
                        color: Color(0xFF71717A),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Use the exact same name on every floor it reaches. That is how multi-floor routes are linked.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: const Color(0xFF52525B),
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Marked on other floors:',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF18181B),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: suggestions.map((w) {
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          setState(() {
                            _controller.text = w.label;
                            _error = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE4E4E7)),
                          ),
                          child: Text(
                            w.label,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF27272A),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
              const SizedBox(height: 24),

              // Action Buttons
              Row(
                children: [
                  if (isEditing) ...[
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDC2626),
                        side: const BorderSide(color: Color(0xFFFECACA)),
                        backgroundColor: const Color(0xFFFEF2F2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () => Navigator.pop(
                        context,
                        MarkerDialogResult(
                          widget.initial!.label,
                          widget.initial!.category,
                          delete: true,
                        ),
                      ),
                      child: Text(
                        'Delete',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFDC2626),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF52525B),
                        side: const BorderSide(color: Color(0xFFE4E4E7)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _submit,
                      child: Text(
                        'Save',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
