import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/navigation_trip.dart';
import '../services/navigation_history_service.dart';
import 'map_viewer_screen.dart';

/// Offline list of completed navigations, newest first.
class RecentTripsScreen extends StatefulWidget {
  const RecentTripsScreen({super.key});

  @override
  State<RecentTripsScreen> createState() => _RecentTripsScreenState();
}

class _RecentTripsScreenState extends State<RecentTripsScreen> {
  final _service = NavigationHistoryService.instance;
  List<NavigationTrip> _trips = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final trips = await _service.load();
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _loading = false;
    });
  }

  String _timeAgo(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${at.month}/${at.day}/${at.year}';
  }

  Future<String?> _resolveMapKey(NavigationTrip trip) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (trip.toFloor != null) {
        final key = 'map_${trip.toBuilding}#${trip.toFloor}';
        if (prefs.containsKey(key)) return key;
      }
      final prefix = 'map_${trip.toBuilding}#';
      final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList()
        ..sort();
      if (keys.isNotEmpty) return keys.first;
      if (trip.fromFloor != null) {
        final key = 'map_${trip.fromBuilding}#${trip.fromFloor}';
        if (prefs.containsKey(key)) return key;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _navigateAgain(NavigationTrip trip) async {
    final mapKey = await _resolveMapKey(trip);
    if (!mounted) return;
    if (mapKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No offline map for ${trip.toBuilding} yet')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewerScreen(
          mapKey: mapKey,
          mapName: trip.toBuilding,
          targetDestinationName: trip.toLabel,
          targetFloor: trip.toFloor,
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear recent trips?'),
        content: const Text(
            'This removes the offline navigation history on this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _service.clear();
      await _reload();
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
        title: Text('Recent Trips', style: textTheme.titleLarge),
        actions: [
          if (!_loading && _trips.isNotEmpty)
            TextButton(
              onPressed: _confirmClear,
              child: const Text('Clear',
                  style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : _trips.isEmpty
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
                          child: const Icon(CupertinoIcons.compass,
                              size: 36, color: Color(0xFF71717A)),
                        ),
                        const SizedBox(height: 16),
                        Text('No trips yet',
                            style: textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          'Completed navigations appear here. '
                          'History stays on this device.',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _trips.length,
                  separatorBuilder: (_, _) => const Divider(
                      height: 1, color: Color(0xFFF4F4F5)),
                  itemBuilder: (context, index) {
                    final trip = _trips[index];
                    return Dismissible(
                      key: ValueKey(trip.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.black,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(CupertinoIcons.trash,
                            color: Colors.white, size: 20),
                      ),
                      onDismissed: (_) async {
                        await _service.delete(trip.id);
                        await _reload();
                      },
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
                          child: const Icon(CupertinoIcons.compass,
                              size: 19, color: Colors.black),
                        ),
                        title: Text(trip.title,
                            style: textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${trip.routeSummary} · ${_timeAgo(trip.completedAt)}',
                          style: textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(CupertinoIcons.chevron_right,
                            size: 14, color: Color(0xFFA1A1AA)),
                        onTap: () => _navigateAgain(trip),
                      ),
                    );
                  },
                ),
    );
  }
}
