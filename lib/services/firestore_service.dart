import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_service.dart';

class FirestoreService {
  static final FirestoreService instance = FirestoreService._();
  FirestoreService._();

  FirebaseFirestore? get _firestore {
    try {
      if (Firebase.apps.isEmpty) return null;
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  CollectionReference<Map<String, dynamic>>? get _buildingsCol =>
      _firestore?.collection('buildings');

  CollectionReference<Map<String, dynamic>>? get _mapsCol =>
      _firestore?.collection('maps');

  /// Saves or updates a building document with its GPS coordinates and metadata.
  Future<void> saveBuilding({
    required String buildingName,
    BuildingLocation? location,
    int? initialFloor,
  }) async {
    try {
      final col = _buildingsCol;
      if (col == null) return;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('building_tombstone_$buildingName');
      } catch (_) {}
      try {
        await _firestore?.collection('deleted_buildings').doc(buildingName).delete();
      } catch (_) {}

      final docRef = col.doc(buildingName);
      final doc = await docRef.get();

      final data = <String, dynamic>{
        'name': buildingName,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (location != null) {
        data['latitude'] = location.latitude;
        data['longitude'] = location.longitude;
        data['accuracy'] = location.accuracy;
        data['locationRecordedAt'] = location.timestamp.toIso8601String();
      }

      if (!doc.exists) {
        data['createdAt'] = FieldValue.serverTimestamp();
        data['floors'] = initialFloor != null ? [initialFloor] : <int>[];
        await docRef.set(data);
      } else {
        if (initialFloor != null) {
          data['floors'] = FieldValue.arrayUnion([initialFloor]);
        }
        await docRef.set(data, SetOptions(merge: true));
      }
      debugPrint('Firestore: Saved building "$buildingName" successfully.');
    } catch (e) {
      debugPrint('Firestore: Failed to save building "$buildingName": $e');
    }
  }

  /// Pushes a floor map to Firestore in both the top-level `maps` collection
  /// and the building's `floors` subcollection.
  Future<void> saveMap({
    required String mapKey,
    required String buildingName,
    required int floor,
    required Map<String, dynamic> mapData,
    BuildingLocation? location,
  }) async {
    try {
      final maps = _mapsCol;
      final buildings = _buildingsCol;
      if (maps == null || buildings == null) return;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('map_tombstone_$mapKey');
        await prefs.remove('building_tombstone_$buildingName');
      } catch (_) {}
      try {
        await _firestore?.collection('deleted_buildings').doc(buildingName).delete();
      } catch (_) {}

      final payload = Map<String, dynamic>.from(mapData);
      payload['key'] = mapKey;
      payload['name'] = buildingName;
      payload['floor'] = floor;
      payload['updatedAt'] = FieldValue.serverTimestamp();

      if (location != null) {
        payload['latitude'] = location.latitude;
        payload['longitude'] = location.longitude;
        payload['gpsAccuracy'] = location.accuracy;
      }

      // 1. Save in top-level maps collection
      await maps.doc(mapKey).set(payload, SetOptions(merge: true));

      // 2. Save in buildings/{buildingName}/floors/{floor}
      await buildings
          .doc(buildingName)
          .collection('floors')
          .doc('$floor')
          .set(payload, SetOptions(merge: true));

      // 3. Ensure building record exists and contains this floor
      await saveBuilding(
        buildingName: buildingName,
        location: location,
        initialFloor: floor,
      );

      debugPrint('Firestore: Map "$mapKey" uploaded successfully.');
    } catch (e) {
      debugPrint('Firestore: Error saving map "$mapKey": $e');
    }
  }

  /// Deletes a floor map from Firestore and updates building's floor list.
  Future<void> deleteMap({
    required String mapKey,
    required String buildingName,
    required int floor,
  }) async {
    try {
      final maps = _mapsCol;
      final buildings = _buildingsCol;
      if (maps == null || buildings == null) return;

      await maps.doc(mapKey).delete();
      await buildings
          .doc(buildingName)
          .collection('floors')
          .doc('$floor')
          .delete();

      await buildings.doc(buildingName).update({
        'floors': FieldValue.arrayRemove([floor]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('Firestore: Deleted map "$mapKey".');
    } catch (e) {
      debugPrint('Firestore: Error deleting map "$mapKey": $e');
    }
  }

  /// Updates a building doc's `floors` array after a floor renumber.
  Future<void> updateBuildingFloors({
    required String buildingName,
    int? remove,
    int? add,
  }) async {
    try {
      final col = _buildingsCol;
      if (col == null) return;
      final data = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (remove != null) data['floors'] = FieldValue.arrayRemove([remove]);
      // Two array ops can't share one update map, so apply sequentially.
      if (data.length > 1) {
        await col.doc(buildingName).update(data);
        data.remove('floors');
      }
      if (add != null) data['floors'] = FieldValue.arrayUnion([add]);
      await col.doc(buildingName).set(data, SetOptions(merge: true));
      debugPrint('Firestore: Updated floors for "$buildingName".');
    } catch (e) {
      debugPrint('Firestore: Error updating floors for "$buildingName": $e');
    }
  }

  /// Deletes an entire building: its doc, all `floors` subcollection docs,
  /// and every top-level `maps` doc belonging to it. Fail-soft when offline.
  Future<void> deleteBuilding({required String buildingName}) async {
    try {
      final maps = _mapsCol;
      final buildings = _buildingsCol;

      // 1. Record deletion in deleted_buildings for multi-device sync
      try {
        await _firestore?.collection('deleted_buildings').doc(buildingName).set({
          'deletedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      if (buildings != null) {
        final floorsSnap =
            await buildings.doc(buildingName).collection('floors').get();
        for (final doc in floorsSnap.docs) {
          await doc.reference.delete();
        }
        await buildings.doc(buildingName).delete();
      }
      if (maps != null) {
        final mapsSnap =
            await maps.where('name', isEqualTo: buildingName).get();
        for (final doc in mapsSnap.docs) {
          await doc.reference.delete();
        }
      }
      debugPrint('Firestore: Deleted building "$buildingName".');
    } catch (e) {
      debugPrint('Firestore: Error deleting building "$buildingName": $e');
    }
  }

  /// Renames a building doc (and its `floors` subcollection) to [newName].
  /// Per-floor top-level `maps` docs are migrated as well.
  Future<void> renameBuilding({
    required String oldName,
    required String newName,
    String? gpsRaw,
  }) async {
    try {
      final buildings = _buildingsCol;
      final maps = _mapsCol;

      // 1. Record rename in deleted_buildings for multi-device sync
      try {
        await _firestore?.collection('deleted_buildings').doc(oldName).set({
          'deletedAt': FieldValue.serverTimestamp(),
          'renamedTo': newName,
        });
        await _firestore?.collection('deleted_buildings').doc(newName).delete();
      } catch (_) {}

      // 2. Rename all maps in the top-level maps collection
      if (maps != null) {
        final mapsSnap = await maps.where('name', isEqualTo: oldName).get();
        for (final doc in mapsSnap.docs) {
          final data = Map<String, dynamic>.from(doc.data());
          final floor = data['floor'] ?? 0;
          final newMapKey = 'map_$newName#$floor';
          data['name'] = newName;
          data['key'] = newMapKey;
          data['updatedAt'] = FieldValue.serverTimestamp();
          await maps.doc(newMapKey).set(data, SetOptions(merge: true));
          await doc.reference.delete();
        }
      }

      // 3. Rename in buildings collection
      if (buildings != null) {
        final oldRef = buildings.doc(oldName);
        final newRef = buildings.doc(newName);
        final oldDoc = await oldRef.get();

        final base = oldDoc.exists
            ? Map<String, dynamic>.from(oldDoc.data()!)
            : <String, dynamic>{};
        base['name'] = newName;
        base['renamedFrom'] = oldName;
        base['updatedAt'] = FieldValue.serverTimestamp();
        if (base['createdAt'] == null) {
          base['createdAt'] = FieldValue.serverTimestamp();
        }
        await newRef.set(base, SetOptions(merge: true));

        final floorsSnap = await oldRef.collection('floors').get();
        for (final doc in floorsSnap.docs) {
          final data = Map<String, dynamic>.from(doc.data())..['name'] = newName;
          await newRef.collection('floors').doc(doc.id).set(data);
          await doc.reference.delete();
        }
        await oldRef.delete();
      }
      debugPrint('Firestore: Renamed building "$oldName" -> "$newName".');
    } catch (e) {
      debugPrint('Firestore: Error renaming building "$oldName": $e');
    }
  }

  /// Migrates one floor's top-level `maps` doc to a new key/building name.
  Future<void> renameFloorMap({
    required String oldMapKey,
    required String newMapKey,
    required String oldBuilding,
    required String newBuilding,
    required int floor,
  }) async {
    try {
      final maps = _mapsCol;
      final buildings = _buildingsCol;
      if (maps == null || buildings == null) return;

      final oldDoc = await maps.doc(oldMapKey).get();
      if (oldDoc.exists) {
        final data = Map<String, dynamic>.from(oldDoc.data()!)
          ..['key'] = newMapKey
          ..['name'] = newBuilding;
        await maps.doc(newMapKey).set(data);
        await oldDoc.reference.delete();
      }
      final oldFloor = await buildings
          .doc(oldBuilding)
          .collection('floors')
          .doc('$floor')
          .get();
      if (oldFloor.exists) {
        final data = Map<String, dynamic>.from(oldFloor.data()!)
          ..['key'] = newMapKey
          ..['name'] = newBuilding;
        await buildings
            .doc(newBuilding)
            .collection('floors')
            .doc('$floor')
            .set(data);
        await oldFloor.reference.delete();
      }
    } catch (e) {
      debugPrint('Firestore: Error renaming map "$oldMapKey": $e');
    }
  }

  /// Syncs remote maps from Firestore down to local SharedPreferences.
  /// Updates modified maps, removes deleted/renamed buildings, and adds new maps.
  Future<int> syncFromFirestore() async {
    try {
      final maps = _mapsCol;
      final buildings = _buildingsCol;
      if (maps == null) return 0;

      final prefs = await SharedPreferences.getInstance();

      // 1. Pull remote deleted_buildings (if any) and tombstone/clean them locally
      try {
        final delSnap = await _firestore?.collection('deleted_buildings').get();
        if (delSnap != null) {
          for (final doc in delSnap.docs) {
            final delName = doc.id.trim();
            final data = doc.data();
            final renamedTo = (data['renamedTo'] as String?)?.trim();
            await prefs.setString(
                'building_tombstone_$delName', DateTime.now().toIso8601String());

            final matchingKeys = prefs
                .getKeys()
                .where((k) =>
                    k.startsWith('map_$delName#') || k == 'map_$delName')
                .toList();
            for (final k in matchingKeys) {
              await prefs.remove(k);
            }
            await prefs.remove('building_gps_$delName');
            await prefs.remove('building_place_$delName');

            final rawReg = prefs.getString('building_registry');
            final reg = <String>{
              if (rawReg != null && rawReg.isNotEmpty)
                for (final e in (jsonDecode(rawReg) as List)) e.toString(),
            }..remove(delName);
            if (renamedTo != null && renamedTo.isNotEmpty) {
              reg.add(renamedTo);
            }
            await prefs.setString('building_registry', jsonEncode(reg.toList()));
          }
        }
      } catch (_) {}

      // Names deleted on this device: never re-pull them from the cloud.
      final tombstoned = {
        for (final k in prefs
            .getKeys()
            .where((k) => k.startsWith('building_tombstone_')))
          k.substring('building_tombstone_'.length),
      };

      final snapshot = await maps.get();
      int syncedCount = 0;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final docBuilding = (data['name'] as String?)?.trim();
        if (docBuilding != null && tombstoned.contains(docBuilding)) continue;
        final floor = (data['floor'] as int?) ?? 0;
        final key = data['key'] as String? ?? 'map_$docBuilding#$floor';
        if (prefs.containsKey('map_tombstone_$key')) continue;

        // Clean non-serializable fields if any before caching locally
        final cleanData = Map<String, dynamic>.from(data)
          ..remove('updatedAt')
          ..remove('createdAt');
        final encodedRemote = jsonEncode(cleanData);
        final localRaw = prefs.getString(key);

        if (localRaw == null) {
          await prefs.setString(key, encodedRemote);
          syncedCount++;
        } else if (localRaw != encodedRemote) {
          // Map was edited in Firestore: update local cache!
          await prefs.setString(key, encodedRemote);
          syncedCount++;
        }
      }

      // Also pull building shells so buildings with zero floors still show
      // up locally (registry + GPS cache).
      if (buildings != null) {
        final bSnap = await buildings.get();
        final rawReg = prefs.getString('building_registry');
        final registry = <String>{
          if (rawReg != null && rawReg.isNotEmpty)
            for (final e in (jsonDecode(rawReg) as List)) e.toString(),
        };
        var regChanged = false;
        for (final doc in bSnap.docs) {
          final data = doc.data();
          final bName = ((data['name'] as String?) ?? doc.id).trim();
          if (tombstoned.contains(bName)) continue;

          // Check if building was renamed
          final renamedFrom = (data['renamedFrom'] as String?)?.trim();
          if (renamedFrom != null && renamedFrom.isNotEmpty) {
            await prefs.setString(
                'building_tombstone_$renamedFrom',
                DateTime.now().toIso8601String());
            tombstoned.add(renamedFrom);
            if (registry.remove(renamedFrom)) regChanged = true;
            final oldKeys = prefs
                .getKeys()
                .where((k) =>
                    k.startsWith('map_$renamedFrom#') ||
                    k == 'map_$renamedFrom')
                .toList();
            for (final k in oldKeys) {
              await prefs.remove(k);
            }
            await prefs.remove('building_gps_$renamedFrom');
            await prefs.remove('building_place_$renamedFrom');
          }

          if (registry.add(bName)) regChanged = true;

          // Update GPS if remote has coordinates
          if (data['latitude'] is num && data['longitude'] is num) {
            final locPayload = jsonEncode({
              'latitude': (data['latitude'] as num).toDouble(),
              'longitude': (data['longitude'] as num).toDouble(),
              'accuracy': (data['accuracy'] as num?)?.toDouble() ?? 0.0,
              'timestamp': data['locationRecordedAt'] as String? ??
                  DateTime.now().toIso8601String(),
            });
            if (prefs.getString('building_gps_$bName') != locPayload) {
              await prefs.setString('building_gps_$bName', locPayload);
            }
          }
        }
        if (regChanged) {
          await prefs.setString(
              'building_registry', jsonEncode(registry.toList()));
        }
      }

      return syncedCount;
    } catch (e) {
      debugPrint('Firestore: syncFromFirestore failed: $e');
      return 0;
    }
  }

  // ---- Building connections ----------------------------------------------

  CollectionReference<Map<String, dynamic>>? get _connectionsCol => _firestore?.collection('connections');

  /// Saves an outdoor route between two buildings, keyed by its id.
  Future<void> saveConnection(String id, Map<String, dynamic> data) async {
    try {
      await _connectionsCol?.doc(_docId(id)).set({...data, 'updatedAt': FieldValue.serverTimestamp()});
    } catch (e) {
      debugPrint('Firestore: Error saving connection "$id": $e');
    }
  }

  Future<void> deleteConnection(String id) async {
    try {
      await _connectionsCol?.doc(_docId(id)).delete();
    } catch (e) {
      debugPrint('Firestore: Error deleting connection "$id": $e');
    }
  }

  /// All stored connections, or null when Firestore isn't reachable.
  Future<List<Map<String, dynamic>>?> fetchConnections() async {
    try {
      final col = _connectionsCol;
      if (col == null) return null;
      final snapshot = await col.get();
      return [for (final doc in snapshot.docs) Map<String, dynamic>.from(doc.data())..remove('updatedAt')];
    } catch (e) {
      debugPrint('Firestore: fetchConnections failed: $e');
      return null;
    }
  }

  // Firestore document ids can't contain '/'.
  static String _docId(String id) => id.replaceAll('/', '_');
}
