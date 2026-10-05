// The Status screen: no catalog byte with the tab flagged off, the shared empty and error faces, and
// a non-premium tap that goes STRAIGHT to the paywall stamped with the verb it came from.
import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/widgets/reel/reel_prefetch_service.dart';
import 'package:arul/app/widgets/reel/video_preload_controller.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/presentation/status_screen.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:arul/features/wallpapers/data/feed_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _clips = [
  StatusVideo(
    id: 'c0ffee00-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
    title: 'Vel',
    category: 'murugan',
    key: 'statuses/murugan/c0ffee00.mp4',
  ),
  StatusVideo(
    id: 'c0ffee01-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
    title: 'Deepam',
    category: 'sivan',
    key: 'statuses/sivan/c0ffee01.mp4',
  ),
];

class _NullCache implements CacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoPrefetch extends ReelPrefetchService<StatusVideo> {
  _NoPrefetch()
    : super(
        cdnBaseUrl: 'https://cdn.test',
        cache: _NullCache.new,
        ahead: 1,
        aheadCold: 1,
      );

  @override
  Future<String?> cachedPathOrNull(String url) async => null;

  @override
  void prefetchAround(List<StatusVideo> items, int currentIndex) {}
}

class _Catalog extends StatusCatalogNotifier {
  _Catalog(this._result, this.builds);
  final Future<List<StatusVideo>> Function() _result;
  final List<int> builds;

  @override
  Future<List<StatusVideo>> build() {
    builds.add(1);
    return _result();
  }
}

class _NoConfig extends AppConfigNotifier {
  @override
  Future<AppConfigModel?> build() async => null;
}

class _RecordingAnalytics implements AnalyticsService {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

const _method = MethodChannel('arul_test/status_video');

void main() {
  late List<int> builds;
  late _RecordingAnalytics analytics;
  late List<String> pushed;

  Future<void> pump(
    WidgetTester tester, {
    bool? flag = true,
    bool premium = false,
    Future<List<StatusVideo>> Function()? catalog,
  }) async {
    builds = [];
    analytics = _RecordingAnalytics();
    pushed = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _method,
      (_) async => null,
    );
    final controller = VideoPreloadController<StatusVideo>(
      cdnBaseUrl: 'https://cdn.test',
      prefetch: _NoPrefetch(),
      pool: FeedVideoPlayerPool.withChannels(
        _method,
        const EventChannel('arul_test/status_video_events'),
      ),
      keepBehind: 0,
      audio: true,
      visible: false,
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const StatusScreen()),
        GoRoute(
          path: '/premium',
          builder: (_, state) {
            pushed.add(state.uri.toString());
            return const Text('paywall');
          },
        ),
        GoRoute(path: '/settings', builder: (_, _) => const Text('settings')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          statusTabFlagProvider.overrideWithValue(flag),
          statusCatalogProvider.overrideWith(
            () => _Catalog(catalog ?? () async => _clips, builds),
          ),
          appConfigProvider.overrideWith(_NoConfig.new),
          entitlementProvider.overrideWith((ref) async => premium),
          statusVideoControllerProvider.overrideWith((ref) {
            ref.onDispose(controller.dispose);
            return controller;
          }),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('flag off or unknown → the catalog is never fetched', (
    tester,
  ) async {
    for (final flag in [false, null]) {
      await pump(tester, flag: flag);
      expect(builds, isEmpty, reason: 'flag $flag');
      expect(find.text('Status'), findsNothing);
    }
  });

  testWidgets('flag on → the reel, the chips and both actions', (tester) async {
    await pump(tester);
    expect(builds, [1]);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Murugan'), findsOneWidget);
    expect(find.bySemanticsIdentifier('arul_status_whatsapp'), findsWidgets);
    expect(find.bySemanticsIdentifier('arul_status_save'), findsWidgets);
    expect(find.bySemanticsIdentifier('arul_header_settings'), findsOneWidget);
  });

  testWidgets('an empty catalog shows the empty face', (tester) async {
    await pump(tester, catalog: () async => const []);
    expect(find.text('No status videos yet'), findsOneWidget);
  });

  testWidgets('a failed catalog shows the error face with retry', (
    tester,
  ) async {
    await pump(tester, catalog: () async => throw StateError('page 1 missing'));
    expect(find.text("Couldn't load status videos"), findsOneWidget);
    expect(find.bySemanticsIdentifier('arul_status_retry'), findsOneWidget);
  });

  for (final (id, source) in [
    ('arul_status_whatsapp', 'status_share'),
    ('arul_status_save', 'status_save'),
  ]) {
    testWidgets('non-premium $id → straight to /premium?source=$source', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.bySemanticsIdentifier(id).first);
      await tester.pumpAndSettle();

      expect(pushed, ['/premium?source=$source']);
      expect(
        analytics.events.map((e) => e.$1),
        contains('${source}_blocked_premium'),
      );
      final props = analytics.events
          .firstWhere((e) => e.$1 == '${source}_blocked_premium')
          .$2;
      expect(props, {'status_id': _clips.first.id, 'category': 'murugan'});
    });
  }
}
