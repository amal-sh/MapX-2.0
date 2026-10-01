# AGENTS.md — MapX 2.0

AR indoor navigation (PDR + map-matched trajectories + floor-anchored AR HUD). Flutter + Firebase (`mapx-007`). No auth yet — Firestore calls fail soft (return null/0) when Firebase is uninitialized.

## Commands

- `flutter pub get` — install deps (SDK `^3.11.1`, Flutter 3.47 / Dart 3.13 verified).
- `flutter analyze` — lint (uses `package:flutter_lints/flutter.yaml`; `android/ ios/ web/ windows/ macos/ linux/ build/` excluded).
- `flutter test` — full suite (~11 files in `test/`).
- `flutter test test/<name>_test.dart` — single suite, e.g. `flutter test test/floor_route_planner_test.dart`.
- `flutter run` — AR flows need a physical Android device with ARCore `SUPPORTED_INSTALLED`; emulator shows unsupported dialog by design.
- `firebase deploy --only firestore:rules` — deploys `firestore.rules`. `firebase.json` also wires `flutterfire configure` output to `lib/firebase_options.dart` + `android/app/google-services.json`.

## Architecture

- Entrypoint: `lib/main.dart` → `DashboardScreen` (local map list, cloud sync, ARCore availability check).
- `lib/screens/` — `dashboard_screen.dart`, `mapping_screen.dart` (walk-recording), `map_viewer_screen.dart` (2D preview + AR nav), `map_editor_screen.dart`, `search_screen.dart`.
- `lib/logic/` — PDR/tracking core: `live_position_tracker.dart`, `floor_graph.dart`, `floor_route_planner.dart`, `floor_transition_manager.dart`, `coordinate_transform.dart`, `spatial_sensor_fusion.dart`, `wall_collision_validator.dart`, `route_instructions.dart`, `route_segment_manager.dart`, `relocalization_manager.dart`, `depth_occlusion_manager.dart`.
- `lib/models/` — `map_models.dart` (`PathNode`, `RawStep`, `PathSegment`, `Waypoint`), `floor_map_data.dart`, `search_models.dart`.
- `lib/services/` — `firestore_service.dart`, `location_service.dart`, `search_service.dart`.
- `lib/widgets/` — `path_map_painter.dart` (2D canvas), `navigation/` (AR HUD overlays, mini-map, off-path prompts), `marker_dialog.dart`.
- Native: `android/app/src/main/kotlin/com/example/mapx/MainActivity.kt` — game-rotation-vector + compass fusion, step detection, ARCore floor hit-test, exposed over `MethodChannel('mapx/arcore')`. Handle `MissingPluginException` (tests/desktop) — see `dashboard_screen.dart:_checkArCoreSupport`.
- Full architecture + phased roadmap (graph stitching, multi-floor, offline Hive/SQLite): `MapX_2.0_Implementation_Plan.md`. Trust `lib/` + `pubspec.yaml` over the plan when they conflict.

## Data & persistence

- Local: `SharedPreferences`, key = `map_<building>#<floor>`, JSON-encoded map payload.
- Cloud: top-level `maps/{mapKey}` + `buildings/{name}/floors/{floor}` (dual-write in `FirestoreService.saveMap`); `buildings/{name}` holds `floors[]`, GPS, timestamps. `syncFromFirestore` only pulls keys missing locally and strips `updatedAt`/`createdAt` before caching.
- `firestore.rules` is currently open (`allow read, write: if true`). The RBAC schema in the Implementation Plan §4.3 is **not deployed** — do not claim it is enforced.

## Design system — monochrome minimal (required)

Follow this on every new/edited screen. Source of truth is the `ThemeData` in `lib/main.dart`; do not introduce ad-hoc colors.

- Palette: black `Colors.black` / white `Colors.white` only, plus zinc neutrals: `0xFF27272A` (secondary), `0xFF18181B` (body), `0xFF52525B` / `0xFF71717A` (muted), `0xFFA1A1AA` (hint/disabled text), borders `0xFFE4E4E7`, fills `0xFFF4F4F5` / `0xFFFAFAFA`. Radius 12–18, borders 1px `0xFFE4E4E7`, elevation 0 (cards/buttons/dialogs), FAB black-on-white rounded-16.
- Exceptions only: `Colors.red` for destructive `Delete`/`Discard` text, `Colors.white70` on AR camera overlays. The one green dot (`0xFF16A34A` in `dashboard_screen.dart`) is legacy — do not copy it.
- Typography: `GoogleFonts.interTextTheme` sizes/weights defined in `main.dart` (700 headings, 600 labels/titles, 400 body). Use `Theme.of(context).textTheme`, never raw `TextStyle` with a new font.
- Icons: `CupertinoIcons` everywhere (`flutter/cupertino.dart` + `cupertino_icons`). `Icons.stairs_outlined` / `Icons.elevator_outlined` in `marker_dialog.dart` are tolerated only because Cupertino has no equivalent — same rule for new icons. Never bulk-replace with `Icons.*`.
- Screens already following this: dashboard, mapping, search. Match their card/border/padding patterns; put shared styling in the `main.dart` theme, not per-widget literals.
- Assets: `assets/images/transp_banner.png`, `assets/animations/` (Lottie). Launcher icon source: `assets/images/mapx2_icon.png` via `flutter_launcher_icons`.

## Conventions & gotchas

- `FirestoreService`/`LocationService` are singletons swallowing errors to `debugPrint` — check return values, don't assume throws.
- `DashboardScreen._MapEntry`: a "building" is all entries sharing a name; `floor` is nullable for legacy maps.
- Tests are pure-Dart logic tests (planner, tracker, search, transforms); AR/native paths are mocked or skipped via `MissingPluginException`. Don't add widget tests requiring ARCore.
- `pubspec.yaml` declares `flutter_launcher_icons` + `lottie`/`google_fonts`/`geolocator` — plan-doc deps (`hive`, `firebase_auth`, `permission_handler`, `mockito`) are **not installed**; add a dependency only if the task needs it.
