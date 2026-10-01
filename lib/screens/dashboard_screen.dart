import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/firestore_service.dart';
import '../services/location_service.dart';
import 'mapping_screen.dart';
import 'map_viewer_screen.dart';

/// One saved floor map. A "building" is just every entry sharing a name.
class _MapEntry {
  final String key;
  final String name;
  // Null for maps saved before floors were asked for.
  final int? floor;
  const _MapEntry({required this.key, required this.name, required this.floor});

  String get title => floor == null ? name : '$name · Floor $floor';
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _methodChannel = MethodChannel('mapx/arcore');

  List<_MapEntry> _entries = [];
  Map<String, BuildingLocation> _buildingLocations = {};
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isDeviceSupported = true;

  @override
  void initState() {
    super.initState();
    _loadMaps();
    _checkArCoreSupport();
  }

  Future<void> _checkArCoreSupport() async {
    try {
      final availability =
          await _methodChannel.invokeMethod<String>('checkAvailability');
      // ARCore is only operational and supported if availability is SUPPORTED_INSTALLED.
      // Emulators or devices without ARCore installed (SUPPORTED_NOT_INSTALLED,
      // UNSUPPORTED_DEVICE_NOT_CAPABLE, or errors) are not supported to run MapX AR.
      if (availability != 'SUPPORTED_INSTALLED') {
        if (!mounted) return;
        setState(() => _isDeviceSupported = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showUnsupportedDeviceDialog();
          }
        });
      }
    } on MissingPluginException {
      // In testing environments or platforms without the plugin registered,
      // do not block unless mocked.
    } on PlatformException {
      if (!mounted) return;
      setState(() => _isDeviceSupported = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUnsupportedDeviceDialog();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDeviceSupported = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUnsupportedDeviceDialog();
        }
      });
    }
  }

  void _showUnsupportedDeviceDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(CupertinoIcons.exclamationmark_triangle_fill,
                  color: Color(0xFFDC2626), size: 24),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Device Not Supported',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'This device isn\'t supported. MapX requires ARCore support to function properly.',
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFF52525B),
              height: 1.4,
            ),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => SystemNavigator.pop(),
              child: const Text('Exit App', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadMaps({bool syncCloud = false}) async {
    if (syncCloud) {
      setState(() => _isSyncing = true);
      try {
        final count = await FirestoreService.instance.syncFromFirestore();
        if (mounted && count > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Synced $count map(s) from Firestore!')),
          );
        }
      } catch (_) {}
      if (mounted) setState(() => _isSyncing = false);
    }

    final prefs = await SharedPreferences.getInstance();
    final entries = <_MapEntry>[];
    final locations = <String, BuildingLocation>{};

    for (final key in prefs.getKeys().where((k) => k.startsWith('map_'))) {
      final data = jsonDecode(prefs.getString(key) ?? '{}') as Map;
      final name = data['name'] as String? ?? key.substring(4);
      final floor = data['floor'] as int?;

      entries.add(_MapEntry(
        key: key,
        name: name,
        floor: floor,
      ));

      if (data['latitude'] != null && data['longitude'] != null && !locations.containsKey(name)) {
        locations[name] = BuildingLocation(
          latitude: (data['latitude'] as num).toDouble(),
          longitude: (data['longitude'] as num).toDouble(),
          accuracy: (data['accuracy'] ?? data['gpsAccuracy'] as num?)?.toDouble() ?? 0.0,
          timestamp: DateTime.tryParse(data['timestamp'] as String? ?? '') ?? DateTime.now(),
        );
      }
    }

    // Also check building_gps_ cache
    for (final key in prefs.getKeys().where((k) => k.startsWith('building_gps_'))) {
      final bName = key.substring('building_gps_'.length);
      if (!locations.containsKey(bName)) {
        try {
          final locData = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
          locations[bName] = BuildingLocation.fromJson(locData);
        } catch (_) {}
      }
    }

    setState(() {
      _entries = entries;
      _buildingLocations = locations;
      _isLoading = false;
    });
  }

  Future<void> _deleteMap(String key) async {
    final entry = _entries.cast<_MapEntry?>().firstWhere((e) => e?.key == key, orElse: () => null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);

    if (entry != null) {
      unawaited(FirestoreService.instance.deleteMap(
        mapKey: key,
        buildingName: entry.name,
        floor: entry.floor ?? 0,
      ));
    }
    _loadMaps();
  }

  bool _exists(String name, int floor) =>
      _entries.any((e) => e.name == name && e.floor == floor);

  Future<void> _startNewMap() async {
    if (!_isDeviceSupported) {
      _showUnsupportedDeviceDialog();
      return;
    }
    final details = await showDialog<({String name, int floor})>(
      context: context,
      builder: (_) => _NewMapDialog(exists: _exists),
    );
    if (details == null || !mounted) return;

    // Show immediate feedback while acquiring GPS
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Acquiring building GPS coordinates...'),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );

    final location = await LocationService.instance.getCurrentLocation();
    if (location != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('building_gps_${details.name}', jsonEncode(location.toJson()));

      unawaited(FirestoreService.instance.saveBuilding(
        buildingName: details.name,
        location: location,
        initialFloor: details.floor,
      ));
    }

    await _openMapping(details, location: location);
  }

  Future<void> _addFloor(String building) async {
    if (!_isDeviceSupported) {
      _showUnsupportedDeviceDialog();
      return;
    }
    final details = await showDialog<({String name, int floor})>(
      context: context,
      builder: (_) => _AddFloorDialog(building: building, exists: _exists),
    );
    if (details == null || !mounted) return;

    BuildingLocation? location = _buildingLocations[building];
    location ??= await LocationService.instance.getCurrentLocation();

    await _openMapping(details, location: location);
  }

  Future<void> _openMapping(({String name, int floor})? details, {BuildingLocation? location}) async {
    if (details == null || !mounted) return;

    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MappingScreen(
          mapName: details.name,
          floor: details.floor,
          location: location,
        ),
      ),
    );
    if (saved == true) {
      _loadMaps();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Image.asset(
          'assets/images/transp_banner.png',
          height: 52,
          fit: BoxFit.contain,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(CupertinoIcons.cloud_download, color: Colors.black),
            tooltip: 'Sync from Firestore',
            onPressed: _isSyncing ? null : () => _loadMaps(syncCloud: true),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _entries.isEmpty
              ? _buildEmptyState()
              : _buildMapList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewMap,
        icon: const Icon(CupertinoIcons.add),
        label: const Text('New Map'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F5),
              shape: BoxShape.circle,
            ),
            child: const Icon(CupertinoIcons.map, size: 64, color: Color(0xFF71717A)),
          ),
          const SizedBox(height: 20),
          const Text(
            'No maps found',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.black),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap "New Map" to start mapping your space.',
            style: TextStyle(color: Color(0xFF71717A), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildMapList() {
    final byBuilding = <String, List<_MapEntry>>{};
    for (final e in _entries) {
      byBuilding.putIfAbsent(e.name, () => []).add(e);
    }
    for (final floors in byBuilding.values) {
      // Ascending by floor; maps with no floor recorded go last.
      floors.sort((a, b) => (a.floor ?? 1 << 30).compareTo(b.floor ?? 1 << 30));
    }
    final buildings = byBuilding.entries.toList();

    return ListView.builder(
      // Bottom padding clears the floating New Map button.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      itemCount: buildings.length,
      itemBuilder: (context, index) =>
          _buildBuildingCard(buildings[index].key, buildings[index].value),
    );
  }

  Widget _buildBuildingCard(String name, List<_MapEntry> floors) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(CupertinoIcons.building_2_fill, color: Colors.white, size: 22),
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: Colors.black)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  floors.length == 1 ? '1 floor' : '${floors.length} floors',
                  style: const TextStyle(color: Color(0xFF71717A), fontSize: 13),
                ),
                if (_buildingLocations.containsKey(name))
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.location_solid, size: 12, color: Color(0xFF16A34A)),
                        const SizedBox(width: 4),
                        Text(
                          '${_buildingLocations[name]!.latitude.toStringAsFixed(5)}, ${_buildingLocations[name]!.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(
                            color: Color(0xFF52525B),
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final entry in floors)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 24, right: 12),
              leading: const Icon(CupertinoIcons.square_stack_3d_up, color: Color(0xFF18181B), size: 18),
              title: Text(
                entry.floor == null ? 'No floor set' : 'Floor ${entry.floor}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black),
              ),
              subtitle: const Text('Tap to open map', style: TextStyle(color: Color(0xFF71717A), fontSize: 12)),
              trailing: IconButton(
                icon: const Icon(CupertinoIcons.trash, color: Color(0xFF71717A), size: 18),
                onPressed: () => _confirmDelete(entry),
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MapViewerScreen(mapKey: entry.key, mapName: entry.title),
                  ),
                );
              },
            ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 24, right: 12),
            leading: const Icon(CupertinoIcons.plus_circle, color: Colors.black, size: 18),
            title: const Text(
              'Add Floor',
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            onTap: () => _addFloor(name),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(_MapEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Map?'),
        content: Text('Are you sure you want to delete "${entry.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMap(entry.key);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// Asks for the map's name and floor number before the mapping page opens.
class _NewMapDialog extends StatefulWidget {
  final bool Function(String name, int floor) exists;
  const _NewMapDialog({required this.exists});

  @override
  State<_NewMapDialog> createState() => _NewMapDialogState();
}

class _NewMapDialogState extends State<_NewMapDialog> {
  final _nameController = TextEditingController();
  final _floorController = TextEditingController();
  String? _nameError;
  String? _floorError;

  @override
  void dispose() {
    _nameController.dispose();
    _floorController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final floor = int.tryParse(_floorController.text.trim());
    setState(() {
      _nameError = name.isEmpty ? 'Enter a map name' : null;
      _floorError = floor == null
          ? 'Enter a floor number'
          : (name.isNotEmpty && widget.exists(name, floor))
              ? 'Floor $floor of "$name" already exists'
              : null;
    });
    if (_nameError == null && _floorError == null) {
      Navigator.pop(context, (name: name, floor: floor!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Map'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Map name',
              hintText: 'e.g., Home',
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _floorController,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Floor number',
              hintText: '0 = ground floor',
              errorText: _floorError,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Asks for a new floor number to add to [building].
class _AddFloorDialog extends StatefulWidget {
  final String building;
  final bool Function(String name, int floor) exists;
  const _AddFloorDialog({required this.building, required this.exists});

  @override
  State<_AddFloorDialog> createState() => _AddFloorDialogState();
}

class _AddFloorDialogState extends State<_AddFloorDialog> {
  final _floorController = TextEditingController();
  String? _floorError;

  @override
  void dispose() {
    _floorController.dispose();
    super.dispose();
  }

  void _submit() {
    final floor = int.tryParse(_floorController.text.trim());
    setState(() {
      _floorError = floor == null
          ? 'Enter a floor number'
          : widget.exists(widget.building, floor)
              ? 'Floor $floor already exists'
              : null;
    });
    if (_floorError == null) {
      Navigator.pop(context, (name: widget.building, floor: floor!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add floor to ${widget.building}'),
      content: TextField(
        controller: _floorController,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Floor number',
          hintText: 'e.g., 1',
          errorText: _floorError,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
