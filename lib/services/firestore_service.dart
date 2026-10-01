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

  /// Syncs remote maps from Firestore down to local SharedPreferences if not already present.
  Future<int> syncFromFirestore() async {
    try {
      final maps = _mapsCol;
      if (maps == null) return 0;

      final prefs = await SharedPreferences.getInstance();
      final snapshot = await maps.get();
      int syncedCount = 0;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final key = data['key'] as String? ?? 'map_${data['name']}#${data['floor']}';
        if (!prefs.containsKey(key)) {
          // Clean non-serializable fields if any before caching locally
          final cleanData = Map<String, dynamic>.from(data)
            ..remove('updatedAt')
            ..remove('createdAt');
          await prefs.setString(key, jsonEncode(cleanData));
          syncedCount++;
        }
      }
      return syncedCount;
    } catch (e) {
      debugPrint('Firestore: syncFromFirestore failed: $e');
      return 0;
    }
  }
}
