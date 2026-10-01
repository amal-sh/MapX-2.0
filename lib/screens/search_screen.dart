import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/search_models.dart';
import '../providers/search_providers.dart';
import '../services/search_service.dart';
import 'map_viewer_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? initialQuery;
  final String? preselectedBuilding;

  const SearchScreen({
    super.key,
    this.initialQuery,
    this.preselectedBuilding,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery ?? '');

    // Set initial filters on next microtask after provider tree is ready
    Future.microtask(() {
      if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
        ref.read(searchQueryProvider.notifier).state = widget.initialQuery!;
      }
      if (widget.preselectedBuilding != null) {
        ref.read(searchFocusedBuildingProvider.notifier).state = widget.preselectedBuilding;
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    ref.read(searchQueryProvider.notifier).state = query;
  }

  void _toggleBuildingFocus(String? buildingName) {
    final current = ref.read(searchFocusedBuildingProvider);
    ref.read(searchFocusedBuildingProvider.notifier).state = (current == buildingName) ? null : buildingName;
  }

  void _setCategory(String category) {
    ref.read(searchCategoryFilterProvider.notifier).state = category;
  }

  void _openWaypoint(SearchWaypointInfo waypoint) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewerScreen(
          mapKey: waypoint.mapKey,
          mapName: waypoint.buildingName,
          targetDestinationName: waypoint.name,
          targetFloor: waypoint.floor,
        ),
      ),
    );
  }

  void _openBuilding(BuildingSearchInfo building) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapViewerScreen(
          mapKey: building.primaryMapKey,
          mapName: building.name,
          targetFloor: building.floors.firstOrNull ?? 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contextAsync = ref.watch(searchContextProvider);
    final results = ref.watch(searchResultsProvider);
    final focusedBuilding = ref.watch(searchFocusedBuildingProvider);
    final selectedCategory = ref.watch(searchCategoryFilterProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Container(
          height: 44,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F4F5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE4E4E7)),
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            style: const TextStyle(fontSize: 15, color: Colors.black),
            decoration: InputDecoration(
              prefixIcon: const Icon(CupertinoIcons.search, size: 18, color: Color(0xFF71717A)),
              hintText: focusedBuilding != null
                  ? 'Search in $focusedBuilding...'
                  : 'Search rooms, places, buildings...',
              hintStyle: const TextStyle(color: Color(0xFF71717A), fontSize: 14),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(CupertinoIcons.clear_circled_solid, size: 16, color: Color(0xFF71717A)),
                      onPressed: () {
                        _searchController.clear();
                        _onQueryChanged('');
                      },
                    )
                  : null,
            ),
          ),
        ),
      ),
      body: contextAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: Colors.black)),
        error: (err, stack) => Center(
          child: Text('Unable to load places: $err', style: const TextStyle(color: Color(0xFF71717A))),
        ),
        data: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLocationContextBar(ctx, focusedBuilding),
            _buildCategoryFilters(selectedCategory),
            const Divider(height: 1, color: Color(0xFFE4E4E7)),
            Expanded(child: _buildResultsList(results, focusedBuilding)),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationContextBar(SearchLocationContext context, String? focusedBuilding) {
    final isInBuilding = context.isInBuilding;
    final currentB = context.currentBuilding;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      color: const Color(0xFFFAFAFA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isInBuilding ? CupertinoIcons.location_fill : CupertinoIcons.compass,
                size: 15,
                color: isInBuilding ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isInBuilding
                      ? 'You are at ${currentB!.name}'
                      : context.nearbyBuildings.isNotEmpty
                          ? 'Nearby: ${context.nearbyBuildings.first.name} (${context.nearbyBuildings.first.distanceFormatted})'
                          : 'GPS ready · Searching all maps',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF18181B),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (focusedBuilding != null)
                GestureDetector(
                  onTap: () => _toggleBuildingFocus(null),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Text(
                          'Show All',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                        SizedBox(width: 4),
                        Icon(CupertinoIcons.clear, size: 10, color: Colors.white),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (!isInBuilding && context.nearbyBuildings.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('Focus on: ', style: TextStyle(fontSize: 11, color: Color(0xFF71717A))),
                  for (final b in context.nearbyBuildings.take(3)) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(
                          '${b.name} (${b.distanceFormatted})',
                          style: TextStyle(
                            fontSize: 11,
                            color: focusedBuilding == b.name ? Colors.white : Colors.black,
                          ),
                        ),
                        selected: focusedBuilding == b.name,
                        selectedColor: Colors.black,
                        backgroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFFE4E4E7)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                        onSelected: (_) => _toggleBuildingFocus(b.name),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryFilters(String selectedCategory) {
    final categories = [
      ('all', 'All', CupertinoIcons.square_grid_2x2),
      ('places', 'Rooms & Places', CupertinoIcons.placemark),
      ('buildings', 'Buildings', CupertinoIcons.building_2_fill),
      ('connectors', 'Stairs & Lifts', CupertinoIcons.square_stack_3d_up),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: categories.map((cat) {
          final isSelected = selectedCategory == cat.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              avatar: Icon(
                cat.$3,
                size: 13,
                color: isSelected ? Colors.white : const Color(0xFF52525B),
              ),
              label: Text(
                cat.$2,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? Colors.white : Colors.black,
                ),
              ),
              selected: isSelected,
              selectedColor: Colors.black,
              backgroundColor: const Color(0xFFF4F4F5),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
              onSelected: (_) => _setCategory(cat.$1),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildResultsList(SearchResults results, String? focusedBuilding) {
    if (results.isEmpty) {
      return Center(
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
                child: const Icon(CupertinoIcons.search, size: 40, color: Color(0xFF71717A)),
              ),
              const SizedBox(height: 16),
              const Text(
                'No matching results',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.black),
              ),
              const SizedBox(height: 6),
              Text(
                focusedBuilding != null
                    ? 'No results in "$focusedBuilding". Tap "Show All" above to search across all buildings.'
                    : 'Try checking your spelling or searching for a room, stairs, or building name.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF71717A), height: 1.4),
              ),
              if (focusedBuilding != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _toggleBuildingFocus(null),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black,
                    side: const BorderSide(color: Colors.black),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Search All Buildings'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (results.waypoints.isNotEmpty) ...[
          _buildSectionHeader('Places & Rooms (${results.waypoints.length})'),
          for (final wp in results.waypoints) _buildWaypointTile(wp),
        ],
        if (results.buildings.isNotEmpty) ...[
          _buildSectionHeader('Buildings (${results.buildings.length})'),
          for (final b in results.buildings) _buildBuildingTile(b),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF71717A),
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildWaypointTile(SearchWaypointInfo wp) {
    final isStairsOrLift = wp.isConnector;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: isStairsOrLift ? const Color(0xFFF4F4F5) : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          isStairsOrLift ? CupertinoIcons.square_stack_3d_up : CupertinoIcons.placemark,
          size: 18,
          color: isStairsOrLift ? Colors.black : const Color(0xFF2563EB),
        ),
      ),
      title: Text(
        wp.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black),
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              wp.locationDescription,
              style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (wp.distanceMeters != null)
            Text(
              wp.distanceMeters! < 1000
                  ? '${wp.distanceMeters!.round()}m away'
                  : '${(wp.distanceMeters! / 1000).toStringAsFixed(1)}km',
              style: const TextStyle(fontSize: 11, color: Color(0xFF52525B), fontWeight: FontWeight.w500),
            ),
        ],
      ),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 14, color: Color(0xFFA1A1AA)),
      onTap: () => _openWaypoint(wp),
    );
  }

  Widget _buildBuildingTile(BuildingSearchInfo b) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(CupertinoIcons.building_2_fill, size: 18, color: Colors.white),
      ),
      title: Text(
        b.name,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black),
      ),
      subtitle: Text(
        '${b.floorSummary}${b.distanceFormatted.isNotEmpty ? " · ${b.distanceFormatted}" : ""}',
        style: const TextStyle(fontSize: 12, color: Color(0xFF71717A)),
      ),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 14, color: Color(0xFFA1A1AA)),
      onTap: () => _openBuilding(b),
    );
  }
}
