import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import '../data/video_thumbnail_service.dart';

/// PREVIEW SOURCE (UI phase): the bucket's own content-prep manifest.
///
/// Port-map Phase 4 repoints this at the Worker-built catalog
/// (`catalog/wallpapers/all_{page}.json` + `version.json` for `?v=` busting) and
/// adds paging. Nothing above this provider changes — the widgets already
/// consume `Wallpaper`.
final catalogProvider = FutureProvider<List<Wallpaper>>((ref) async {
  final res = await http.get(
    Uri.parse('${AppConfig.cdnBaseUrl}/catalog/catalog.json'),
  );
  if (res.statusCode != 200) {
    throw Exception('catalog ${res.statusCode}');
  }
  final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final assets = (body['assets'] as List).cast<Map<String, dynamic>>();
  return assets.map(Wallpaper.fromManifest).toList(growable: false);
});

/// Categories, derived from the catalog — not a hardcoded list, so adding a
/// seventh deity server-side needs no app release.
final categoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(catalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <Wallpaper>[],
  };
  final labels = <String, String>{};
  for (final w in all) {
    labels.putIfAbsent(w.category, () => w.categoryLabel);
  }
  return labels.entries
      .map((e) => WallpaperCategory(e.key, e.value))
      .toList(growable: false)
    ..sort((a, b) => a.label.compareTo(b.label));
});

final selectedCategoryProvider = NotifierProvider<SelectedCategory, String>(
  SelectedCategory.new,
);

class SelectedCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The feed: catalog filtered by the selected CATEGORY. Never by kind — static
/// and live interleave by design (CLAUDE.md §5b).
final feedProvider = Provider<AsyncValue<List<Wallpaper>>>((ref) {
  final slug = ref.watch(selectedCategoryProvider);
  return ref
      .watch(catalogProvider)
      .whenData(
        (all) => slug == WallpaperCategory.allSlug
            ? all
            : all.where((w) => w.category == slug).toList(growable: false),
      );
});

/// Native first-frame stills — the grid's fallback for a live wallpaper whose
/// pre-generated thumbnail is missing. App-scoped so its in-flight memo is shared
/// across grid rebuilds and a fling issues one native call per clip, not one per
/// build.
final videoThumbnailServiceProvider = Provider<VideoThumbnailService>(
  (ref) => VideoThumbnailService(),
);
