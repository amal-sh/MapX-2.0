import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/search_models.dart';
import '../services/search_service.dart';
import 'service_providers.dart';

/// Provider for loading the search location context (nearby buildings & places).
final searchContextProvider = FutureProvider.autoDispose<SearchLocationContext>((ref) async {
  final service = ref.watch(searchServiceProvider);
  return await service.loadSearchContext();
});

/// Current active search query string.
final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

/// Current active category filter: 'all', 'places', 'buildings', 'connectors'.
final searchCategoryFilterProvider = StateProvider.autoDispose<String>((ref) => 'all');

/// Current focused building filter (nullable).
final searchFocusedBuildingProvider = StateProvider.autoDispose<String?>((ref) => null);

/// Computed search results based on query, category, focused building, and search context.
final searchResultsProvider = Provider.autoDispose<SearchResults>((ref) {
  final query = ref.watch(searchQueryProvider);
  final category = ref.watch(searchCategoryFilterProvider);
  final focusedBuilding = ref.watch(searchFocusedBuildingProvider);
  final contextAsync = ref.watch(searchContextProvider);

  return contextAsync.maybeWhen(
    data: (ctx) {
      final service = ref.watch(searchServiceProvider);
      return service.search(
        query: query,
        context: ctx,
        focusBuildingName: focusedBuilding,
        categoryFilter: category,
      );
    },
    orElse: () => const SearchResults(waypoints: [], buildings: []),
  );
});
