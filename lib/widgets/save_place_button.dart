import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/saved_place.dart';
import '../services/saved_places_service.dart';

/// Bookmark toggle backed by the offline [SavedPlacesService].
///
/// Shows a filled bookmark when [place] is saved, an outline otherwise.
/// Nothing leaves the device.
class SavePlaceButton extends StatefulWidget {
  final SavedPlace place;
  final double iconSize;

  const SavePlaceButton({super.key, required this.place, this.iconSize = 18});

  @override
  State<SavePlaceButton> createState() => _SavePlaceButtonState();
}

class _SavePlaceButtonState extends State<SavePlaceButton> {
  bool _saved = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(SavePlaceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.place.id != widget.place.id) _refresh();
  }

  Future<void> _refresh() async {
    final saved =
        await SavedPlacesService.instance.isSaved(widget.place.id);
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loaded = true;
    });
  }

  Future<void> _toggle() async {
    final nowSaved =
        await SavedPlacesService.instance.toggle(widget.place);
    if (!mounted) return;
    setState(() => _saved = nowSaved);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(nowSaved
              ? 'Saved ${widget.place.label} on this device'
              : 'Removed ${widget.place.label}'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: _saved ? 'Saved on this device' : 'Save on this device',
      icon: Icon(
        _saved ? CupertinoIcons.bookmark_fill : CupertinoIcons.bookmark,
        size: widget.iconSize,
        color: _loaded && _saved
            ? Colors.black
            : const Color(0xFF71717A),
      ),
      onPressed: _toggle,
    );
  }
}
