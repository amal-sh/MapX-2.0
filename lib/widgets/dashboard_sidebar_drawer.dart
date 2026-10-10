import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/admin_studio_screen.dart';
import '../screens/campus_map_screen.dart';
import '../screens/search_screen.dart';

/// Navigation sidebar drawer matching Image 2.
class DashboardSidebarDrawer extends StatelessWidget {
  final bool isAdminMode;
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
    this.onOpenAdminStudio,
    this.onOpenCampusOverview,
    this.onOpenSavedPlaces,
    this.onOpenRecentTrips,
    this.onOpenPreferences,
    this.onOpenDiagnostics,
    this.onOpenHelp,
  });

  void _handleCampusOverview(BuildContext context) {
    if (onOpenCampusOverview != null) {
      onOpenCampusOverview!();
    } else {
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CampusMapScreen()),
      );
    }
  }

  void _handleSavedPlaces(BuildContext context) {
    if (onOpenSavedPlaces != null) {
      onOpenSavedPlaces!();
    } else {
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchScreen()),
      );
    }
  }

  void _handleRecentTrips(BuildContext context) {
    if (onOpenRecentTrips != null) {
      onOpenRecentTrips!();
    } else {
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SearchScreen()),
      );
    }
  }

  void _handlePreferences(BuildContext context) {
    if (onOpenPreferences != null) {
      onOpenPreferences!();
    } else {
      Navigator.pop(context);
      _showDefaultPreferencesSheet(context);
    }
  }

  void _handleDiagnostics(BuildContext context) {
    if (onOpenDiagnostics != null) {
      onOpenDiagnostics!();
    } else {
      Navigator.pop(context);
      _showDefaultDiagnosticsDialog(context);
    }
  }

  void _handleHelp(BuildContext context) {
    if (onOpenHelp != null) {
      onOpenHelp!();
    } else {
      Navigator.pop(context);
      _showDefaultHelpDialog(context);
    }
  }

  void _showDefaultPreferencesSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
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
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.gauge, color: Colors.black),
                title: Text(
                  'Units of Distance',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: Text(
                  'Meters (m)',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: const Color(0xFF71717A),
                  ),
                ),
              ),
              const Divider(color: Color(0xFFE4E4E7)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(CupertinoIcons.map, color: Colors.black),
                title: Text(
                  'Default Map Theme',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: Text(
                  'Monochrome Minimal',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: const Color(0xFF71717A),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDefaultDiagnosticsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
            _diagRow('ARCore Support', 'Installed & Ready'),
            const SizedBox(height: 10),
            _diagRow('Pedestrian Dead Reckoning', 'Active (Step + Heading)'),
            const SizedBox(height: 10),
            _diagRow('GPS Alignment', 'Acquired (Live)'),
            const SizedBox(height: 10),
            _diagRow('Compass Heading', 'Calibrated (IMU + Game Rotation)'),
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
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            color: const Color(0xFF71717A),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF18181B),
          ),
        ),
      ],
    );
  }

  void _showDefaultHelpDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'MapX Help & Feedback',
          style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700),
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
                        'v2.0 • Indoor AR Engine',
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
                onTap: () => _handleCampusOverview(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                onTap: () => _handleSavedPlaces(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F4F5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '4',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF52525B),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(CupertinoIcons.chevron_right,
                          size: 14, color: Color(0xFF71717A)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // Recent Trips
              GestureDetector(
                onTap: () => _handleRecentTrips(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
                      Text(
                        'Lab 302B',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF71717A),
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
                  if (onOpenAdminStudio != null) {
                    onOpenAdminStudio!();
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
                              color: isAdminMode
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
              const Divider(height: 24, thickness: 1, color: Color(0xFFF4F4F5)),

              // Preferences
              GestureDetector(
                onTap: () => _handlePreferences(context),
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
                onTap: () => _handleDiagnostics(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.antenna_radiowaves_left_right,
                          size: 18, color: Color(0xFF52525B)),
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
                onTap: () => _handleHelp(context),
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
