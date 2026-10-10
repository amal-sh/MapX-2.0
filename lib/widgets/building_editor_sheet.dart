import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../providers/dashboard_providers.dart';
import '../screens/pick_location_screen.dart';
import '../services/location_service.dart';

Future<void> showEditBuildingSheet(BuildContext context, String building) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _EditBuildingSheet(building: building),
    ),
  );
}

Future<void> showFloorSettingsSheet(
    BuildContext context, BuildingMapEntry entry) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _FloorSettingsSheet(mapKey: entry.key),
    ),
  );
}

Widget _sheetHandle() {
  return Container(
    margin: const EdgeInsets.only(top: 10, bottom: 6),
    width: 36,
    height: 4,
    decoration: BoxDecoration(
      color: const Color(0xFFE4E4E7),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

Widget _sectionHeader(String text) {
  return Text(
    text,
    style: GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF71717A),
      letterSpacing: 0.8,
    ),
  );
}

InputDecoration _fieldDecoration(String label, String hint, String? error) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: error,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFE4E4E7)),
    ),
  );
}

/// Edit everything about a building: name, GPS location, floors overview,
/// and deletion. All saves apply immediately (optimistic provider updates).
class _EditBuildingSheet extends ConsumerStatefulWidget {
  final String building;
  const _EditBuildingSheet({required this.building});

  @override
  ConsumerState<_EditBuildingSheet> createState() => _EditBuildingSheetState();
}

class _EditBuildingSheetState extends ConsumerState<_EditBuildingSheet> {
  late final TextEditingController _nameController;
  final _latController = TextEditingController();
  final _lngController = TextEditingController();
  String? _nameError;
  String? _coordError;
  bool _locating = false;
  bool _renaming = false;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.building);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final next = _nameController.text.trim();
    final notifier = ref.read(dashboardProvider.notifier);
    String? err;
    if (next.isEmpty) {
      err = 'Enter a building name';
    } else if (next == widget.building) {
      err = 'Name is unchanged';
    } else if (notifier.buildingExists(next)) {
      err = 'A building named "$next" already exists';
    }
    if (err != null) {
      setState(() => _nameError = err);
      return;
    }
    setState(() {
      _nameError = null;
      _renaming = true;
    });
    final ok = await notifier.renameBuilding(widget.building, next);
    if (!mounted) return;
    setState(() => _renaming = false);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Renamed "${widget.building}" to "$next".'
            : 'Could not rename "${widget.building}".'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveLocation(BuildingLocation loc) async {
    await ref
        .read(dashboardProvider.notifier)
        .updateBuildingLocation(widget.building, loc);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Building location updated.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    final loc = await LocationService.instance.getCurrentLocation();
    if (!mounted) return;
    setState(() => _locating = false);
    if (loc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not get a GPS fix. Try again outside.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await _saveLocation(loc);
  }

  /// Opens the OSM pin picker centered on the current fix (or GPS/default),
  /// then saves whatever the admin confirms.
  Future<void> _pickOnMap() async {
    final state = ref.read(dashboardProvider);
    final current = state.buildingLocations[widget.building];
    LatLng initial;
    if (current != null) {
      initial = LatLng(current.latitude, current.longitude);
    } else {
      final gps = await LocationService.instance.getCurrentLocation();
      if (gps != null) {
        initial = LatLng(gps.latitude, gps.longitude);
      } else {
        initial = const LatLng(20, 78);
      }
    }
    if (!mounted) return;
    setState(() => _picking = true);
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => PickLocationScreen(initial: initial)),
    );
    if (!mounted) return;
    setState(() => _picking = false);
    if (picked == null) return;
    await _saveLocation(BuildingLocation(
      latitude: picked.latitude,
      longitude: picked.longitude,
      accuracy: 0,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> _applyManualCoords() async {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    String? err;
    if (lat == null || lng == null) {
      err = 'Enter both latitude and longitude as numbers';
    } else if (lat < -90 || lat > 90) {
      err = 'Latitude must be between -90 and 90';
    } else if (lng < -180 || lng > 180) {
      err = 'Longitude must be between -180 and 180';
    }
    if (err != null) {
      setState(() => _coordError = err);
      return;
    }
    setState(() => _coordError = null);
    await _saveLocation(
      BuildingLocation(
        latitude: lat!,
        longitude: lng!,
        accuracy: 0,
        timestamp: DateTime.now(),
      ),
    );
    if (!mounted) return;
    _latController.clear();
    _lngController.clear();
  }

  Future<void> _confirmDelete() async {
    final outerContext = context;
    final floors =
        ref.read(dashboardProvider).groupedByBuilding[widget.building] ?? const [];
    final confirmed = await showDialog<bool>(
      context: outerContext,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete Building?',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text(
          floors.isEmpty
              ? 'Delete "${widget.building}"? It has no recorded floors.'
              : 'Delete "${widget.building}" and all ${floors.length} recorded floor${floors.length == 1 ? '' : 's'}? This cannot be undone.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(color: const Color(0xFF71717A))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete',
                style: GoogleFonts.inter(
                    color: const Color(0xFFDC2626),
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(dashboardProvider.notifier).deleteBuilding(widget.building);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted "${widget.building}".'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardProvider);
    final location = state.buildingLocations[widget.building];
    final placeName = state.buildingPlaceNames[widget.building]?.trim();
    final floors = state.groupedByBuilding[widget.building] ?? const [];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: _sheetHandle()),
            Text(
              'Edit Building',
              style: GoogleFonts.inter(
                  fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _sectionHeader('NAME'),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _rename(),
                    decoration: _fieldDecoration(
                        'Building name', 'e.g., Science Complex', _nameError),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onPressed: _renaming ? null : _rename,
                  child: _renaming
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text('Apply',
                          style:
                              GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _sectionHeader('LOCATION'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
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
                      const Icon(CupertinoIcons.location_solid,
                          size: 18, color: Color(0xFF27272A)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          location != null
                              ? '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}'
                              : 'No GPS fix yet — navigation to this building needs one.',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: const Color(0xFF27272A)),
                        ),
                      ),
                    ],
                  ),
                  if (location != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(CupertinoIcons.map_pin,
                            size: 14, color: Color(0xFF71717A)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            (placeName != null && placeName.isNotEmpty)
                                ? placeName
                                : 'Resolving place name…',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF71717A),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF18181B),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _locating ? null : _useCurrentLocation,
                icon: _locating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(CupertinoIcons.location, size: 18),
                label: Text(
                    _locating ? 'Locating…' : 'Use current location',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF18181B),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _picking ? null : _pickOnMap,
                icon: _picking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(CupertinoIcons.map_pin_ellipse, size: 18),
                label: Text(
                    _picking ? 'Opening map…' : 'Pin on map',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _latController,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    decoration:
                        _fieldDecoration('Latitude', 'e.g., 37.7749', null),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lngController,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    decoration:
                        _fieldDecoration('Longitude', 'e.g., -122.4194', null),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onPressed: _applyManualCoords,
                  child: Text('Set',
                      style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            if (_coordError != null) ...[
              const SizedBox(height: 6),
              Text(_coordError!,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            _sectionHeader('FLOORS · ${floors.length}'),
            const SizedBox(height: 8),
            Text(
              'Tap a floor in the list to rename its label, change its floor number, or delete it.',
              style: GoogleFonts.inter(
                  fontSize: 13, color: const Color(0xFF71717A)),
            ),
            const SizedBox(height: 20),
            _sectionHeader('DANGER ZONE'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _confirmDelete,
                icon: const Icon(CupertinoIcons.trash, size: 18),
                label: Text('Delete building',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-floor settings: custom label, floor number, live stats, deletion.
class _FloorSettingsSheet extends ConsumerStatefulWidget {
  final String mapKey;
  const _FloorSettingsSheet({required this.mapKey});

  @override
  ConsumerState<_FloorSettingsSheet> createState() =>
      _FloorSettingsSheetState();
}

class _FloorSettingsSheetState extends ConsumerState<_FloorSettingsSheet> {
  late final TextEditingController _labelController;
  final _numberController = TextEditingController();
  String? _labelError;
  String? _numberError;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController();
  }

  @override
  void dispose() {
    _labelController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  BuildingMapEntry? _entry(DashboardState state) {
    for (final e in state.entries) {
      if (e.key == widget.mapKey) return e;
    }
    return null;
  }

  Future<void> _applyLabel(BuildingMapEntry entry) async {
    if (entry.floor == null) return;
    setState(() {
      _labelError = null;
      _working = true;
    });
    final ok = await ref.read(dashboardProvider.notifier).setFloorLabel(
          building: entry.name,
          floor: entry.floor!,
          label: _labelController.text,
        );
    if (!mounted) return;
    setState(() => _working = false);
    if (!ok) {
      setState(() => _labelError = 'Could not save the label.');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_labelController.text.trim().isEmpty
            ? 'Label cleared.'
            : 'Floor label saved.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _applyNumber(BuildingMapEntry entry) async {
    if (entry.floor == null) return;
    final next = int.tryParse(_numberController.text.trim());
    final notifier = ref.read(dashboardProvider.notifier);
    String? err;
    if (next == null) {
      err = 'Enter a floor number';
    } else if (next == entry.floor) {
      err = 'Number is unchanged';
    } else if (notifier.exists(entry.name, next)) {
      err = 'Floor $next already exists in "${entry.name}"';
    }
    if (err != null) {
      setState(() => _numberError = err);
      return;
    }
    setState(() {
      _numberError = null;
      _working = true;
    });
    final ok = await notifier.renumberFloor(
      building: entry.name,
      oldFloor: entry.floor!,
      newFloor: next!,
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (!ok) {
      setState(() => _numberError = 'Could not change the floor number.');
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Floor moved to $next.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmDelete(BuildingMapEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete Floor Map?',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text(
          'Delete "${entry.title}"? This removes its recorded trajectory, anchors, and places.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(color: const Color(0xFF71717A))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete',
                style: GoogleFonts.inter(
                    color: const Color(0xFFDC2626),
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(dashboardProvider.notifier).deleteMap(entry.key);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dashboardProvider);
    final entry = _entry(state);
    if (entry == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(child: _sheetHandle()),
              const SizedBox(height: 12),
              Text('This floor no longer exists.',
                  style: GoogleFonts.inter(fontSize: 14)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    }
    final stats = state.floorStats[entry.key] ?? const FloorMapStats();
    if (_labelController.text.isEmpty && (entry.label ?? '').isNotEmpty) {
      _labelController.text = entry.label!;
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: _sheetHandle()),
            Text(
              entry.displayTitle,
              style: GoogleFonts.inter(
                  fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '${entry.name} · Floor ${entry.floor ?? '?'}',
              style: GoogleFonts.inter(
                  fontSize: 12, color: const Color(0xFF71717A)),
            ),
            const SizedBox(height: 16),
            _sectionHeader('LABEL'),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _labelController,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _applyLabel(entry),
                    decoration: _fieldDecoration('Custom label',
                        'e.g., Lobby Level', _labelError),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onPressed: _working ? null : () => _applyLabel(entry),
                  child: Text('Apply',
                      style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _sectionHeader('FLOOR NUMBER'),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _numberController,
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _applyNumber(entry),
                    decoration: _fieldDecoration('Floor number',
                        'Current: ${entry.floor ?? '?'}', _numberError),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  onPressed: _working ? null : () => _applyNumber(entry),
                  child: Text('Move',
                      style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Moving renumbers the map, its places, and any connector links.',
              style: GoogleFonts.inter(
                  fontSize: 12, color: const Color(0xFF71717A)),
            ),
            const SizedBox(height: 16),
            _sectionHeader('RECORDED DATA'),
            const SizedBox(height: 8),
            _statRow('Nodes', '${stats.nodeCount}'),
            _statRow('Places', '${stats.placeCount}'),
            _statRow('Lifts', '${stats.liftCount}'),
            _statRow('Staircases', '${stats.stairsCount}'),
            _statRow('Entrances', '${stats.entranceCount}'),
            _statRow('Steps walked', '${stats.stepCount}'),
            _statRow('Distance',
                stats.distanceLabel.isEmpty ? '—' : stats.distanceLabel),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => _confirmDelete(entry),
                icon: const Icon(CupertinoIcons.trash, size: 18),
                label: Text('Delete floor',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 13, color: const Color(0xFF71717A))),
          Text(value,
              style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
