import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Standard OpenStreetMap tile URL (100% free, no API key or external service needed).
const String osmStandardUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Color matrix transforming standard OpenStreetMap raster tiles into
/// a sleek midnight-navy / cool-grey dark theme directly in flutter_map.
///
/// Palette achieved:
/// - Base / Land: #080E18 ~ #0B131E (deep midnight navy)
/// - Water / Rivers: #1C2735 ~ #202D3B (muted slate blue)
/// - Arterials: #707785 ~ #7E8592 (clean, crisp cool grey)
/// - Minor streets: #242C38 ~ #2B3340 (subtle dark slate)
const List<double> osmCustomDarkMatrix = <double>[
  -0.45, -0.05, -0.05, 0, 130, // Red
  -0.05, -0.45, -0.05, 0, 140, // Green
  -0.05, -0.05, -0.50, 0, 165, // Blue
  0, 0, 0, 1, 0, // Alpha
];

/// Matrix for monochrome-minimal light basemap: desaturates standard OSM
/// tiles into a clean grayscale palette matching the app's minimal theme.
const List<double> osmMonochromeLightMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, // Red
  0.2126, 0.7152, 0.0722, 0, 0, // Green
  0.2126, 0.7152, 0.0722, 0, 0, // Blue
  0, 0, 0, 1, 0, // Alpha
];

/// Default color matrix for dark mode.
const List<double> customDarkMapMatrix = osmCustomDarkMatrix;

/// Pure OpenStreetMap tile layer with custom GPU color-filter styling.
/// Operates 100% with standard OpenStreetMap and zero third-party basemap services.
TileLayer osmTileLayer({bool dark = false}) => TileLayer(
  urlTemplate: osmStandardUrl,
  userAgentPackageName: 'com.example.mapx2',
  maxNativeZoom: 19,
  tileBuilder: (context, tileWidget, tile) => ColorFiltered(
    colorFilter: ColorFilter.matrix(
      dark ? osmCustomDarkMatrix : osmMonochromeLightMatrix,
    ),
    child: tileWidget,
  ),
);

/// Custom midnight-navy tile layer using pure OpenStreetMap tiles
/// and flutter_map color filtering.
TileLayer customDarkTileLayer() => osmTileLayer(dark: true);

/// Outdoor basemap styles: custom midnight navy, monochrome light,
/// or standard full-color OpenStreetMap.
enum BasemapTheme { customDark, dark, light, standard }

/// Basemap tile layer for [theme]. All themes run on 100% standard OpenStreetMap.
TileLayer basemapTileLayer(BasemapTheme theme) {
  switch (theme) {
    case BasemapTheme.customDark:
    case BasemapTheme.dark:
      return osmTileLayer(dark: true);
    case BasemapTheme.light:
      return osmTileLayer(dark: false);
    case BasemapTheme.standard:
      return TileLayer(
        urlTemplate: osmStandardUrl,
        userAgentPackageName: 'com.example.mapx2',
        maxNativeZoom: 19,
      );
  }
}

/// Attribution for standard OpenStreetMap tiles.
Widget basemapAttribution(BasemapTheme theme) => osmAttribution();

/// Standard OpenStreetMap attribution required by the ODbL license.
Widget osmAttribution() => const RichAttributionWidget(
  showFlutterMapAttribution: false,
  popupBackgroundColor: Colors.white,
  attributions: [
    TextSourceAttribution('OpenStreetMap contributors', prependCopyright: true),
  ],
);

/// The live "you are here" dot. Inverts with the basemap theme so it
/// always reads: black dot on light, white dot on dark — with a soft
/// white radial halo around it on dark so it glows on dark basemaps.
///
/// Always returns a fixed 72x72 box with a centered 20px dot so the
/// visual size never depends on the parent [Marker] width/height
/// (flutter_map stretches the child to fill the marker box, which made
/// the light-theme dot balloon to 72px).
Widget userLocationDot({bool dark = false}) {
  final dot = Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: dark ? Colors.white : Colors.black,
      shape: BoxShape.circle,
      border: Border.all(
        color: dark ? const Color(0xFF18181B) : Colors.white,
        width: 3,
      ),
      boxShadow: const [
        BoxShadow(color: Color(0x8827272A), blurRadius: 10, spreadRadius: 2),
      ],
    ),
  );
  return SizedBox(
    width: 72,
    height: 72,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                dark ? const Color(0x2EFFFFFF) : const Color(0x1818181B),
                dark ? const Color(0x00FFFFFF) : const Color(0x0018181B),
              ],
              stops: const [0.35, 1.0],
            ),
          ),
        ),
        dot,
      ],
    ),
  );
}
