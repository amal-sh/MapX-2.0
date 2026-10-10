import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/navigation_trip.dart';
import '../screens/admin_studio_screen.dart';
import '../screens/campus_map_screen.dart';
import '../screens/recent_trips_screen.dart';
import '../screens/saved_places_screen.dart';
import '../services/navigation_history_service.dart';
import '../services/saved_places_service.dart';
import '../services/user_preferences_service.dart';

/// Navigation sidebar drawer.
///
/// Saved-place counts and the latest trip are loaded from the offline
/// on-device stores ([SavedPlacesService], [NavigationHistoryService]) —
/// nothing here is hardcoded. Diagnostics are queried live from the
/// device instead of claiming fixed "ready" values.
class DashboardSidebarDrawer extends StatefulWidget {
  final bool isAdminMode;
  final String appVersion;
  final VoidCallback? onOpenAdminStudio;
  final VoidCallback? onOpenCampusOverview;
  final VoidCallback? onOpenSavedPlaces;
  final VoidCallback? onOpenRecentTrips;
  final VoidCallback? onOpenPreferences;
  final VoidCallback? onOpenDiagnostics;
  final VoidCallback? onOpenHelp;

  const DashboardSidebarDrawer({
    super.key,
    this.isAdminMode = false,
    this.appVersion = 'v2.0',
    this.onOpenAdminStudio,
    this.onOpenCampusOverview,
    this.onOpenSavedPlaces,
    this.onOpenRecentTrips,
    this.onOpenPreferences,
    this.onOpenDiagnostics,
    this.onOpenHelp,
  });

  @override
  State<DashboardSidebarDrawer> createState() => _DashboardSidebarDrawerState();
}

class _DashboardSidebarDrawerState extends State<DashboardSidebarDrawer> {
  static const _arChannel = MethodChannel('mapx/arcore');

  int _savedCount = 0;
  NavigationTrip? _latestTrip;
  String _arCoreStatus = 'Checking…';
  String _locationStatus = 'Checking…';

  @override
  void initState() {
    super.initState();
    _reloadOfflineData();
    _loadDiagnostics();
  }

  Future<void> _reloadOfflineData() async {
    final saved = await SavedPlacesService.instance.load();
    final latest = await NavigationHistoryService.instance.latest();
    if (!mounted) return;
    setState(() {
      _savedCount = saved.length;
      _latestTrip = latest;
    });
  }

  Future<void> _loadDiagnostics() async {
    String arCore;
    try {
      final availability =
          await _arChannel.invokeMethod<String>('checkAvailability');
      arCore = availability == 'SUPPORTED_INSTALLED'
          ? 'Installed & Ready'
          : (availability == null || availability.isEmpty
              ? 'Not available'
              : availability);
    } on MissingPluginException {
      arCore = 'Unavailable in preview';
    } catch (_) {
      arCore = 'Not available';
    }

    String location;
    try {
      final permission = await Geolocator.checkPermission();
      location =
          (permission == LocationPermission.always ||
                  permission == LocationPermission.whileInUse)
              ? 'Granted (live)'
              : 'Not granted';
    } catch (_) {
      location = 'Unknown';
    }

    if (!mounted) return;
    setState(() {
      _arCoreStatus = arCore;
      _locationStatus = location;
    });
  }

  Future<void> _pushAndRefresh(Widget page) async {
    Navigator.pop(context);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    await _reloadOfflineData();
  }

  void _handleCampusOverview() {
    if (widget.onOpenCampusOverview != null) {
      widget.onOpenCampusOverview!();
    } else {
      _pushAndRefresh(const CampusMapScreen());
    }
  }

  void _handleSavedPlaces() {
    if (widget.onOpenSavedPlaces != null) {
      widget.onOpenSavedPlaces!();
    } else {
      _pushAndRefresh(const SavedPlacesScreen());
    }
  }

  void _handleRecentTrips() {
    if (widget.onOpenRecentTrips != null) {
      widget.onOpenRecentTrips!();
    } else {
      _pushAndRefresh(const RecentTripsScreen());
    }
  }

  void _handlePreferences() {
    if (widget.onOpenPreferences != null) {
      widget.onOpenPreferences!();
    } else {
      Navigator.pop(context);
      _showPreferencesSheet();
    }
  }

  void _handleDiagnostics() {
    if (widget.onOpenDiagnostics != null) {
      widget.onOpenDiagnostics!();
    } else {
      Navigator.pop(context);
      _showDiagnosticsDialog();
    }
  }

  void _handleHelp() {
    if (widget.onOpenHelp != null) {
      widget.onOpenHelp!();
    } else {
      Navigator.pop(context);
      _showHelpDialog();
    }
  }

  Future<void> _showPreferencesSheet() {
    final prefs = UserPreferencesService.instance;
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FutureBuilder<List<String>>(
        future: Future.wait(
            [prefs.loadDistanceUnits(), prefs.loadMapTheme()]),
        builder: (context, snapshot) {
          var units = UserPreferencesService.unitsMeters;
          var theme = UserPreferencesService.themeMonochrome;
          if (snapshot.hasData) {
            units = snapshot.data![0];
            theme = snapshot.data![1];
          }
          return StatefulBuilder(
            builder: (context, setSheetState) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Preferences',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Stored on this device only.',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF71717A),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Units of Distance',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF71717A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: UserPreferencesService.unitsMeters,
                            label: Text('Meters')),
                        ButtonSegment(
                            value: UserPreferencesService.unitsFeet,
                            label: Text('Feet')),
                      ],
                      selected: {units},
                      showSelectedIcon: false,
                      onSelectionChanged: (selected) async {
                        await prefs.saveDistanceUnits(selected.first);
                        setSheetState(() => units = selected.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Default Map Theme',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF71717A),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value:
                                UserPreferencesService.themeMonochrome,
                            label: Text('Monochrome')),
                        ButtonSegment(
                            value: UserPreferencesService.themeSystem,
                            label: Text('System')),
                      ],
                      selected: {theme},
                      showSelectedIcon: false,
                      onSelectionChanged: (selected) async {
                        await prefs.saveMapTheme(selected.first);
                        setSheetState(() => theme = selected.first);
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDiagnosticsDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(CupertinoIcons.antenna_radiowaves_left_right,
                color: Colors.black, size: 22),
            const SizedBox(width: 10),
            Text(
              'ARCore Diagnostics',
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.black,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _diagRow('ARCore Support', _arCoreStatus),
            const SizedBox(height: 10),
            _diagRow('Location Permission', _locationStatus),
            const SizedBox(height: 10),
            _diagRow('Step + Heading (PDR)', 'On-device'),
            const SizedBox(height: 10),
            _diagRow('Compass Heading', 'On-device (IMU fusion)'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Close',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _diagRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: const Color(0xFF71717A),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF18181B),
            ),
          ),
        ),
      ],
    );
  }

  void _showHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'MapX Help & Feedback',
          style:
              GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'MapX provides high-precision indoor AR pedestrian navigation using sensor fusion (PDR + ARCore + building coordinate transforms).\n\n• User Mode: Tap any complex or floor to preview paths or navigate in AR.\n• Admin Mode: Open Admin Studio from the sidebar to record floor trajectories, add floor levels, and sync map data.',
          style: GoogleFonts.inter(
            fontSize: 13,
            color: const Color(0xFF52525B),
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Got it',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recentSubtitle = _latestTrip == null
        ? 'No trips yet'
        : _latestTrip!.destinationDisplay;

    return Drawer(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      width: MediaQuery.of(context).size.width * 0.82,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with MapX logo and Close X button
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Image.asset(
                        'assets/images/transp_banner.png',
                        height: 24,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${widget.appVersion} • Indoor AR Engine',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF71717A),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF4F4F5),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(CupertinoIcons.xmark,
                          size: 15, color: Color(0xFF18181B)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // EXPLORE Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'EXPLORE',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF71717A),
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    'Spaces',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFA1A1AA),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Campus Overview (Selected pill)
              GestureDetector(
                onTap: _handleCampusOverview,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F4F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.map_fill,
                          size: 18, color: Colors.black),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Campus Overview',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const Icon(CupertinoIcons.chevron_right,
                          size: 14, color: Color(0xFF71717A)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Saved Places & Rooms
              GestureDetector(
                onTap: _handleSavedPlaces,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.bookmark,
                          size: 18, color: Color(0xFF27272A)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Saved Places & Rooms',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF18181B),
                          ),
                        ),
                      ),
                      if (_savedCount > 0) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F5),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$_savedCount',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF52525B),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Icon(CupertinoIcons.chevron_right,
                          size: 14, color: Color(0xFF71717A)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Recent Trips
              GestureDetector(
                onTap: _handleRecentTrips,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.compass,
                          size: 18, color: Color(0xFF27272A)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Recent Trips',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF18181B),
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          recentSubtitle,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF71717A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(CupertinoIcons.chevron_right,
                          size: 14, color: Color(0xFF71717A)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // MANAGEMENT Section
              Text(
                'MANAGEMENT',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF71717A),
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),

              // Admin Studio Card
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  if (widget.onOpenAdminStudio != null) {
                    widget.onOpenAdminStudio!();
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminStudioScreen()),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF27272A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'ADMIN ONLY',
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: widget.isAdminMode
                                  ? Colors.white
                                  : const Color(0xFF3F3F46),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            'Admin Studio',
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          const Icon(CupertinoIcons.arrow_right,
                              color: Colors.white, size: 18),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Floor mapping',
                        style: GoogleFonts.inter(
                          color: const Color(0xFFA1A1AA),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),
              const Divider(
                  height: 24, thickness: 1, color: Color(0xFFF4F4F5)),

              // Preferences
              GestureDetector(
                onTap: _handlePreferences,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.gear,
                          size: 18, color: Color(0xFF52525B)),
                      const SizedBox(width: 12),
                      Text(
                        'Preferences',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF27272A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ARCore Diagnostics
              GestureDetector(
                onTap: _handleDiagnostics,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(
                          CupertinoIcons.antenna_radiowaves_left_right,
                          size: 18,
                          color: Color(0xFF52525B)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'ARCore Diagnostics',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF27272A),
                          ),
                        ),
                      ),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE4E4E7),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Help & Feedback
              GestureDetector(
                onTap: _handleHelp,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.question_circle,
                          size: 18, color: Color(0xFF52525B)),
                      const SizedBox(width: 12),
                      Text(
                        'Help & Feedback',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF27272A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
