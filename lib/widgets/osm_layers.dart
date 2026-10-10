import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';

/// CARTO monochrome basemap (OSM data) in `light_all` or `dark_all`.
/// Both keep building footprints and streets readable while staying
/// grayscale to match the app's monochrome-minimal theme. (`voyager`
/// was trialled but the key returns fetch errors for that style, so
/// we're on the `*_all` styles.)
///
/// CARTO requires an API key (free up to 5M tile requests/month from
/// carto.com/basemaps/apikey). Put it in the gitignored `.env` file:
/// `CARTO_API_KEY=your_key_here` (see `.env.example`).
/// `--dart-define=CARTO_API_KEY=...` still works as a CI override.
String get _cartoApiKey {
  const defined = String.fromEnvironment('CARTO_API_KEY', defaultValue: '');
  if (defined.isNotEmpty) return defined;
  try {
    return dotenv.env['CARTO_API_KEY'] ?? '';
  } catch (_) {
    // dotenv not initialized (e.g. widget tests): anonymous CARTO usage.
    return '';
  }
}

TileLayer osmTileLayer({bool dark = false}) => TileLayer(
      urlTemplate:
          'https://{s}.basemaps.cartocdn.com/${dark ? 'dark_all' : 'light_all'}/{z}/{x}/{y}{r}.png?key=$_cartoApiKey',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.example.mapx2',
      maxNativeZoom: 20,
    );

/// Outdoor basemap styles: CARTO monochrome `dark_all` / `light_all`
/// plus the standard (full-color) OpenStreetMap tiles.
enum BasemapTheme { dark, light, standard }

/// Basemap tile layer for [theme]. `standard` uses the OSM tile servers
/// directly (no CARTO key needed); dark/light use the CARTO `*_all` styles.
TileLayer basemapTileLayer(BasemapTheme theme) {
  switch (theme) {
    case BasemapTheme.standard:
      return TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.example.mapx2',
        maxNativeZoom: 19,
      );
    case BasemapTheme.light:
      return osmTileLayer(dark: false);
    case BasemapTheme.dark:
      return osmTileLayer(dark: true);
  }
}

/// Attribution matching [basemapTileLayer]: standard OSM credits only the
/// OSM contributors, while the CARTO styles additionally credit CARTO.
Widget basemapAttribution(BasemapTheme theme) {
  if (theme == BasemapTheme.standard) {
    return RichAttributionWidget(
      showFlutterMapAttribution: false,
      popupBackgroundColor: Colors.white,
      attributions: [
        TextSourceAttribution(
          'OpenStreetMap contributors',
          prependCopyright: true,
        ),
      ],
    );
  }
  return osmAttribution();
}

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

/// The live "you are here" dot. Inverts with the basemap theme so it
/// always reads: black dot on light, white dot on dark — with a soft
/// white radial halo around it on dark so it glows on `dark_all`.
Widget userLocationDot({bool dark = false}) {
  final dot = Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: dark ? Colors.white : Colors.black,
      shape: BoxShape.circle,
      border: Border.all(
          color: dark ? const Color(0xFF18181B) : Colors.white, width: 3),
      boxShadow: const [
        BoxShadow(
            color: Color(0x8827272A), blurRadius: 10, spreadRadius: 2)
      ],
    ),
  );
  if (!dark) return dot;
  return SizedBox(
    width: 72,
    height: 72,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Color(0x2EFFFFFF), Color(0x00FFFFFF)],
              stops: [0.35, 1.0],
            ),
          ),
        ),
        dot,
      ],
    ),
  );
}
