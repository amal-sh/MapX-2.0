# MapX — Implementation Plan
**AR Indoor Navigation System | Dept. of IT, School of Engineering, CUSAT**  
**Architecture, PDR-AR Pipeline & Firebase Cloud Integration**

---

## 1. Executive Summary & Core Paradigm

MapX is an advanced indoor navigation system designed for complex institutional environments (such as university departments, academic blocks, and campus facilities). It combines **Pedestrian Dead Reckoning (PDR)**, **map-matched step trajectories**, and **floor-anchored Augmented Reality (AR)** to provide reliable, drift-free guidance without requiring expensive external beacon infrastructure.

### 1.1 Core Navigation Principles
- **Continuous Step Trajectories:** Corridors and pathways are recorded as continuous step segments (`PathSegment`, `RawStep`) linked to designated physical points of interest (`Waypoint`).
- **Dual-Sensor Orientation Fusion:** Uses Android's `TYPE_GAME_ROTATION_VECTOR` (gyroscope and accelerometer) for smooth, jitter-free rotation deltas with zero magnetic interference, paired with a slow complementary filter referencing `TYPE_ROTATION_VECTOR` (compass) for true north alignment.
- **Cadence-Filtered Step Detection:** Step counting relies on accelerometer oscillation with baseline gravity calibration and consecutive-peak interval validation, preventing incidental hand movements from triggering false steps.
- **Map-Matched Arc-Length Tracking:** The user's live position is projected directly onto the recorded corridor polyline arc-length, mathematically eliminating lateral drift in featureless institutional corridors.
- **Floor-Anchored AR HUD:** Projects the navigation ribbon onto the live camera feed using a pinhole perspective model calibrated in real-time by ARCore horizontal plane floor height detection (`floorHeight`, `cameraFovY`).

---

## 2. Current Codebase Status Audit

| Component | Status | Codebase Location | Description |
|---|---|---|---|
| **Native Sensor Pipeline** | Completed | `android/app/src/main/kotlin/com/example/mapx/MainActivity.kt` | Complementary orientation filter, motion level estimation, ARCore horizontal floor plane hit-testing, and EventChannel streaming. |
| **Data Models** | Completed | `lib/models/map_models.dart` | `PathNode`, `RawStep`, `PathSegment`, and `Waypoint` models with JSON serialization. |
| **PDR Tracking Engine** | Completed | `lib/logic/live_position_tracker.dart` | Map-matching step progression along route distance with circular heading smoothing. |
| **Mapping Tool** | Completed | `lib/screens/mapping_screen.dart` | Walk-recording interface with real-time sensor feedback, waypoint marker placement, and local save. |
| **Map Viewer & Navigation** | Completed | `lib/screens/map_viewer_screen.dart` | 2D canvas preview, route selection (Start to Destination), and live AR navigation mode. |
| **2D Top-Down Renderer** | Completed | `lib/widgets/path_map_painter.dart` | CustomPainter rendering grid lines, recorded path geometry, waypoints, and user position dot. |
| **Floor-Anchored AR HUD** | Completed | `lib/widgets/navigation/ar_path_painter.dart`, `ar_world_scanner_overlay.dart` | 3D perspective path ribbon projection, compass HUD, and ARCore floor tracking indicators. |
| **Local Dashboard** | Completed | `lib/screens/dashboard_screen.dart` | Lists locally recorded maps stored in device `SharedPreferences`. |
| **Cloud & Multi-Floor Layer** | In Progress | Scheduled in this plan | Firebase Authentication, Cloud Firestore synchronization, multi-floor transitions, and offline caching. |

---

## 3. System Architecture

```
+---------------------------------------------------------------+
|                       PRESENTATION LAYER                      |
|  +--------------------+ +-------------------+ +-------------+ |
|  |    Admin Portal    | | Visitor / Student | |   AR HUD    | |
|  | (Walk, Map, POIs)  | | (Search & Browse) | | (Floor AR)  | |
|  +--------------------+ +-------------------+ +-------------+ |
+---------------------------------------------------------------+
                                |
+---------------------------------------------------------------+
|                   CORE LOGIC & TRACKING ENGINE                |
|  +--------------------+ +-------------------+ +-------------+ |
|  | LivePositionTracker| | Graph Router (A*) | | Multi-Floor | |
|  |   (PDR Engine)     | | (Inter-Trajectory)| | Transitions | |
|  +--------------------+ +-------------------+ +-------------+ |
+---------------------------------------------------------------+
                                |
+---------------------------------------------------------------+
|                 DATA REPOSITORY & CLOUD LAYER                 |
|             +-----------------------------------+             |
|             |      SyncManager / Repository     |             |
|             +-----------------+-----------------+             |
|                               |                               |
|               +---------------+---------------+               |
|               |                               |               |
|               v                               v               |
|  +-------------------------+    +--------------------------+  |
|  |   Local Storage Cache   |    | Firebase Cloud Services  |  |
|  | - SQLite / Hive DB      |    | - Cloud Firestore        |  |
|  | - Offline Route Cache   |    | - Firebase Auth          |  |
|  | - Fast instant access   |    | - Firebase Storage       |  |
|  +-------------------------+    | - Cloud Messaging (FCM)  |  |
|                                 +--------------------------+  |
+---------------------------------------------------------------+
```

---

## 4. Firebase & Cloud Integration

### 4.1 Firebase Services
- **Firebase Authentication:** Role-Based Access Control (RBAC). Anonymous guest sign-in for visitors/students; Google or Email login for verified staff/admins.
- **Cloud Firestore:** Primary cloud database for multi-campus, multi-building, multi-floor trajectory networks and points of interest.
- **Firebase Storage:** Cloud storage for architectural 2D floor plans, 3D waypoint indicators, and doorplate ground-truth photos.
- **Firebase Cloud Messaging (FCM):** Real-time safety broadcasts, dynamic route detours, and corridor maintenance notices.
- **Firebase Crashlytics & Performance:** Sensor health monitoring, frame rate profiling, and battery consumption tracking.

---

### 4.2 Cloud Firestore Database Schema

The database follows a hierarchical structure to accommodate campus-wide deployments:

```
campuses/{campusId}
|-- name: "CUSAT Main Campus"
|-- location: GeoPoint(10.0435, 76.3245)
`-- buildings/{buildingId}
    |-- name: "Department of Information Technology"
    |-- code: "SOE-IT"
    |-- totalFloors: 3
    `-- floors/{floorId}
        |-- level: 1                            // 0 = Ground, 1 = First Floor
        |-- name: "First Floor"
        |-- blueprintUrl: "gs://.../floor1.svg" // 2D schematic overlay
        |-- altitudeMeters: 3.8
        |-- originAnchor: { lat, lng, bearing }
        |
        |-- trajectories/{trajectoryId}        // Continuous recorded walks
        |   |-- name: "North Corridor Main"
        |   |-- totalSteps: 142
        |   |-- totalDistanceMeters: 71.0
        |   |-- recordedBy: "admin_uid_123"
        |   |-- createdAt: Timestamp
        |   |-- segments: [
        |   |     {
        |   |       steps: [
        |   |         { heading: 42.5, length: 0.5 },
        |   |         { heading: 43.1, length: 0.5 }
        |   |       ]
        |   |     }
        |   |   ]
        |   `-- nodes: [                       // Cartesian path coordinates
        |         { index: 0, heading: 42.5, east: 0.0, north: 0.0 },
        |         { index: 1, heading: 43.1, east: 0.33, north: 0.37 }
        |       ]
        |
        |-- waypoints/{waypointId}             // POIs, Rooms, Facilities
        |   |-- label: "Software Engineering Lab"
        |   |-- category: "lab"                // room, lab, washroom, exit, etc.
        |   |-- trajectoryId: "traj_north_01"
        |   |-- stepIndex: 38
        |   |-- coordinates: { east: 12.4, north: 14.1 }
        |   |-- aliases: ["SE Lab", "Lab 2"]
        |   |-- isAccessible: true
        |   `-- photoUrl: "gs://.../door.jpg"
        |
        `-- transitions/{transitionId}         // Stairs and Elevators
            |-- type: "stairs"                 // "stairs" | "elevator" | "ramp"
            |-- name: "East Stairwell"
            |-- fromFloorId: "fl_1"
            |-- toFloorId: "fl_2"
            |-- localWaypointId: "wp_stairs_fl1"
            `-- targetWaypointId: "wp_stairs_fl2"
```

---

### 4.3 Security Rules & Permissions

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    function isAdmin() {
      return request.auth != null && request.auth.token.role == 'admin';
    }

    // Public / Visitors can read any map data for navigation
    // Only authenticated Admins can create, modify, or delete maps
    match /campuses/{campusId} {
      allow read: if true;
      allow write: if isAdmin();
      
      match /buildings/{buildingId} {
        allow read: if true;
        allow write: if isAdmin();

        match /floors/{floorId} {
          allow read: if true;
          allow write: if isAdmin();
          
          match /{document=**} {
            allow read: if true;
            allow write: if isAdmin();
          }
        }
      }
    }

    match /alerts/{alertId} {
      allow read: if true;
      allow write: if isAdmin();
    }
  }
}
```

---

### 4.4 Offline-First Synchronization Architecture
Campus buildings often contain thick concrete walls and basements with zero cellular coverage. Navigation must remain completely functional under total network loss.

1. **One-Tap Building Download:** When a user opens a building, the complete multi-floor trajectory network and waypoint catalog are downloaded and stored in a high-speed local database (Hive/SQLite).
2. **Checksum Verification:** Before redownloading, the client checks the building's `updatedAt` timestamp against the local version. If unchanged, zero network traffic is incurred.
3. **Repository Abstraction:** The navigation and tracking engines interact solely with a generic `MapRepository` interface, remaining agnostic to whether data originates from local storage or Firestore.

---

## 5. Multi-Trajectory Graph Routing & Multi-Floor Navigation

### 5.1 Inter-Trajectory Graph Stitching
To navigate an entire facility, multiple separately recorded walks must form a unified routing graph:
1. **Intersection Points:** When an administrator walks a new path that crosses an existing route, a shared `Waypoint` (e.g. "North Corridor Intersection") is created at the crossing point.
2. **Topological Merging:** The routing engine links the overlapping trajectory segments at that vertex with zero transition penalty.
3. **A* Pathfinding:** Finds the optimal route between any room and any destination across multiple stitched walks.

```
[Room 101] ---> (Route 1) ---> [Junction A] ---> (Route 2) ---> [East Stairs]
                                                                     | (Floor Handoff)
                                                                     v
[Lab 204]  <--- (Route 4) <--- [Junction B] <--- (Route 3) <---------'
```

### 5.2 Multi-Floor Transitions (Stairs & Elevators)
1. **Approach Notification:** When the user comes within 3 meters of a transition waypoint, the AR HUD displays an instruction card: *"Take East Stairs to Floor 2"*.
2. **Handoff State Machine:**
   - User ascends stairs; tracking pauses or monitors step cadence.
   - Upon arriving on Floor 2, the user taps *"Arrived at Floor 2"* (or floor is confirmed via transition waypoint).
   - The active floor trajectory updates to Floor 2 at the target transition waypoint.
   - ARCore re-acquires the floor plane and resumes arrow guidance toward the final destination.

---

## 6. Phased Implementation Roadmap

```
Phase 1: Data Model Architecture & Local Repository
   |
   v
Phase 2: Firebase Integration & Authentication
   |
   v
Phase 3: Offline Caching & Synchronization Manager
   |
   v
Phase 4: Inter-Trajectory Graph Stitching & Routing (A*)
   |
   v
Phase 5: Multi-Floor Transition System (Stairs/Lifts)
   |
   v
Phase 6: Admin Cloud Studio (Mapping & POI Management)
   |
   v
Phase 7: Performance Optimization & Campus Deployment
```

---

### Detailed Phase Specifications

#### Phase 1 — Data Model Architecture & Local Repository
- Refactor `lib/models/map_models.dart` to incorporate `Campus`, `Building`, `Floor`, `CloudTrajectory`, and `FloorTransition`.
- Add Douglas-Peucker polyline simplification to compress trajectory storage footprint for cloud transfer.
- Define `MapRepository` abstract contract to decouple storage implementations from navigation logic.
- Implement a structured local database repository (Hive/SQLite) replacing flat `SharedPreferences`.

#### Phase 2 — Firebase Integration & Authentication
- Integrate `firebase_core`, `cloud_firestore`, `firebase_auth`, and `firebase_storage`.
- Build `AuthService` with Anonymous sign-in for visitors and Google/Email sign-in for campus administrators.
- Implement `FirestoreMapRepository` conforming to `MapRepository`.
- Deploy Firestore security rules and index definitions.

#### Phase 3 — Offline Caching & Synchronization Manager
- Create `SyncManager` handling building bundle downloads, version checksums, and local persistence.
- Update `DashboardScreen` to display cloud campuses/buildings, offline availability badges, and manual sync buttons.
- Implement automatic fallback to local cache during connectivity loss.

#### Phase 4 — Inter-Trajectory Graph Stitching & Routing (A*)
- Implement `GraphStitcher` to assemble independent recorded trajectories into a connected navigation graph.
- Implement Multi-Route A* Pathfinder capable of finding shortest paths across intersected walks.
- Upgrade `LivePositionTracker` to guide walkers continuously across multi-segment composite routes.

#### Phase 5 — Multi-Floor Transition System
- Implement `FloorTransitionManager` to coordinate vertical transitions between floor graphs.
- Add floor handoff guidance cards to the AR HUD (*"Take Stairs to Floor 2"*).
- Include an accessibility preference option (*"Avoid Stairs / Elevator Only"*).

#### Phase 6 — Admin Cloud Studio
- Upgrade `MappingScreen` to support selecting Campus, Building, and Floor before mapping.
- Add real-time POI category labeling (Classrooms, Labs, Restrooms, Exits, Elevators).
- Provide a one-tap "Publish to Cloud" button to synchronize newly mapped routes directly to Firestore.
- Add a 2D graph editor to review, rename, or prune waypoints on the canvas.

#### Phase 7 — Performance Optimization & Campus Deployment
- **Thermal & Battery Optimization:** Profile continuous 30+ minute navigation sessions on mid-range Android devices.
- **Sensor Robustness:** Validate complementary filter stability near electromagnetic fields (elevator shafts, electrical rooms).
- **Field Pilot:** Complete full-building mapping and navigation trials across the CUSAT IT block.
- **Testing:** Automated unit, repository, and routing tests with high test coverage.

---

## 7. Technical Dependencies Roadmap

```yaml
dependencies:
  flutter:
    sdk: flutter

  # UI & Styling
  cupertino_icons: ^1.0.8
  google_fonts: ^6.2.1

  # Local Persistence & Offline Caching
  shared_preferences: ^2.5.5
  hive_flutter: ^1.1.0

  # Firebase Ecosystem
  firebase_core: ^3.12.0
  firebase_auth: ^5.5.0
  cloud_firestore: ^5.6.4
  firebase_storage: ^12.4.3
  firebase_crashlytics: ^4.3.3

  # Hardware & Permissions
  permission_handler: ^11.4.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  mockito: ^5.4.5
  build_runner: ^2.4.15
```

---

## 8. Deliverables & Milestones Matrix

| Milestone | Target Deliverable | Success Criteria |
|---|---|---|
| **M1: Data Models & Local Repo** | Unified multi-floor models + local Hive storage | 100% serialization test coverage; fast local read/write. |
| **M2: Firebase Integration** | Firestore schema + Firebase Auth RBAC | Admin can upload mapped routes; visitors can stream data without logging in. |
| **M3: Offline Engine** | Offline `SyncManager` with local caching | App navigates with Airplane Mode turned ON identically to online mode. |
| **M4: Graph Stitching** | Inter-trajectory A* pathfinding | Shortest path calculated across two separately recorded intersecting walks. |
| **M5: Multi-Floor Transition** | Floor handoff at stairs & elevators | Automatic guidance prompt at stairwell; seamless switch to upper floor. |
| **M6: Campus Field Trial** | Deployment of CUSAT IT block map on real student devices | Tested across multiple student devices in CUSAT IT Block with zero tracking loss. |

---
*Maintained by MapX Engineering Team.*
