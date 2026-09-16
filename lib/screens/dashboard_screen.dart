import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mapping_screen.dart';
import 'map_viewer_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<String> _mapKeys = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _mapKeys = prefs.getKeys().where((k) => k.startsWith('map_')).toList();
      _isLoading = false;
    });
  }

  Future<void> _deleteMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
    _loadKeys();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MapX Dashboard'),
        centerTitle: true,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _mapKeys.isEmpty
              ? _buildEmptyState()
              : _buildMapList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const MappingScreen()),
          );
          if (result == true) {
            _loadKeys();
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('New Map'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map_outlined, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'No maps found.',
            style: TextStyle(fontSize: 20, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap "New Map" to start exploring!',
            style: TextStyle(color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildMapList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _mapKeys.length,
      itemBuilder: (context, index) {
        final key = _mapKeys[index];
        final name = key.substring(4);
        
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: const CircleAvatar(
              backgroundColor: Colors.teal,
              child: Icon(Icons.map, color: Colors.white),
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            subtitle: const Text('Tap to view map'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete Map?'),
                    content: Text('Are you sure you want to delete "$name"?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _deleteMap(key);
                        },
                        child: const Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
              },
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => MapViewerScreen(mapKey: key, mapName: name)),
              );
            },
          ),
        );
      },
    );
  }
}
