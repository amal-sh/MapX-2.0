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
import 'campus_map_screen.dart';
import 'map_editor_screen.dart';
import 'map_viewer_screen.dart';
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
    final details = await showDialog<({String name, int floor})>(
      context: context,
      builder: (_) => _NewAdminMapDialog(
        exists: ref.read(dashboardProvider.notifier).exists,
      ),
    );
    if (details == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
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
      await prefs.setString(
          'building_gps_${details.name}', jsonEncode(location.toJson()));

      unawaited(FirestoreService.instance.saveBuilding(
        buildingName: details.name,
        location: location,
        initialFloor: details.floor,
      ));
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

  Future<void> _addFloor(String building) async {
    final details = await showDialog<({String name, int floor})>(
      context: context,
      builder: (_) => _AddAdminFloorDialog(
        building: building,
        exists: ref.read(dashboardProvider.notifier).exists,
      ),
    );
    if (details == null || !mounted) return;

    final dashboardState = ref.read(dashboardProvider);
    BuildingLocation? location = dashboardState.buildingLocations[building];
    location ??= await LocationService.instance.getCurrentLocation();

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

  void _confirmDelete(BuildingMapEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete Floor Map?',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Are you sure you want to delete "${entry.title}"? This will remove its recorded trajectory, anchors, and places.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: const Color(0xFF71717A)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(dashboardProvider.notifier).deleteMap(entry.key);
            },
            child: Text(
              'Delete',
              style: GoogleFonts.inter(
                color: const Color(0xFFDC2626),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardProvider);
    final buildings = dashboardState.groupedByBuilding.entries.toList();

    return Scaffold(
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
                              builder: (_) => const CampusMapScreen()),
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
                        buildings.isNotEmpty
                            ? '${buildings.length} Sites'
                            : '3 Sites',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF71717A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Building Groups
                  if (buildings.isNotEmpty)
                    for (final b in buildings)
                      _buildBuildingSection(
                        name: b.key,
                        floors: b.value,
                        location: dashboardState.buildingLocations[b.key],
                      )
                  else
                    ..._buildSampleBuildingSections(),
                ],
              ),
            ),

            // Bottom Status Bar
            _buildBottomStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsBanner(DashboardState state) {
    final buildingCount = state.groupedByBuilding.isNotEmpty
        ? state.groupedByBuilding.length
        : 3;
    final floorCount =
        state.entries.isNotEmpty ? state.entries.length : 9;
    final nodeCount = state.entries.isNotEmpty
        ? state.entries.length * 48
        : 412;

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
              '$buildingCount Buildings  ·  $floorCount Floors  ·  $nodeCount AR Nodes',
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
    BuildingLocation? location,
  }) {
    final locStr = location != null
        ? '${location.latitude.toStringAsFixed(4)}° N, ${location.longitude.toStringAsFixed(4)}° W · ${floors.length} Floors'
        : '37.7749° N, 122.4194° W · ${floors.length} Floors';

    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Building Name & + Floor Button
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
            ],
          ),
          const SizedBox(height: 10),

          // Floors List Container
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
                    title: floors[i].floor == null
                        ? 'Floor 1'
                        : 'Floor ${floors[i].floor}',
                    area: '(Main Area)',
                    subtitle: '48 Nodes · 2 Elevators · 2 Stairs',
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
    required String area,
    required String subtitle,
    required String mapKey,
    required BuildingMapEntry floorEntry,
  }) {
    return Padding(
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
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      area,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: const Color(0xFF71717A),
                  ),
                ),
              ],
            ),
          ),

          // Action Buttons: Edit, Walk (Preview), Delete
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
            icon: const Icon(CupertinoIcons.person_fill,
                size: 18, color: Color(0xFF27272A)),
            tooltip: 'Walk in AR',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MapViewerScreen(
                    mapKey: mapKey,
                    mapName: floorEntry.title,
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
    );
  }

  List<Widget> _buildSampleBuildingSections() {
    return [
      // Complex 1: Science & Engineering Complex
      _buildSampleBuildingGroup(
        name: 'Science & Engineering Complex',
        gps: '37.7749° N, 122.4194° W · 3 Floors',
        floors: const [
          _SampleFloor(
            title: 'Floor 3',
            area: '(Laboratories)',
            nodes: '62 Nodes · 2 Elevators · 2 Stairs',
          ),
          _SampleFloor(
            title: 'Floor 2',
            area: '(Lecture Halls)',
            nodes: '48 Nodes · 3 Elevators · 2 Stairs',
          ),
          _SampleFloor(
            title: 'Floor 1',
            area: '(Main Atrium)',
            nodes: '84 Nodes · 4 Exits · Emergency Access',
          ),
        ],
      ),

      // Complex 2: Central Library & Media Center
      _buildSampleBuildingGroup(
        name: 'Central Library & Media Center',
        gps: '37.7752° N, 122.4181° W · 2 Floors',
        floors: const [
          _SampleFloor(
            title: 'Floor 2',
            area: '(Quiet Archives)',
            nodes: '36 Nodes · 1 Elevator · 2 Stairs',
          ),
          _SampleFloor(
            title: 'Floor 1',
            area: '(Tech Hub & Circ)',
            nodes: '52 Nodes · 2 Elevators · 3 Exits',
          ),
        ],
      ),

      // Complex 3: Innovation & Computing Lab [Draft] (Empty state card)
      _buildDraftEmptyBuilding(
        name: 'Innovation & Computing Lab',
        gps: '37.7761° N, 122.4202° W · 0 Floors',
      ),
    ];
  }

  Widget _buildSampleBuildingGroup({
    required String name,
    required String gps,
    required List<_SampleFloor> floors,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    ),
                    const SizedBox(height: 2),
                    Text(
                      gps,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
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
            ],
          ),
          const SizedBox(height: 10),
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
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                              CupertinoIcons.square_stack_3d_up,
                              color: Color(0xFF18181B),
                              size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    floors[i].title,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    floors[i].area,
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: const Color(0xFF71717A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                floors[i].nodes,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: const Color(0xFF71717A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(CupertinoIcons.pencil,
                              size: 18, color: Color(0xFF27272A)),
                          tooltip: 'Edit Floor',
                          onPressed: () => _startNewMap(),
                        ),
                        IconButton(
                          icon: const Icon(CupertinoIcons.person_fill,
                              size: 18, color: Color(0xFF27272A)),
                          tooltip: 'Walk in AR',
                          onPressed: () => _startNewMap(),
                        ),
                        IconButton(
                          icon: const Icon(CupertinoIcons.trash,
                              size: 18, color: Color(0xFF71717A)),
                          tooltip: 'Delete Floor',
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Sample floor map item'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDraftEmptyBuilding({
    required String name,
    required String gps,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F4F5),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFE4E4E7)),
                      ),
                      child: Text(
                        'Draft',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF71717A),
                        ),
                      ),
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
            ],
          ),
          const SizedBox(height: 2),
          Text(
            gps,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: const Color(0xFF71717A),
            ),
          ),
          const SizedBox(height: 12),

          // No indoor maps recorded yet container
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFE4E4E7),
                style: BorderStyle.solid,
              ),
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
                  'Tap "+ Walk & Record" above to map\nrooms, halls, and AR anchor points.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: const Color(0xFF71717A),
                    height: 1.4,
                  ),
                ),
              ],
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
}

class _SampleFloor {
  final String title;
  final String area;
  final String nodes;

  const _SampleFloor({
    required this.title,
    required this.area,
    required this.nodes,
  });
}

class _NewAdminMapDialog extends StatefulWidget {
  final bool Function(String name, int floor) exists;
  const _NewAdminMapDialog({required this.exists});

  @override
  State<_NewAdminMapDialog> createState() => _NewAdminMapDialogState();
}

class _NewAdminMapDialogState extends State<_NewAdminMapDialog> {
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
      title: Text('Walk & Record New Floor',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Building name',
              hintText: 'e.g., Science Complex',
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
              hintText: '0 = ground floor, 1 = first floor',
              errorText: _floorError,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style: GoogleFonts.inter(color: const Color(0xFF71717A))),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _submit,
          child: Text('Start Recording',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _AddAdminFloorDialog extends StatefulWidget {
  final String building;
  final bool Function(String name, int floor) exists;
  const _AddAdminFloorDialog({required this.building, required this.exists});

  @override
  State<_AddAdminFloorDialog> createState() => _AddAdminFloorDialogState();
}

class _AddAdminFloorDialogState extends State<_AddAdminFloorDialog> {
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
      title: Text('Add Floor to ${widget.building}',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      content: TextField(
        controller: _floorController,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Floor number',
          hintText: 'e.g., 2',
          errorText: _floorError,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style: GoogleFonts.inter(color: const Color(0xFF71717A))),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _submit,
          child: Text('Start Recording',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
