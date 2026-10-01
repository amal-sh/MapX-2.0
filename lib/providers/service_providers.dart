import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firestore_service.dart';
import '../services/location_service.dart';
import '../services/search_service.dart';

/// Provider for SharedPreferences instance.
final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

/// Provider for FirestoreService singleton. Overridable in tests.
final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  return FirestoreService.instance;
});

/// Provider for LocationService singleton. Overridable in tests.
final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService.instance;
});

/// Provider for SearchService singleton. Overridable in tests.
final searchServiceProvider = Provider<SearchService>((ref) {
  return SearchService.instance;
});
