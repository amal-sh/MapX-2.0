import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/map_models.dart';

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
  const MarkerDialogResult(this.label, this.category, {this.delete = false});
}

/// Asks what is at a spot: a place, or stairs/lift leading to other floors.
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
      widget.initial?.isConnector == true ? widget.initial!.category : 'room';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isConnector => _category != 'room';

  void _submit() {
    final label = _controller.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    Navigator.pop(context, MarkerDialogResult(label, _category));
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
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'room', label: Text('Place'), icon: Icon(CupertinoIcons.placemark)),
                ButtonSegment(value: Waypoint.stairsCategory, label: Text('Stairs'), icon: Icon(Icons.stairs_outlined)),
                ButtonSegment(value: Waypoint.liftCategory, label: Text('Lift'), icon: Icon(Icons.elevator_outlined)),
              ],
              selected: {_category},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _category = s.first),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: _isConnector ? 'e.g., ${_category == Waypoint.liftCategory ? "Lift A" : "Main Stairs"}' : 'e.g., Room 101, Exit',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
            ),
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
