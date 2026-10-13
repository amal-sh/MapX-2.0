import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/dashboard_providers.dart';
import '../services/firestore_service.dart';
import '../services/location_service.dart';
import '../widgets/building_editor_sheet.dart';
import '../widgets/dialogs/add_floor_dialog.dart';
import '../widgets/dialogs/confirm_delete_dialog.dart';
import '../widgets/dialogs/create_building_dialog.dart';
import 'connector_links_screen.dart';
import 'map_editor_screen.dart';
import 'mapping_screen.dart';

class AdminStudioScreen extends StatelessWidget {
  const AdminStudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget content = const _AdminStudioScreenContent();
    try {
      ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      content = ProviderScope(child: content);
    }
    return content;
  }
}

class _AdminStudioScreenContent extends ConsumerStatefulWidget {
  const _AdminStudioScreenContent();

  @override
  ConsumerState<_AdminStudioScreenContent> createState() =>
      _AdminStudioScreenState();
}

class _AdminStudioScreenState extends ConsumerState<_AdminStudioScreenContent> {
  static const _methodChannel = MethodChannel('mapx/arcore');
  bool _isDeviceSupported = true;
  bool _isSettingUp = false;

  @override
  void initState() {
    super.initState();
    _checkArCoreSupport();
  }

  Future<void> _checkArCoreSupport() async {
    try {
      final availability =
          await _methodChannel.invokeMethod<String>('checkAvailability');
      if (availability != 'SUPPORTED_INSTALLED') {
        if (mounted) setState(() => _isDeviceSupported = false);
      }
    } catch (_) {
      // Allow simulator / desktop testing
    }
  }

  Future<void> _startNewMap() async {
    final details = await CreateBuildingDialog.show(
      context,
      exists: ref.read(dashboardProvider.notifier).exists,
    );
    if (details == null || !mounted) return;

    setState(() => _isSettingUp = true);

    try {
      final location = await LocationService.instance.getCurrentLocation();
      // Register the building shell first so it exists even with zero floors
      // (e.g. user backs out of the recording flow) and even without GPS.
      await ref
          .read(dashboardProvider.notifier)
          .registerBuilding(details.name, location);
      if (location != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'building_gps_${details.name}', jsonEncode(location.toJson()));

        unawaited(FirestoreService.instance.saveBuilding(
          buildingName: details.name,
          location: location,
          initialFloor: details.floor,
        ));
      } else {
        unawaited(FirestoreService.instance.saveBuilding(
          buildingName: details.name,
          initialFloor: details.floor,
        ));
      }

      if (!mounted) return;
      setState(() => _isSettingUp = false);

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
      if (saved == true && mounted) {
        ref.read(dashboardProvider.notifier).loadMaps();
      }
    } catch (e) {
      debugPrint('Error setting up building map: $e');
    } finally {
      if (mounted && _isSettingUp) {
        setState(() => _isSettingUp = false);
      }
    }
  }

  Future<void> _addFloor(String building) async {
    final details = await AddFloorDialog.show(
      context,
      building: building,
      exists: ref.read(dashboardProvider.notifier).exists,
    );
    if (details == null || !mounted) return;

    final dashboardState = ref.read(dashboardProvider);
    BuildingLocation? location = dashboardState.buildingLocations[building];
    if (location == null) {
      setState(() => _isSettingUp = true);
      try {
        location = await LocationService.instance.getCurrentLocation();
      } finally {
        if (mounted && _isSettingUp) {
          setState(() => _isSettingUp = false);
        }
      }
    }

    if (!mounted) return;
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
    if (saved == true && mounted) {
      ref.read(dashboardProvider.notifier).loadMaps();
    }
  }

  Future<void> _confirmDelete(BuildingMapEntry entry) async {
    final confirmed = await ConfirmDeleteDialog.show(
      context,
      title: 'Delete Floor Map?',
      message:
          'Are you sure you want to delete "${entry.title}"? This will remove its recorded trajectory, anchors, and places.',
    );
    if (confirmed == true && mounted) {
      ref.read(dashboardProvider.notifier).deleteMap(entry.key);
    }
  }

  Future<void> _confirmDeleteBuilding(String building, int floorCount) async {
    final confirmed = await ConfirmDeleteDialog.show(
      context,
      title: 'Delete Building?',
      message: floorCount == 0
          ? 'Are you sure you want to delete "$building"? It has no recorded floors, so only the building entry will be removed.'
          : 'Are you sure you want to delete "$building" and all $floorCount recorded floor${floorCount == 1 ? '' : 's'}? This removes their trajectories, anchors, and places. This cannot be undone.',
    );
    if (confirmed == true && mounted) {
      await ref.read(dashboardProvider.notifier).deleteBuilding(building);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted "$building".'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardProvider);
    final grouped = dashboardState.groupedByBuilding;
    final buildingNames = dashboardState.allBuildingNames;

    return PopScope(
      canPop: !_isSettingUp,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: Colors.white,
            appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left,
              color: Colors.black, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MapX Studio',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.black,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'ADMIN',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // Walk & Record New Floor Hero Button
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _startNewMap,
                      icon: const Icon(CupertinoIcons.viewfinder, size: 22),
                      label: Text(
                        'Walk & Record New Floor',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Connector Links Secondary Button
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFFF4F4F5),
                        foregroundColor: const Color(0xFF18181B),
                        elevation: 0,
                        side: const BorderSide(color: Color(0xFFE4E4E7)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ConnectorLinksScreen()),
                        );
                      },
                      icon: const Icon(CupertinoIcons.circle_grid_hex,
                          size: 18, color: Color(0xFF18181B)),
                      label: Text(
                        'Connector Links',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Metrics Summary Banner
                  _buildMetricsBanner(dashboardState),
                  const SizedBox(height: 22),

                  // Section Header: MAPPED BUILDINGS & FLOORS
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'MAPPED BUILDINGS & FLOORS',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF71717A),
                          letterSpacing: 0.8,
                        ),
                      ),
                      Text(
                        '${buildingNames.length} Sites',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF71717A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Building Groups (includes zero-floor buildings).
                  if (buildingNames.isNotEmpty)
                    for (final bName in buildingNames)
                      _buildBuildingSection(
                        name: bName,
                        floors: grouped[bName] ?? const [],
                        location: dashboardState.buildingLocations[bName],
                        stats: dashboardState.floorStats,
                        placeName:
                            dashboardState.buildingPlaceNames[bName],
                      )
                  else
                    _buildEmptyStudioState(),
                ],
              ),
            ),

            // Bottom Status Bar
            _buildBottomStatusBar(),
          ],
        ),
      ),
    ),
    if (_isSettingUp) _buildSettingUpOverlay(),
  ],
),
);
  }

  Widget _buildMetricsBanner(DashboardState state) {
    final buildingCount = state.allBuildingNames.length;
    final floorCount = state.entries.length;
    final nodeCount =
        state.floorStats.values.fold<int>(0, (sum, s) => sum + s.nodeCount);
    final placeCount =
        state.floorStats.values.fold<int>(0, (sum, s) => sum + s.placeCount);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE4E4E7)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$buildingCount Buildings  ·  $floorCount Floors  ·  $nodeCount Nodes  ·  $placeCount Places',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF27272A),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(
            CupertinoIcons.chart_bar_square,
            size: 16,
            color: Color(0xFF71717A),
          ),
        ],
      ),
    );
  }

  Widget _buildBuildingSection({
    required String name,
    required List<BuildingMapEntry> floors,
    required Map<String, FloorMapStats> stats,
    BuildingLocation? location,
    String? placeName,
  }) {
    // Same OSM place name shown in the dashboard directory card
    // (`dashboard_bottom_sheet.dart`): "<floors> · <place>".
    final floorLabel =
        '${floors.length} Floor${floors.length == 1 ? '' : 's'}';
    final place = placeName?.trim();
    final String locStr;
    if (place != null && place.isNotEmpty) {
      locStr = location != null
          ? '$floorLabel · $place'
          : '$floorLabel · $place · GPS pending';
    } else {
      locStr = location != null
          ? '$floorLabel · Live GPS calibrated'
          : '$floorLabel · GPS pending';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Building Name, + Floor Button & building menu
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      locStr,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  side: const BorderSide(color: Color(0xFFE4E4E7)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => _addFloor(name),
                child: Text(
                  '+ Floor',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(CupertinoIcons.ellipsis,
                    size: 18, color: Color(0xFF27272A)),
                tooltip: 'Building options',
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: (value) {
                  if (value == 'edit') {
                    showEditBuildingSheet(context, name);
                  } else if (value == 'links') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ConnectorLinksScreen(initialBuilding: name),
                      ),
                    );
                  } else if (value == 'delete') {
                    _confirmDeleteBuilding(name, floors.length);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.settings,
                            size: 16, color: Color(0xFF27272A)),
                        const SizedBox(width: 10),
                        Text('Edit building',
                            style: GoogleFonts.inter(fontSize: 13)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'links',
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.circle_grid_hex,
                            size: 16, color: Color(0xFF27272A)),
                        const SizedBox(width: 10),
                        Text('Connector links',
                            style: GoogleFonts.inter(fontSize: 13)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.trash,
                            size: 16, color: Color(0xFFDC2626)),
                        const SizedBox(width: 10),
                        Text('Delete building',
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color: const Color(0xFFDC2626))),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Floors list, or an explicit empty-building card so a building
          // with zero floors still exists and can be managed.
          if (floors.isEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE4E4E7)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF4F4F5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(CupertinoIcons.compass,
                        color: Color(0xFF71717A), size: 18),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No indoor maps recorded yet',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap "+ Floor" above to map\nrooms, halls, and AR anchor points.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: const Color(0xFF71717A),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE4E4E7)),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < floors.length; i++) ...[
                    if (i > 0)
                      const Divider(
                          height: 1, thickness: 1, color: Color(0xFFF4F4F5)),
                    _buildFloorItem(
                      title: floors[i].displayTitle,
                      meta: floors[i].label != null
                          ? 'Floor ${floors[i].floor ?? '?'}'
                          : null,
                      stats: stats[floors[i].key],
                      mapKey: floors[i].key,
                      floorEntry: floors[i],
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFloorItem({
    required String title,
    required String? meta,
    required FloorMapStats? stats,
    required String mapKey,
    required BuildingMapEntry floorEntry,
  }) {
    final distanceLabel = stats?.distanceLabel ?? '';
    final tag = [
      ?meta,
      if (distanceLabel.isNotEmpty) distanceLabel,
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showFloorSettingsSheet(context, floorEntry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF4F4F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(CupertinoIcons.square_stack_3d_up,
                  color: Color(0xFF18181B), size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tag.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            tag,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF71717A),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stats?.subtitle ?? 'No data yet',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: const Color(0xFF71717A),
                    ),
                  ),
                ],
              ),
            ),

          // Action Buttons: Node Editor, Delete (no Walk/Navigate â€” that's for users)
          IconButton(
            icon: const Icon(CupertinoIcons.pencil,
                size: 18, color: Color(0xFF27272A)),
            tooltip: 'CAD & Node Editor',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MapEditorScreen(
                    mapKey: mapKey,
                    title: floorEntry.title,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.trash,
                size: 18, color: Color(0xFF71717A)),
            tooltip: 'Delete Floor',
            onPressed: () => _confirmDelete(floorEntry),
          ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStudioState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE4E4E7)),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Color(0xFFF4F4F5),
              shape: BoxShape.circle,
            ),
            child: const Icon(CupertinoIcons.building_2_fill,
                color: Color(0xFF71717A), size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            'No buildings mapped yet',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap "Walk & Record New Floor" above to map\nyour first building.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: const Color(0xFF71717A),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFF4F4F5))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF71717A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _isDeviceSupported
                    ? 'Engine: ARCore v2.0'
                    : 'Engine: ARCore (Device Unsupported)',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF52525B),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Icon(CupertinoIcons.arrow_2_circlepath,
                  size: 12, color: Color(0xFF71717A)),
              const SizedBox(width: 4),
              Text(
                'Drafts auto-saved',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF71717A),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingUpOverlay() {
    return Positioned.fill(
      child: AbsorbPointer(
        absorbing: true,
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          alignment: Alignment.center,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 36),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE4E4E7)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  'Setting it up...',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF18181B),
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

