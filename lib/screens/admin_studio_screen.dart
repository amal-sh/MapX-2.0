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
import 'outdoor_map_screen.dart';
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

  void _confirmDeleteBuilding(String building, int floorCount) {
    final outerContext = context;
    showDialog(
      context: outerContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Delete Building?',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
        content: Text(
          floorCount == 0
              ? 'Are you sure you want to delete "$building"? It has no recorded floors, so only the building entry will be removed.'
              : 'Are you sure you want to delete "$building" and all $floorCount recorded floor${floorCount == 1 ? '' : 's'}? This removes their trajectories, anchors, and places. This cannot be undone.',
          style: GoogleFonts.inter(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: const Color(0xFF71717A)),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await ref
                  .read(dashboardProvider.notifier)
                  .deleteBuilding(building);
              if (!outerContext.mounted) return;
              ScaffoldMessenger.of(outerContext).showSnackBar(
                SnackBar(
                  content: Text('Deleted "$building".'),
                  duration: const Duration(seconds: 2),
                ),
              );
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
    final grouped = dashboardState.groupedByBuilding;
    final buildingNames = dashboardState.allBuildingNames;

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
                              builder: (_) => const OutdoorMapScreen()),
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
              '$buildingCount Buildings  Ã‚Â·  $floorCount Floors  Ã‚Â·  $nodeCount Nodes  Ã‚Â·  $placeCount Places',
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
  }) {
    final locStr = location != null
        ? '${location.latitude.toStringAsFixed(4)}Ã‚Â° N, ${location.longitude.toStringAsFixed(4)}Ã‚Â° W Ã‚Â· ${floors.length} Floor${floors.length == 1 ? '' : 's'}'
        : '${floors.length} Floor${floors.length == 1 ? '' : 's'} Ã‚Â· GPS pending';

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
