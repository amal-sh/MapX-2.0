import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// OpenStreetMap's standard tiles. Free for light use (projects, demos);
/// their tile usage policy requires an identifying user agent, and a
/// published app with real traffic should switch to a tile provider.
TileLayer osmTileLayer() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.example.mapx2',
      maxNativeZoom: 19,
    );

/// Attribution OpenStreetMap requires on every map that shows its tiles.
Widget osmAttribution() => const SimpleAttributionWidget(source: Text('OpenStreetMap contributors'));

/// The live "you are here" dot.
Widget userLocationDot() => Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2563EB),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x552563EB), blurRadius: 10, spreadRadius: 4)],
      ),
    );
