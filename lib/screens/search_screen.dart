import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/saved_place.dart';
import '../models/search_models.dart';
import '../providers/search_providers.dart';
import '../services/search_service.dart';
import '../widgets/save_place_button.dart';
import 'map_viewer_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? initialQuery;
  final String? preselectedBuilding;
  final String? initialCategory;

  const SearchScreen({
    super.key,
    this.initialQuery,
    this.preselectedBuilding,
    this.initialCategory,
  });

  /// Factory for a smooth expanding transition from the dashboard search bar.
  static Route<void> route({
    String? initialQuery,
    String? preselectedBuilding,
    String? initialCategory,
  }) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) => SearchScreen(
        initialQuery: initialQuery,
        preselectedBuilding: preselectedBuilding,
        initialCategory: initialCategory,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
          ),
          child: child,
        );
      },
    );
  }

  /// Shared Hero flight shuttle so the search bar container smoothly expands
  /// and morphs without text jank, clipping glitches, or yellow underlines.
  static Widget buildSearchHeroFlight(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          return Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F5),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
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
                      decoration: TextDecoration.none,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();
  bool _isFocused = false;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery ?? '');
    _searchFocusNode.addListener(() {
      if (mounted) setState(() => _isFocused = _searchFocusNode.hasFocus);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Delay requesting focus slightly until the hero expansion has started
      // settling so the keyboard doesn't abruptly pop mid-expansion.
      _focusTimer = Timer(const Duration(milliseconds: 220), () {
        if (mounted && _searchController.text.isEmpty) {
          _searchFocusNode.requestFocus();
        }
      });
    });

    // Set initial filters on next microtask after provider tree is ready
    Future.microtask(() {
      if (!mounted) return;
      if (widget.initialQuery != null && widget.initialQuery!.isNotEmpty) {
        ref.read(searchQueryProvider.notifier).state = widget.initialQuery!;
      }
      if (widget.preselectedBuilding != null) {
        ref.read(searchFocusedBuildingProvider.notifier).state =
            widget.preselectedBuilding;
      }
      if (widget.initialCategory != null) {
        ref.read(searchCategoryFilterProvider.notifier).state =
            widget.initialCategory!;
      }
    });
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    ref.read(searchQueryProvider.notifier).state = query;
  }

  void _toggleBuildingFocus(String? buildingName) {
    final current = ref.read(searchFocusedBuildingProvider);
    ref.read(searchFocusedBuildingProvider.notifier).state =
        (current == buildingName) ? null : buildingName;
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

  String _formatFloorName(int? floor) {
    if (floor == null) return 'L1';
    if (floor < 0) return 'B${floor.abs()}';
    if (floor == 0) return 'L0';
    return 'L$floor';
  }

  @override
  Widget build(BuildContext context) {
    final contextAsync = ref.watch(searchContextProvider);
    final results = ref.watch(searchResultsProvider);
    final focusedBuilding = ref.watch(searchFocusedBuildingProvider);
    final selectedCategory = ref.watch(searchCategoryFilterProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildCupertinoHeader(focusedBuilding),
            Expanded(
              child: contextAsync.when(
                loading: () => _buildSkeletonView(),
                error: (err, stack) => Center(
                  child: Text(
                    'Unable to load campus directory',
                    style: GoogleFonts.inter(
                      color: const Color(0xFF71717A),
                      fontSize: 14,
                    ),
                  ),
                ),
                data: (ctx) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLocationContextBar(ctx, focusedBuilding),
                    _buildCategoryFilters(selectedCategory),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFFE4E4E7),
                    ),
                    Expanded(
                      child: _buildResultsList(results, focusedBuilding),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCupertinoHeader(String? focusedBuilding) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE4E4E7), width: 1),
        ),
      ),
      child: Row(
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            onPressed: () => Navigator.pop(context),
            child: const Icon(
              CupertinoIcons.chevron_left,
              color: Colors.black,
              size: 24,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Hero(
              tag: 'campus_search_bar_hero',
              flightShuttleBuilder: SearchScreen.buildSearchHeroFlight,
              child: Material(
                color: Colors.transparent,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F4F5),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color:
                          _isFocused ? Colors.black : const Color(0xFFE4E4E7),
                      width: _isFocused ? 1.2 : 1,
                    ),
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
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textInputAction: TextInputAction.search,
                          onChanged: _onQueryChanged,
                          cursorColor: Colors.black,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                            hintText: focusedBuilding != null
                                ? 'Search in $focusedBuilding...'
                                : 'Search rooms, labs, stairs, restrooms...',
                            hintStyle: GoogleFonts.inter(
                              color: const Color(0xFF71717A),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(32, 32),
                          onPressed: () {
                            _searchController.clear();
                            _onQueryChanged('');
                          },
                          child: const Icon(
                            CupertinoIcons.clear_circled_solid,
                            size: 18,
                            color: Color(0xFF71717A),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationContextBar(
    SearchLocationContext context,
    String? focusedBuilding,
  ) {
    final isInBuilding = context.isInBuilding;
    final currentB = context.currentBuilding;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: const Color(0xFFFAFAFA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: isInBuilding ? Colors.black : const Color(0xFFF4F4F5),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isInBuilding
                      ? CupertinoIcons.location_fill
                      : CupertinoIcons.compass,
                  size: 13,
                  color: isInBuilding ? Colors.white : const Color(0xFF18181B),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isInBuilding
                      ? 'You are at ${currentB!.name}'
                      : context.nearbyBuildings.isNotEmpty
                          ? 'Nearby: ${context.nearbyBuildings.first.name} (${context.nearbyBuildings.first.distanceFormatted})'
                          : 'Campus GPS ready · Searching all maps',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF18181B),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (focusedBuilding != null)
                GestureDetector(
                  onTap: () => _toggleBuildingFocus(null),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Show All',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          CupertinoIcons.clear,
                          size: 10,
                          color: Colors.white,
                        ),
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
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  Text(
                    'Focus: ',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF71717A),
                    ),
                  ),
                  for (final b in context.nearbyBuildings.take(4)) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => _toggleBuildingFocus(b.name),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: focusedBuilding == b.name
                                ? Colors.black
                                : Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: focusedBuilding == b.name
                                  ? Colors.black
                                  : const Color(0xFFE4E4E7),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            '${b.name} (${b.distanceFormatted})',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: focusedBuilding == b.name
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: focusedBuilding == b.name
                                  ? Colors.white
                                  : const Color(0xFF18181B),
                            ),
                          ),
                        ),
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
    const categories = [
      ('all', 'All', CupertinoIcons.square_grid_2x2),
      ('places', 'Rooms & Places', CupertinoIcons.placemark),
      ('buildings', 'Buildings', CupertinoIcons.building_2_fill),
      ('connectors', 'Stairs & Lifts', CupertinoIcons.square_stack_3d_up),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: categories.map((cat) {
          final isSelected = selectedCategory == cat.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _setCategory(cat.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.black : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isSelected
                        ? Colors.black
                        : const Color(0xFFE4E4E7),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      cat.$3,
                      size: 13,
                      color:
                          isSelected ? Colors.white : const Color(0xFF52525B),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      cat.$2,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w500,
                        color:
                            isSelected ? Colors.white : const Color(0xFF18181B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildResultsList(SearchResults results, String? focusedBuilding) {
    if (results.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F5),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
                ),
                child: const Icon(
                  CupertinoIcons.search,
                  size: 28,
                  color: Color(0xFF71717A),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No matching results',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                focusedBuilding != null
                    ? 'No results found in "$focusedBuilding". Tap "Show All" to search across all campus buildings.'
                    : 'Check your spelling or search for another room, lab, stairs, or building.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: const Color(0xFF71717A),
                  height: 1.4,
                ),
              ),
              if (focusedBuilding != null) ...[
                const SizedBox(height: 18),
                CupertinoButton(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: () => _toggleBuildingFocus(null),
                  child: Text(
                    'Search All Buildings',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView(
      physics:
          const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (results.waypoints.isNotEmpty) ...[
          _buildSectionHeader('Places & Rooms', results.waypoints.length),
          for (final wp in results.waypoints) _buildWaypointTile(wp),
        ],
        if (results.buildings.isNotEmpty) ...[
          if (results.waypoints.isNotEmpty) const SizedBox(height: 12),
          _buildSectionHeader('Buildings', results.buildings.length),
          for (final b in results.buildings) _buildBuildingTile(b),
        ],
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF71717A),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
            ),
            child: Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF52525B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaypointTile(SearchWaypointInfo wp) {
    final isConnector = wp.isConnector;

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF4F4F5), width: 1),
        ),
      ),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        onPressed: () => _openWaypoint(wp),
        pressedOpacity: 0.7,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFF4F4F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE4E4E7), width: 1),
              ),
              child: Icon(
                isConnector
                    ? CupertinoIcons.square_stack_3d_up
                    : CupertinoIcons.placemark,
                size: 19,
                color: const Color(0xFF18181B),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wp.name,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: const Color(0xFFE4E4E7), width: 1),
                        ),
                        child: Text(
                          _formatFloorName(wp.floor),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF27272A),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          wp.buildingName,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFF71717A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (wp.distanceMeters != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          wp.distanceMeters! < 1000
                              ? '${wp.distanceMeters!.round()}m away'
                              : '${(wp.distanceMeters! / 1000).toStringAsFixed(1)}km',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: const Color(0xFF52525B),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SavePlaceButton(
              place: SavedPlace.forPlace(
                wp.buildingName,
                wp.floor,
                wp.name,
                mapKey: wp.mapKey,
              ),
              iconSize: 18,
            ),
            const SizedBox(width: 4),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: Color(0xFFA1A1AA),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBuildingTile(BuildingSearchInfo b) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF4F4F5), width: 1),
        ),
      ),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        onPressed: () => _openBuilding(b),
        pressedOpacity: 0.7,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                CupertinoIcons.building_2_fill,
                size: 19,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.name,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _buildingSubtitle(b),
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
            const SizedBox(width: 8),
            SavePlaceButton(
              place: SavedPlace.forBuilding(
                b.name,
                mapKey: b.primaryMapKey,
              ),
              iconSize: 18,
            ),
            const SizedBox(width: 4),
            const Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: Color(0xFFA1A1AA),
            ),
          ],
        ),
      ),
    );
  }

  /// Single combined line: distance first, then OSM place name, then floors.
  String _buildingSubtitle(BuildingSearchInfo b) {
    final parts = <String>[];
    if (b.distanceFormatted.isNotEmpty) parts.add(b.distanceFormatted);
    final place = b.placeName?.trim();
    if (place != null && place.isNotEmpty) parts.add(place);
    parts.add(b.floorSummary);
    return parts.join(' · ');
  }

  Widget _buildSkeletonView() {
    return _Pulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Location context bar skeleton
          ColoredBox(
            color: Color(0xFFFAFAFA),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _SkeletonBox(width: 22, height: 22, radius: 11),
                      SizedBox(width: 8),
                      _SkeletonBox(width: 170, height: 12, radius: 6),
                    ],
                  ),
                  SizedBox(height: 10),
                  Row(
                    children: [
                      _SkeletonBox(width: 44, height: 11, radius: 5),
                      SizedBox(width: 8),
                      _SkeletonBox(width: 80, height: 24, radius: 12),
                      SizedBox(width: 6),
                      _SkeletonBox(width: 110, height: 24, radius: 12),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Category chips skeleton
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                _SkeletonBox(width: 52, height: 32, radius: 16),
                SizedBox(width: 8),
                _SkeletonBox(width: 112, height: 32, radius: 16),
                SizedBox(width: 8),
                _SkeletonBox(width: 86, height: 32, radius: 16),
                SizedBox(width: 8),
                _SkeletonBox(width: 96, height: 32, radius: 16),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: Color(0xFFE4E4E7)),
          // Section header & list tile skeletons
          Expanded(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: const [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      _SkeletonBox(width: 110, height: 12, radius: 6),
                      SizedBox(width: 8),
                      _SkeletonBox(width: 22, height: 16, radius: 8),
                    ],
                  ),
                ),
                _SkeletonTile(),
                _SkeletonTile(),
                _SkeletonTile(),
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      _SkeletonBox(width: 78, height: 12, radius: 6),
                      SizedBox(width: 8),
                      _SkeletonBox(width: 22, height: 16, radius: 8),
                    ],
                  ),
                ),
                _SkeletonTile(isBuilding: true),
                _SkeletonTile(isBuilding: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  final bool isBuilding;

  const _SkeletonTile({this.isBuilding = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF4F4F5), width: 1),
        ),
      ),
      child: Row(
        children: [
          _SkeletonBox(
            width: 42,
            height: 42,
            radius: 12,
            color: isBuilding
                ? const Color(0xFFE4E4E7)
                : const Color(0xFFF4F4F5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(
                  width: isBuilding ? 160 : 130,
                  height: 14,
                  radius: 7,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (!isBuilding) ...[
                      const _SkeletonBox(width: 28, height: 16, radius: 5),
                      const SizedBox(width: 6),
                    ],
                    _SkeletonBox(
                      width: isBuilding ? 180 : 100,
                      height: 11,
                      radius: 5,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const _SkeletonBox(width: 20, height: 20, radius: 10),
          const SizedBox(width: 8),
          const _SkeletonBox(width: 12, height: 14, radius: 4),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final Color? color;

  const _SkeletonBox({
    required this.width,
    required this.height,
    this.radius = 6,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color ?? const Color(0xFFF4F4F5),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  final Widget child;

  const _Pulse({required this.child});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _opacity = Tween<double>(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    if (!WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
      _controller.repeat(reverse: true);
    } else {
      _controller.value = 0.8;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

