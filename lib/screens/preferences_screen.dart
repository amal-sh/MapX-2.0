import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/user_preferences_service.dart';

/// Device-only preferences: distance units and the default outdoor
/// basemap theme. Opened from the sidebar drawer.
class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  final _prefs = UserPreferencesService.instance;

  bool _loading = true;
  String _units = UserPreferencesService.unitsMeters;
  String _basemap = UserPreferencesService.basemapDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _prefs.loadDistanceUnits(),
      _prefs.loadBasemapTheme(),
    ]);
    if (!mounted) return;
    setState(() {
      _units = results[0];
      _basemap = results[1];
      _loading = false;
    });
  }

  Future<void> _setUnits(String units) async {
    setState(() => _units = units);
    await _prefs.saveDistanceUnits(units);
  }

  Future<void> _setBasemap(String basemap) async {
    setState(() => _basemap = basemap);
    await _prefs.saveBasemapTheme(basemap);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back,
              color: Colors.black, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text('Preferences', style: textTheme.titleLarge),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.black))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Stored on this device only.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'UNITS OF DISTANCE',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value:
                              UserPreferencesService.unitsMeters,
                          label: Text('Meters')),
                      ButtonSegment(
                          value: UserPreferencesService.unitsFeet,
                          label: Text('Feet')),
                    ],
                    selected: {_units},
                    showSelectedIcon: false,
                    onSelectionChanged: (selected) =>
                        _setUnits(selected.first),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'DEFAULT MAP THEME',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Used when the outdoor map opens.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  for (final option in const [
                    (
                      value: UserPreferencesService.basemapDark,
                      icon: CupertinoIcons.moon_fill,
                      title: 'Dark',
                      subtitle: 'Monochrome dark basemap',
                    ),
                    (
                      value: UserPreferencesService.basemapLight,
                      icon: CupertinoIcons.sun_max_fill,
                      title: 'Light',
                      subtitle: 'Monochrome light basemap',
                    ),
                    (
                      value: UserPreferencesService.basemapStandard,
                      icon: CupertinoIcons.globe,
                      title: 'Standard OSM',
                      subtitle: 'Full-color OpenStreetMap',
                    ),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _BasemapOptionCard(
                        icon: option.icon,
                        title: option.title,
                        subtitle: option.subtitle,
                        selected: _basemap == option.value,
                        onTap: () => _setBasemap(option.value),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _BasemapOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _BasemapOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF4F4F5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Colors.black
                : const Color(0xFFE4E4E7),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected ? Colors.black : const Color(0xFFF4F4F5),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle, style: textTheme.bodySmall),
                ],
              ),
            ),
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 22,
              color: selected
                  ? Colors.black
                  : const Color(0xFFA1A1AA),
            ),
          ],
        ),
      ),
    );
  }
}
