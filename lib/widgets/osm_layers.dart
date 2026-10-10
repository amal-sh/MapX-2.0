import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';

/// CARTO light monochrome basemap (OSM data). `light_all` keeps building
/// footprints and streets readable while staying grayscale to match the
/// app's monochrome-minimal theme. (`voyager` was trialled but the key
/// returns fetch errors for that style, so we're back on `light_all`.)
///
/// CARTO requires an API key (free up to 5M tile requests/month from
/// carto.com/basemaps/apikey). Put it in the gitignored `.env` file:
/// `CARTO_API_KEY=your_key_here` (see `.env.example`).
/// `--dart-define=CARTO_API_KEY=...` still works as a CI override.
String get _cartoApiKey {
  const defined = String.fromEnvironment('CARTO_API_KEY', defaultValue: '');
  if (defined.isNotEmpty) return defined;
  return dotenv.env['CARTO_API_KEY'] ?? '';
}

TileLayer osmTileLayer() => TileLayer(
      urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=$_cartoApiKey',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.example.mapx2',
      maxNativeZoom: 20,
    );

/// Attribution OSM (ODbL) + CARTO require on every map using these tiles.
/// Kept as a tiny ⓘ toggle instead of a permanent banner: the credits live
/// in its popup. Do not remove — the ODbL license and CARTO terms both
/// mandate this credit.
Widget osmAttribution() => const RichAttributionWidget(
      showFlutterMapAttribution: false,
      popupBackgroundColor: Colors.white,
      attributions: [
        TextSourceAttribution(
          'OpenStreetMap contributors',
          prependCopyright: true,
        ),
        TextSourceAttribution(
          'CARTO',
          prependCopyright: true,
        ),
      ],
    );

/// The live "you are here" dot (monochrome so it reads on the light basemap).
Widget userLocationDot() => Container(
      decoration: BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x8827272A), blurRadius: 10, spreadRadius: 2)],
      ),
    );
