import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../logic/geo_math.dart';
import '../models/outdoor_models.dart';
import '../models/saved_place.dart';
import '../providers/dashboard_providers.dart';
import '../services/location_service.dart';
import '../widgets/save_place_button.dart';
import '../screens/admin_studio_screen.dart';
import '../screens/map_viewer_screen.dart';
import '../screens/search_screen.dart';

/// Draggable bottom sheet holding the dashboard's searchable campus
/// directory. Stays moveable (drag handle + snap sizes) so the CARTO
/// outdoor map behind it can be revealed on demand. Never fully closes:
/// it always covers at least 40% of the screen.
class DashboardBottomSheet extends StatefulWidget {
  final DashboardState dashboardState;
  final GeoPoint? userGps;

  /// Optional controller so the parent can read the live sheet size
  /// (e.g. to center map content in the uncovered region).
  final DraggableScrollableController? controller;

  const DashboardBottomSheet({
    super.key,
    required this.dashboardState,
    required this.userGps,
    this.controller,
  });

  @override
  State<DashboardBottomSheet> createState() => _DashboardBottomSheetState();
}

class _DashboardBottomSheetState extends State<DashboardBottomSheet> {
  String _selectedCategory = 'All';

  static const _categories = [
    'All',
    'Classrooms',
    'Restrooms',
    'Elevators',
    'Labs',
    'Offices',
    'Dining',
  ];

  static const _sampleComplexes = [
    _CampusDirectoryComplex(
      name: 'Science & Engineering Complex',
      subtitle: '80m away · Live GPS calibrated',
      floors: ['L1', 'L2', 'L3', 'L4'],
      icon: CupertinoIcons.building_2_fill,
      distanceMeters: 80,
    ),
    _CampusDirectoryComplex(
      name: 'Innovation & Computing Hub',
      subtitle: '140m away · High accuracy indoor mesh',
      floors: ['B1', 'L1', 'L2', 'L3'],
      icon: Icons.memory,
      distanceMeters: 140,
    ),
    _CampusDirectoryComplex(
      name: 'Student Center & Dining Pavilion',
      subtitle: '210m away',
      floors: ['L1', 'L2'],
      icon: Icons.local_cafe_outlined,
      distanceMeters: 210,
    ),
    _CampusDirectoryComplex(
      name: 'Central Library & Learning Commons',
      subtitle: '350m away',
      floors: ['L1', 'L2', 'L3', 'L4', 'L5'],
      icon: CupertinoIcons.book_fill,
      distanceMeters: 350,
    ),
  ];

  /// Human distance: whole metres below 1 km, one-decimal km above.
  String _formatDistance(double meters) {
    if (meters > 999) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()}m';
  }

  String _formatFloorName(int? floor) {    if (floor == null) return 'L1';
    if (floor < 0) return 'B${floor.abs()}';
    if (floor == 0) return 'L0';
    return 'L$floor';
  }

  IconData _iconForBuilding(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('tech') ||
        lower.contains('comput') ||
        lower.contains('innov') ||
        lower.contains('hub') ||
        lower.contains('lab')) {
      return Icons.memory;
    }
    if (lower.contains('din') ||
        lower.contains('cafe') ||
        lower.contains('food') ||
        lower.contains('center') ||
        lower.contains('student')) {
      return Icons.local_cafe_outlined;
    }
    if (lower.contains('lib') ||
        lower.contains('learn') ||
        lower.contains('book')) {
      return CupertinoIcons.book_fill;
    }
    return CupertinoIcons.building_2_fill;
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = widget.dashboardState;

    return Padding(
      // Floating-card margins so every rounded corner is visible
      // against the map behind the sheet.
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.40,
        maxChildSize: 0.95,
        snap: true,
        snapSizes: const [0.40, 0.62, 0.95],
        controller: widget.controller,
        builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
        ),
        child: dashboardState.isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.black),
              )
            : CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE4E4E7),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildSearchBar(),
                          const SizedBox(height: 14),
                          _buildCategoryFilter(),
                          const SizedBox(height: 20),
                          _buildDirectoryHeader(dashboardState),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                  _buildComplexesList(dashboardState),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 24),
                  ),
                ],
              ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SearchScreen()),
        );
      },
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFFF4F4F5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.search,
              color: Color(0xFF71717A),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Search rooms, labs, stairs, restrooms...',
                style: GoogleFonts.inter(
                  color: const Color(0xFF71717A),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryFilter() {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = _categories[index];
          final isSelected = cat == _selectedCategory;
          return GestureDetector(
            onTap: () {
              setState(() => _selectedCategory = cat);
              if (cat != 'All') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                );
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.black : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color:
                      isSelected ? Colors.black : const Color(0xFFE4E4E7),
                  width: 1,
                ),
              ),
              child: Center(
                child: Text(
                  cat,
                  style: GoogleFonts.inter(
                    color: isSelected ? Colors.white : const Color(0xFF18181B),
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDirectoryHeader(DashboardState dashboardState) {
    final count = dashboardState.entries.isNotEmpty
        ? dashboardState.groupedByBuilding.length
        : _sampleComplexes.length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'CAMPUS DIRECTORY',
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF71717A),
            letterSpacing: 0.8,
          ),
        ),
        Text(
          '$count Complexes Near You',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF71717A),
          ),
        ),
      ],
    );
  }

  /// Real buildings sorted nearest-first (GPS distance when known),
  /// falling back to A–Z. Samples are already distance-ordered.
  List<MapEntry<String, List<BuildingMapEntry>>> _sortedBuildings(
      DashboardState dashboardState) {
    final buildings = dashboardState.groupedByBuilding.entries.toList();
    buildings.sort((a, b) {
      final la = dashboardState.buildingLocations[a.key];
      final lb = dashboardState.buildingLocations[b.key];
      if (widget.userGps != null && la != null && lb != null) {
        final da =
            haversineMeters(widget.userGps!, (la.latitude, la.longitude));
        final db =
            haversineMeters(widget.userGps!, (lb.latitude, lb.longitude));
        return da.compareTo(db);
      }
      if (widget.userGps != null && (la != null || lb != null)) {
        return la != null ? -1 : 1;
      }
      return a.key.compareTo(b.key);
    });
    return buildings;
  }

  Widget _buildComplexesList(DashboardState dashboardState) {
    if (dashboardState.entries.isNotEmpty) {
      final buildings = _sortedBuildings(dashboardState);
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final building = buildings[index];
              return _buildRealBuildingCard(
                building.key,
                building.value,
                dashboardState.buildingLocations,
              );
            },
            childCount: buildings.length,
          ),
        ),
      );
    }

    // Default campus directory complexes, nearest first.
    final samples = List<_CampusDirectoryComplex>.of(_sampleComplexes)
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final complex = samples[index];
            return _buildSampleComplexCard(complex);
          },
          childCount: samples.length,
        ),
      ),
    );
  }

  Widget _buildRealBuildingCard(
    String name,
    List<BuildingMapEntry> floors,
    Map<String, BuildingLocation> locations,
  ) {
    final location = locations[name];
    String subtitle = 'High accuracy indoor mesh';
    if (widget.userGps != null && location != null) {
      final dist = haversineMeters(
          widget.userGps!, (location.latitude, location.longitude));
      subtitle = '${_formatDistance(dist)} away · Live GPS calibrated';
    } else if (location != null) {
      subtitle = 'Live GPS calibrated';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _iconForBuilding(name),
                  color: const Color(0xFF18181B),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.black,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SavePlaceButton(
                place: SavedPlace.forBuilding(name),
                iconSize: 19,
              ),
              GestureDetector(
                onTap: () {
                  if (floors.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MapViewerScreen(
                          mapKey: floors.first.key,
                          mapName: floors.first.title,
                        ),
                      ),
                    );
                  }
                },
                child: const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: Color(0xFF71717A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, thickness: 1, color: Color(0xFFF4F4F5)),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                'Floors',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF71717A),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in floors)
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MapViewerScreen(
                                mapKey: entry.key,
                                mapName: entry.title,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFA),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: const Color(0xFFE4E4E7), width: 1),
                          ),
                          child: Text(
                            _formatFloorName(entry.floor),
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF18181B),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSampleComplexCard(_CampusDirectoryComplex complex) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  complex.icon,
                  color: const Color(0xFF18181B),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      complex.name,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.black,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      complex.subtitle,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () =>
                    _onSampleFloorTap(complex.name, complex.floors.first),
                child: const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: Color(0xFF71717A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, thickness: 1, color: Color(0xFFF4F4F5)),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                'Floors',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF71717A),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final floor in complex.floors)
                      GestureDetector(
                        onTap: () => _onSampleFloorTap(complex.name, floor),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFA),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: const Color(0xFFE4E4E7), width: 1),
                          ),
                          child: Text(
                            floor,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF18181B),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onSampleFloorTap(String buildingName, String floorLabel) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '$buildingName • $floorLabel',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        content: Text(
          'This floor space is in the campus directory. Admin floor recording, CAD modeling, and link management are located in MapX Studio.',
          style: GoogleFonts.inter(
            fontSize: 13,
            color: const Color(0xFF52525B),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Close',
              style: GoogleFonts.inter(
                color: const Color(0xFF71717A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminStudioScreen()),
              );
            },
            child: Text(
              'Open MapX Studio',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _CampusDirectoryComplex {
  final String name;
  final String subtitle;
  final List<String> floors;
  final IconData icon;
  final double distanceMeters;

  const _CampusDirectoryComplex({
    required this.name,
    required this.subtitle,
    required this.floors,
    required this.icon,
    required this.distanceMeters,
  });
}
