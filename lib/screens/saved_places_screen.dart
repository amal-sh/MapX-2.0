import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_place.dart';
import '../services/saved_places_service.dart';
import 'outdoor_map_screen.dart';
import 'map_viewer_screen.dart';

/// Offline list of user-saved buildings, floors/blocks and rooms/places.
class SavedPlacesScreen extends StatefulWidget {
  const SavedPlacesScreen({super.key});

  @override
  State<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

class _SavedPlacesScreenState extends State<SavedPlacesScreen> {
  final _service = SavedPlacesService.instance;
  List<SavedPlace> _places = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final places = await _service.load();
    if (!mounted) return;
    setState(() {
      _places = places;
      _loading = false;
    });
  }

  Future<String?> _resolveMapKey(SavedPlace place) async {
    if (place.mapKey != null && place.mapKey!.isNotEmpty) return place.mapKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (place.floor != null) {
        final key = 'map_${place.building}#${place.floor}';
        if (prefs.containsKey(key)) return key;
      }
      final prefix = 'map_${place.building}#';
      final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList()
        ..sort();
      return keys.isEmpty ? null : keys.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _open(SavedPlace place) async {
    if (place.kind == SavedPlaceKind.building && place.floor == null) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const OutdoorMapScreen()),
      );
      return;
    }
    final mapKey = await _resolveMapKey(place);
    if (!mounted) return;
    if (mapKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No offline map for ${place.building} yet')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewerScreen(
          mapKey: mapKey,
          mapName: place.building,
          targetDestinationName:
              place.kind == SavedPlaceKind.place ? place.label : null,
          targetFloor: place.floor,
        ),
      ),
    );
  }

  Future<void> _remove(SavedPlace place) async {
    await _service.remove(place.id);
    await _reload();
  }

  IconData _iconFor(SavedPlace place) {
    switch (place.kind) {
      case SavedPlaceKind.building:
        return CupertinoIcons.building_2_fill;
      case SavedPlaceKind.floor:
        return CupertinoIcons.square_stack_3d_up;
      case SavedPlaceKind.place:
        return CupertinoIcons.placemark;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Saved Places', style: textTheme.titleLarge),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _places.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: const BoxDecoration(
                            color: Color(0xFFF4F4F5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(CupertinoIcons.bookmark,
                              size: 36, color: Color(0xFF71717A)),
                        ),
                        const SizedBox(height: 16),
                        Text('No saved places yet',
                            style: textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          'Save a building, floor or room from search, '
                          'the dashboard or the campus map. '
                          'Saves stay on this device.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _places.length,
                  separatorBuilder: (_, _) => const Divider(
                      height: 1, color: Color(0xFFF4F4F5)),
                  itemBuilder: (context, index) {
                    final place = _places[index];
                    return Dismissible(
                      key: ValueKey(place.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.black,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(CupertinoIcons.trash,
                            color: Colors.white, size: 20),
                      ),
                      onDismissed: (_) => _remove(place),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(_iconFor(place),
                              size: 19, color: Colors.black),
                        ),
                        title: Text(place.label,
                            style: textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(place.subtitle,
                            style: textTheme.bodySmall),
                        trailing: const Icon(CupertinoIcons.chevron_right,
                            size: 14, color: Color(0xFFA1A1AA)),
                        onTap: () => _open(place),
                      ),
                    );
                  },
                ),
    );
  }
}
