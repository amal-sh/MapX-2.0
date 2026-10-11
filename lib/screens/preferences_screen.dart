import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/service_providers.dart';
import '../services/user_preferences_service.dart';

/// Device-only preferences: default outdoor basemap theme, metric distance
/// units info, and local storage status. Opened from the sidebar drawer.
class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key});

  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  final _prefs = UserPreferencesService.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initPreferences();
  }

  Future<void> _initPreferences() async {
    // Standardize distance units to meters across the app
    await _prefs.saveDistanceUnits(UserPreferencesService.unitsMeters);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _setBasemap(String basemap) async {
    await ref.read(basemapPreferenceProvider.notifier).setBasemap(basemap);
    await _prefs.saveBasemapTheme(basemap);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final activeBasemap = ref.watch(basemapPreferenceProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.black, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text('Preferences', style: textTheme.titleLarge),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: const Color(0xFFE4E4E7),
            height: 1,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.black,
                strokeWidth: 2,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hero / Privacy Card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: const Color(0xFF18181B),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            CupertinoIcons.slider_horizontal_3,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Local Device Settings',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Preferences and cached geometries are stored locally on this phone and are never uploaded.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF71717A),
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF4F4F5),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFFE4E4E7),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      CupertinoIcons.lock_shield,
                                      size: 13,
                                      color: Color(0xFF52525B),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      'Offline & Private',
                                      style: textTheme.labelSmall?.copyWith(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF52525B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Section: Outdoor Basemap Theme
                  Row(
                    children: [
                      const Icon(
                        CupertinoIcons.map,
                        size: 16,
                        color: Color(0xFF18181B),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'DEFAULT MAP THEME',
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: const Color(0xFF52525B),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Visual layer style applied when launching outdoor campus navigation.',
                    style: textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF71717A),
                    ),
                  ),
                  const SizedBox(height: 12),

                  for (final option in const [
                    (
                      value: UserPreferencesService.basemapDark,
                      icon: CupertinoIcons.moon_fill,
                      title: 'Dark Blue',
                      subtitle:
                          'Deep dark blue & navy night tiles with reduced glare. Recommended for seamless outdoor & indoor navigation.',
                      previewColor: Color(0xFF0F172A),
                      badgeText: 'Recommended',
                    ),
                    (
                      value: UserPreferencesService.basemapLight,
                      icon: CupertinoIcons.sun_max_fill,
                      title: 'Monochrome Light',
                      subtitle:
                          'Clean, high-key grayscale styling optimized for bright sunlight conditions.',
                      previewColor: Color(0xFFF4F4F5),
                      badgeText: null,
                    ),
                    (
                      value: UserPreferencesService.basemapStandard,
                      icon: CupertinoIcons.globe,
                      title: 'Standard OpenStreetMap',
                      subtitle:
                          'Classic full-color topological map rendering pathways, greenery, and buildings.',
                      previewColor: Color(0xFFE4E4E7),
                      badgeText: null,
                    ),
                  ]) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _BasemapOptionCard(
                        icon: option.icon,
                        title: option.title,
                        subtitle: option.subtitle,
                        previewColor: option.previewColor,
                        badgeText: option.badgeText,
                        selected: activeBasemap == option.value,
                        onTap: () => _setBasemap(option.value),
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Section: Units of Distance (Meters standardized)
                  Row(
                    children: [
                      const Icon(
                        CupertinoIcons.compass,
                        size: 16,
                        color: Color(0xFF18181B),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'MEASUREMENT SYSTEM',
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: const Color(0xFF52525B),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Units used for indoor dead-reckoning and campus path calculations.',
                    style: textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF71717A),
                    ),
                  ),
                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            CupertinoIcons.location_north_fill,
                            size: 18,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Metric (Meters & km)',
                                      style: textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF18181B),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          CupertinoIcons.checkmark,
                                          size: 11,
                                          color: Colors.white,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Meters',
                                          style: textTheme.labelSmall?.copyWith(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Fixed to meters for precision sensor fusion, PDR step length estimation, and AR floor anchors.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF71717A),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Section: Data & Storage
                  Row(
                    children: [
                      const Icon(
                        CupertinoIcons.device_phone_portrait,
                        size: 16,
                        color: Color(0xFF18181B),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'DATA & CACHE',
                        style: textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: const Color(0xFF52525B),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            CupertinoIcons.archivebox,
                            size: 18,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Local Map Storage',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Cached building floors, waypoints & paths',
                                style: textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF71717A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Active',
                            style: textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF27272A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
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
  final Color previewColor;
  final String? badgeText;
  final bool selected;
  final VoidCallback onTap;

  const _BasemapOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.previewColor,
    this.badgeText,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: const Color(0x10000000),
        highlightColor: const Color(0x08000000),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? Colors.white : const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Colors.black : const Color(0xFFE4E4E7),
              width: selected ? 1.5 : 1.0,
            ),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x0C000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selected ? Colors.black : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? Colors.black : const Color(0xFFE4E4E7),
                    width: 1,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: selected ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        if (badgeText != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4F4F5),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFFE4E4E7),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              badgeText!,
                              style: textTheme.labelSmall?.copyWith(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF52525B),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF71717A),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  size: 22,
                  color: selected ? Colors.black : const Color(0xFFA1A1AA),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

