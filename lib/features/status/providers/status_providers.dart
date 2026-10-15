import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/reel/reel_prefetch_service.dart';
import '../../../app/widgets/reel/video_preload_controller.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../data/status_media_service.dart';
import '../data/status_prefetch_service.dart';
import '../domain/status_video.dart';

final statusPrefetchServiceProvider =
    Provider<ReelPrefetchService<StatusVideo>>((ref) {
      final service = StatusPrefetchService(cdnBaseUrl: AppConfig.cdnBaseUrl);
      ref.onDispose(service.dispose);
      return service;
    });

/// The status reel's own pool: current + next only, audible, hidden until the shell shows it.
/// App-scoped for the same reason as the feed's -> `ref` is unusable from a screen's dispose().
final statusVideoControllerProvider =
    Provider<VideoPreloadController<StatusVideo>>((ref) {
      final controller = VideoPreloadController<StatusVideo>(
        cdnBaseUrl: AppConfig.cdnBaseUrl,
        prefetch: ref.read(statusPrefetchServiceProvider),
        keepBehind: 0,
        audio: true,
        visible: false,
        onGaveUp: (status, code) {
          if (!ref.mounted) return;
          // Media3 names a dropped or timed-out connection ERROR_CODE_IO_NETWORK_*: nothing to fix.
          final network = code.startsWith('ERROR_CODE_IO_NETWORK');
          ref
              .read(analyticsServiceProvider)
              .track(
                'status_play_failed',
                properties: {
                  'status_id': status.id,
                  'category': status.category,
                  'code': code,
                  'reason': network ? 'network' : code,
                },
              );
          final crash = ref.read(crashReporterProvider)
            ..log('status ${status.id} gave up: $code');
          if (!network) {
            crash.recordError(
              StateError('status play gave up: $code'),
              StackTrace.current,
              reason: 'status play failed',
            );
          }
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final statusMediaServiceProvider = Provider<StatusMediaService>(
  (ref) => ApiStatusMediaService(apiClient: ref.watch(apiClientProvider)),
);

/// The status catalog, drained from the CDN on the first watch — only the Status screen watches it,
/// so a phone that never opens the tab never fetches a byte of it.
final statusCatalogProvider =
    AsyncNotifierProvider<StatusCatalogNotifier, List<StatusVideo>>(
      StatusCatalogNotifier.new,
    );

class StatusCatalogNotifier extends AsyncNotifier<List<StatusVideo>> {
  @override
  Future<List<StatusVideo>> build() {
    // Riverpod retries a failed build up to 10 times, each keeping the error -> one report per run.
    listenSelf((previous, next) {
      if (next.hasError && !(previous?.hasError ?? false)) {
        _reportLoadFailure(next.error!, next.stackTrace);
      }
    });
    return _fetch();
  }

  void _reportLoadFailure(Object e, StackTrace? st) {
    final network = isNetworkError(e);
    ref
        .read(analyticsServiceProvider)
        .track(
          'status_load_failed',
          properties: {'reason': network ? 'network' : '${e.runtimeType}'},
        );
    if (!network) {
      ref
          .read(crashReporterProvider)
          .recordError(e, st, reason: 'status catalog load failed');
    }
  }

  int _fetchSeq = 0;

  /// Retry from the error card, or a pull on the first card -> re-reads the version pointer so a
  /// fresh publish lands. With clips on screen they stay there while the fetch runs and after a
  /// failure, exactly as the wallpaper feed's refresh does; the loading card only ever replaces nothing.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    final seq = ++_fetchSeq;
    if (!state.hasValue) state = const AsyncLoading();
    try {
      final fresh = await _fetch();
      if (ref.mounted && seq == _fetchSeq) state = AsyncData(fresh);
    } catch (e, st) {
      if (!ref.mounted || seq != _fetchSeq || state.hasValue) return;
      state = AsyncError(e, st);
    }
  }

  Future<List<StatusVideo>> _fetch() async {
    final client = ref.read(catalogHttpClientProvider);

    Future<CatalogPage<StatusVideo>?> fetch(int page) => client.fetchPage(
      scope: 'statuses',
      slug: 'all',
      page: page,
      itemFromJson: StatusVideo.fromJson,
    );

    final first = await fetch(1);
    if (first == null) {
      // Every status publish writes page 1, so its absence is an operational fault, not an empty tab.
      throw StateError('status catalog page 1 missing on CDN');
    }
    final all = [...first.items];
    for (var page = 2; first.hasMore && page <= first.totalPages; page++) {
      final next = await fetch(page);
      if (next == null) break;
      all.addAll(next.items);
    }
    return List<StatusVideo>.unmodifiable(all);
  }
}

/// Chips derived from the catalog, ordered by the CMS's `category_order.statuses` when set.
final statusCategoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(statusCatalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <StatusVideo>[],
  };
  final cfg = switch (ref.watch(appConfigProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  };
  final labels = <String, String>{};
  for (final s in all) {
    labels.putIfAbsent(s.category, () => s.categoryLabel);
  }
  final ordered = orderedByCms(
    labels.entries.map((e) => WallpaperCategory(e.key, e.value)).toList(),
    categoryOrderFor(cfg?.categoryOrder, 'statuses'),
    compareBrowseCategories,
  );
  final lead = statusSlugForLanguage(ref.watch(localeProvider).languageCode);
  final i = ordered.indexWhere((c) => c.slug == lead);
  if (i <= 0) return ordered;
  return [ordered[i], ...ordered.take(i), ...ordered.skip(i + 1)];
});

const _statusSlugByLanguage = {
  'ta': 'tamil',
  'te': 'telugu',
  'kn': 'kannada',
  'ml': 'malayalam',
  'hi': 'hindi',
};

/// The status category of an app language. English has none.
String? statusSlugForLanguage(String code) => _statusSlugByLanguage[code];

/// The app languages the catalog has statuses for, in the app's own order -> the only ones the
/// Status language sheet offers (owner). Empty until the catalog lands.
final statusLanguagesProvider = Provider<List<String>>((ref) {
  final all = switch (ref.watch(statusCatalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <StatusVideo>[],
  };
  final slugs = {for (final s in all) s.category};
  return [
    for (final l in supportedAppLocales)
      if (slugs.contains(statusSlugForLanguage(l.languageCode))) l.languageCode,
  ];
});

final statusLanguagePicksProvider =
    NotifierProvider<StatusLanguagePicks, List<String>>(
      StatusLanguagePicks.new,
    );

/// Every language picked for Status, latest first. A list, not one value: Settings never loads the
/// catalog, so it cannot tell whether a pick has statuses, and Hindi must not wipe the Tamil before it.
class StatusLanguagePicks extends Notifier<List<String>> {
  static const prefsKey = 'arul_status_langs';

  @override
  List<String> build() =>
      ref.read(sharedPreferencesProvider).getStringList(prefsKey) ?? const [];

  /// Puts [code] first; a language with no status category is never kept.
  Future<void> remember(String code) async {
    if (statusSlugForLanguage(code) == null) return;
    if (state.isNotEmpty && state.first == code) return;
    final next = List<String>.unmodifiable([
      code,
      ...state.where((c) => c != code),
    ]);
    state = next;
    await ref.read(sharedPreferencesProvider).setStringList(prefsKey, next);
  }
}

/// The language whose clips the reel shows (owner): the app language when it has statuses, else the
/// latest pick that does, else null -> every clip, and Status asks.
final statusLanguageProvider = Provider<String?>((ref) {
  final has = ref.watch(statusLanguagesProvider);
  final app = ref.watch(localeProvider).languageCode;
  if (has.contains(app)) return app;
  for (final code in ref.watch(statusLanguagePicksProvider)) {
    if (has.contains(code)) return code;
  }
  return null;
});

/// The catalog filtered to one category, in `feed_rank` order (nulls last, catalog order next).
List<StatusVideo> statusFeedOrder(String slug, List<StatusVideo> all) =>
    orderedByUse(
      slug == WallpaperCategory.allSlug
          ? all
          : all.where((s) => s.category == slug).toList(growable: false),
      (_) => 0,
      rank: (s) => s.feedRank,
    );

final statusFeedProvider = Provider<AsyncValue<List<StatusVideo>>>((ref) {
  final code = ref.watch(statusLanguageProvider);
  final slug =
      (code == null ? null : statusSlugForLanguage(code)) ??
      WallpaperCategory.allSlug;
  return ref
      .watch(statusCatalogProvider)
      .whenData((all) => statusFeedOrder(slug, all));
});
