// The Status screen: the shared empty and error faces, a non-premium tap that goes STRAIGHT to
// the paywall stamped with the verb it came from, and a premium share's card -> sheet -> target.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/widgets/arul_screen_header.dart';
import 'package:arul/app/widgets/reel/reel_card.dart';
import 'package:arul/app/widgets/reel/reel_prefetch_service.dart';
import 'package:arul/app/widgets/reel/video_preload_controller.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/presentation/status_screen.dart';
import 'package:arul/features/status/providers/status_action_provider.dart';
import 'package:arul/features/status/providers/status_persona_provider.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:arul/features/wallpapers/data/feed_video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/support/load_real_fonts.dart';

const _clips = [
  // A 2:3 clip and a 9:16 one: the reel must hold both at their own shapes.
  StatusVideo(
    id: 'c0ffee00-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
    title: 'Vel',
    category: 'murugan',
    key: 'statuses/murugan/c0ffee00.mp4',
    width: 1024,
    height: 1536,
  ),
  StatusVideo(
    id: 'c0ffee01-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
    title: 'Deepam',
    category: 'sivan',
    key: 'statuses/sivan/c0ffee01.mp4',
    width: 1024,
    height: 1824,
  ),
];

/// The reel's poster sweep never settles -> step the sheet's rise and fall instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

final _shotKey = GlobalKey();

const _tamil = StatusVideo(
  id: 'c0ffee02-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
  title: 'Amman',
  category: 'tamil',
  key: 'statuses/tamil/c0ffee02.mp4',
  width: 768,
  height: 1152,
);

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

  /// Every index the pool asked to stage around, in order — the first one is the card it opened on.
  final indices = <int>[];

  /// The reel's list as the pool last staged it.
  List<String> ids = const [];

  @override
  Future<String?> cachedPathOrNull(String url) async => null;

  @override
  void prefetchAround(List<StatusVideo> items, int currentIndex) {
    indices.add(currentIndex);
    ids = [for (final s in items) s.id];
  }
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

/// The action notifier with the I/O taken out: each verb parks on [gate], so a test can look at the
/// preparing card mid-flight. The real fan-out is pinned by status_action_test.dart.
class _FakeActions extends StatusActionNotifier {
  _FakeActions({this.whatsApp = true, this.settle});

  final bool whatsApp;

  // Set -> the fetch fails this way instead of reaching the sheet.
  final StatusActionOutcome? settle;
  final gate = Completer<void>();
  final picks = <StatusShareTarget>[];
  var prepares = 0;
  var saves = 0;

  @override
  Future<StatusSharePrep?> prepareShare(StatusVideo status) async {
    if (state is! StatusActionIdle) return null;
    prepares++;
    state = const StatusActionBusy();
    await gate.future;
    if (settle case final outcome?) {
      state = const StatusActionIdle();
      return StatusShareSettled(outcome);
    }
    state = StatusActionChoosing(status, File('clip.mp4'), whatsApp);
    return StatusShareReady(whatsApp: whatsApp);
  }

  /// A download progress callback, as the real fetch reports one.
  void tick(double progress) => state = StatusActionBusy(progress: progress);

  @override
  Future<StatusActionOutcome?> shareVia(StatusShareTarget target) async {
    if (state is! StatusActionChoosing) return null;
    state = const StatusActionIdle();
    picks.add(target);
    return StatusActionOutcome.done;
  }

  @override
  Future<StatusActionOutcome?> save(StatusVideo status) async {
    if (state is! StatusActionIdle) return null;
    saves++;
    state = const StatusActionBusy(stage: StatusActionStage.saving);
    await gate.future;
    state = const StatusActionIdle();
    return StatusActionOutcome.done;
  }
}

const _method = MethodChannel('arul_test/status_video');

List<String> _feedIds(ProviderContainer c) => [
  for (final s in c.read(statusFeedProvider).value!) s.id,
];

void main() {
  late List<int> builds;
  late _RecordingAnalytics analytics;
  late List<String> pushed;
  late _NoPrefetch prefetch;

  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  late SharedPreferences prefs;
  late GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    bool premium = false,
    bool online = true,
    bool visible = false,
    Future<List<StatusVideo>> Function()? catalog,
    _FakeActions? actions,
    bool reduceMotion = false,
    bool languageAsked = true,
    String? appLanguage,
    bool shell = false,
    double textScale = 1,
    List<Override> extra = const [],
  }) async {
    builds = [];
    analytics = _RecordingAnalytics();
    pushed = [];
    prefetch = _NoPrefetch();
    // The deep-link consume clears its persisted copy through installReferrerServiceProvider.
    SharedPreferences.setMockInitialValues({
      if (languageAsked) StatusScreen.languageAskedKey: true,
      appLocalePrefsKey: ?appLanguage,
    });
    prefs = await SharedPreferences.getInstance();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _method,
      (_) async => null,
    );
    final controller = VideoPreloadController<StatusVideo>(
      cdnBaseUrl: 'https://cdn.test',
      prefetch: prefetch,
      pool: FeedVideoPlayerPool.withChannels(
        _method,
        const EventChannel('arul_test/status_video_events'),
      ),
      keepBehind: 0,
      audio: true,
      visible: visible,
    );
    final status = GoRoute(path: '/', builder: (_, _) => const StatusScreen());
    router = GoRouter(
      initialLocation: '/',
      routes: [
        if (shell)
          // The app's shell hides a tab it leaves behind TickerMode, as this one does.
          StatefulShellRoute.indexedStack(
            builder: (_, _, navigationShell) => navigationShell,
            branches: [
              StatefulShellBranch(routes: [status]),
              StatefulShellBranch(
                routes: [
                  GoRoute(path: '/other', builder: (_, _) => const Text('other')),
                ],
              ),
            ],
          )
        else
          status,
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
          isOnlineProvider.overrideWith((ref) => Stream.value(online)),
          sharedPreferencesProvider.overrideWithValue(prefs),
          if (actions != null) statusActionProvider.overrideWith(() => actions),
          ...extra,
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: RepaintBoundary(key: _shotKey, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the reel and both actions, no category chips', (tester) async {
    await pump(tester);
    expect(builds, [1]);
    expect(find.text('Status and Greet'), findsOneWidget);
    expect(find.text('Murugan'), findsNothing);
    expect(find.bySemanticsIdentifier('arul_status_whatsapp'), findsWidgets);
    expect(find.bySemanticsIdentifier('arul_status_save'), findsWidgets);
    expect(find.bySemanticsIdentifier('arul_header_settings'), findsOneWidget);
  });

  ProviderContainer scopeOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(StatusScreen)));

  testWidgets('the sheet offers only languages with statuses; the pick narrows the reel and the app', (
    tester,
  ) async {
    await pump(
      tester,
      languageAsked: false,
      catalog: () async => [..._clips, _tamil],
    );
    await _settle(tester);
    expect(find.text('தமிழ்'), findsOneWidget);
    expect(find.text('English'), findsNothing);
    expect(find.text('हिन्दी'), findsNothing);
    expect(find.text('മലയാളം'), findsNothing, reason: 'no Malayalam clips here');

    await tester.tap(find.text('தமிழ்'));
    await _settle(tester);
    final scope = scopeOf(tester);
    expect(prefs.getString(appLocalePrefsKey), 'ta');
    expect(prefs.getBool(StatusScreen.languageAskedKey), isTrue);
    expect(scope.read(statusLanguageProvider), 'ta');
    expect(_feedIds(scope), [_tamil.id]);
  });

  testWidgets('a closed sheet with no language shows every clip and asks again on the next visit', (
    tester,
  ) async {
    await pump(
      tester,
      languageAsked: false,
      shell: true,
      catalog: () async => [..._clips, _tamil],
    );
    await _settle(tester);
    expect(find.text('தமிழ்'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await _settle(tester);
    expect(find.text('தமிழ்'), findsNothing);
    final scope = scopeOf(tester);
    expect(scope.read(statusLanguageProvider), isNull);
    expect(_feedIds(scope), hasLength(3));
    expect(prefs.getString(appLocalePrefsKey), isNull);

    // Back from a pushed page is not a visit.
    unawaited(router.push('/settings'));
    await _settle(tester);
    router.pop();
    await _settle(tester);
    expect(find.text('தமிழ்'), findsNothing);

    router.go('/other');
    await _settle(tester);
    router.go('/');
    await _settle(tester);
    expect(find.text('தமிழ்'), findsOneWidget);
  });

  testWidgets('an app language with statuses is asked once, selected, and closing keeps it', (
    tester,
  ) async {
    await pump(
      tester,
      languageAsked: false,
      appLanguage: 'ta',
      shell: true,
      catalog: () async => [..._clips, _tamil],
    );
    await _settle(tester);
    expect(find.text('தமிழ்'), findsOneWidget);
    expect(_feedIds(scopeOf(tester)), [_tamil.id]);
    await tester.tapAt(const Offset(20, 20));
    await _settle(tester);
    expect(prefs.getBool(StatusScreen.languageAskedKey), isTrue);
    expect(prefs.getStringList(StatusLanguagePicks.prefsKey), ['ta']);

    router.go('/other');
    await _settle(tester);
    router.go('/');
    await _settle(tester);
    expect(find.text('தமிழ்'), findsNothing, reason: 'never twice');
    expect(_feedIds(scopeOf(tester)), [_tamil.id]);
  });

  test('English has no status category', () {
    expect(statusSlugForLanguage('en'), isNull);
    expect(statusSlugForLanguage('ta'), 'tamil');
  });

  group('the status language', () {
    Future<ProviderContainer> container({
      String? app,
      List<String> picks = const [],
    }) async {
      SharedPreferences.setMockInitialValues({
        appLocalePrefsKey: ?app,
        if (picks.isNotEmpty) StatusLanguagePicks.prefsKey: picks,
      });
      prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer.test(
        overrides: [
          statusCatalogProvider.overrideWith(
            () => _Catalog(() async => [..._clips, _tamil], []),
          ),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      await c.read(statusCatalogProvider.future);
      return c;
    }

    test('is the app language when it has clips', () async {
      final c = await container(app: 'ta', picks: ['ml']);
      expect(c.read(statusLanguageProvider), 'ta');
      expect(_feedIds(c), [_tamil.id]);
    });

    test('falls back to the latest pick with clips, past one without', () async {
      final c = await container(app: 'hi', picks: ['hi', 'ta']);
      expect(c.read(statusLanguageProvider), 'ta');
      expect(_feedIds(c), [_tamil.id]);
    });

    test('is none for English with no pick -> every clip', () async {
      final c = await container(app: 'en');
      expect(c.read(statusLanguageProvider), isNull);
      expect(_feedIds(c), hasLength(3));
    });

    test('a pick goes first, once; English is never kept', () async {
      final c = await container();
      final picks = c.read(statusLanguagePicksProvider.notifier);
      await picks.remember('ta');
      await picks.remember('en');
      await picks.remember('ml');
      await picks.remember('ta');
      expect(c.read(statusLanguagePicksProvider), ['ta', 'ml']);
      expect(prefs.getStringList(StatusLanguagePicks.prefsKey), ['ta', 'ml']);
    });
  });

  testWidgets('a cold status link is never interrupted by the language sheet', (
    tester,
  ) async {
    ArulDeepLink.requestTarget(StatusLinkTarget(_clips[1].id));
    await pump(tester, languageAsked: false, visible: true);
    await _settle(tester);
    expect(find.text('தமிழ்'), findsNothing);
    expect(prefs.getBool(StatusScreen.languageAskedKey), isNull);
  });

  testWidgets('Photo on a phone that cannot export explains itself', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.hsrutility.arul/share_watermark'),
      (_) async => {'supported': false, 'sdkInt': 30},
    );
    await pump(tester);
    await tester.tap(find.bySemanticsIdentifier('arul_status_photo').first);
    await _settle(tester);
    expect(find.text('Needs Android 12 or newer'), findsOneWidget);
  });

  testWidgets('an empty catalog shows the empty face', (tester) async {
    await pump(tester, catalog: () async => const []);
    expect(find.text('No status videos yet'), findsOneWidget);
    expect(
      find.bySemanticsIdentifier('arul_feed_browse_all'),
      findsNothing,
      reason: 'no categories to browse',
    );
  });

  testWidgets('the loading card names status videos, never wallpapers', (
    tester,
  ) async {
    final gate = Completer<List<StatusVideo>>();
    await pump(tester, catalog: () => gate.future);
    expect(find.text('Bringing your status videos…'), findsOneWidget);
    expect(find.textContaining('wallpapers'), findsNothing);
    gate.complete(_clips);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Bringing your status videos…'), findsNothing);
  });

  testWidgets('offline with nothing loaded is the offline card', (
    tester,
  ) async {
    await pump(
      tester,
      online: false,
      catalog: () async => throw StateError('offline'),
    );
    expect(find.text('No internet'), findsOneWidget);
    expect(
      find.text('Turn on the internet to see status videos.'),
      findsOneWidget,
    );
    expect(find.bySemanticsIdentifier('arul_status_retry'), findsOneWidget);
  });

  testWidgets('a cold link leads with its clip, in any language, then the user\'s own', (
    tester,
  ) async {
    ArulDeepLink.requestTarget(StatusLinkTarget(_clips[1].id));
    await pump(
      tester,
      visible: true,
      appLanguage: 'ta',
      catalog: () async => [..._clips, _tamil],
    );
    await tester.pump(const Duration(milliseconds: 300));

    final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pager.initialPage, 0);
    expect(prefetch.indices, isNotEmpty);
    expect(prefetch.indices.first, 0, reason: 'the pool opened on the target');
    expect(prefetch.ids, [_clips[1].id, _tamil.id]);
    expect(ArulDeepLink.pendingTarget, isNull, reason: 'consumed');
    expect(analytics.events.map((e) => e.$1), contains('deep_link_opened'));

    // A new status language drops the linked clip.
    await ProviderScope.containerOf(tester.element(find.byType(StatusScreen)))
        .read(localeProvider.notifier)
        .setLocale(const Locale('en'), source: LanguageSource.pick);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(prefetch.ids, hasLength(3));
  });

  testWidgets('offline with clips in hand keeps the reel', (tester) async {
    await pump(tester, online: false);
    expect(find.text('No internet'), findsNothing);
    expect(find.bySemanticsIdentifier('arul_status_whatsapp'), findsWidgets);
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

  group('premium share', () {
    // The reel's poster sweep never settles -> step past the card's and the sheet's transitions.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Finder cell(String name) =>
        find.bySemanticsIdentifier('arul_status_share_$name');

    testWidgets('the card speaks the stage, then the Arul sheet offers four '
        'targets in the owner\'s order', (tester) async {
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions);

      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Getting the video…'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'no transfer yet, no bar',
      );
      actions.tick(0.4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('%'), findsNothing, reason: 'never a counter');

      actions.gate.complete();
      await settle(tester);
      expect(find.text('Getting the video…'), findsNothing);
      expect(find.text('Share this video'), findsOneWidget);
      final xs = [
        for (final n in ['groups', 'chat', 'status', 'more'])
          tester.getCenter(cell(n)).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));
      expect(find.text('Groups'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
      const logo = AssetImage('assets/images/whatsapp.webp');
      for (final n in ['groups', 'chat', 'status']) {
        expect(
          find.descendant(of: cell(n), matching: find.image(logo)),
          findsOneWidget,
          reason: '$n opens WhatsApp, so it wears the logo',
        );
      }
      expect(
        find.descendant(of: cell('more'), matching: find.image(logo)),
        findsNothing,
        reason: 'More is the system sheet, not WhatsApp',
      );
    });

    testWidgets('under reduced motion the bar lands without a layout assert', (
      tester,
    ) async {
      // A zero-length AnimatedSize re-dirtied itself mid-layout on a low-tier phone.
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions, reduceMotion: true);
      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      actions.tick(0.4);
      await tester.pump();
      actions.tick(0.8);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      actions.gate.complete();
      await settle(tester);
    });

    testWidgets('a pick closes the sheet and fires ONCE, even on a double '
        'tap', (tester) async {
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions);
      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      actions.gate.complete();
      await settle(tester);

      await tester.tap(cell('groups'));
      await tester.pump();
      await tester.tap(cell('groups'), warnIfMissed: false);
      await settle(tester);

      expect(actions.picks, [StatusShareTarget.groups]);
      expect(actions.prepares, 1);
      expect(find.text('Share this video'), findsNothing);
      expect(
        find.byType(StatusScreen),
        findsOneWidget,
        reason: 'no double pop',
      );
      expect(actions.state, isA<StatusActionIdle>());
    });

    testWidgets('Close shares nothing and frees the pills', (tester) async {
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions);
      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      actions.gate.complete();
      await settle(tester);

      await tester.tap(find.bySemanticsIdentifier('arul_status_share_close'));
      await settle(tester);

      expect(actions.picks, isEmpty);
      expect(actions.state, isA<StatusActionIdle>());
    });

    testWidgets('no WhatsApp: no Arul sheet, straight to the system sheet', (
      tester,
    ) async {
      final actions = _FakeActions(whatsApp: false);
      await pump(tester, premium: true, actions: actions);
      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      actions.gate.complete();
      await settle(tester);

      expect(find.text('Share this video'), findsNothing);
      expect(actions.picks, [StatusShareTarget.more]);
    });

    testWidgets('Back on the card abandons: no sheet, no share', (
      tester,
    ) async {
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions);
      await tester.tap(
        find.bySemanticsIdentifier('arul_status_whatsapp').first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Getting the video…'), findsNothing);
      expect(find.byType(StatusScreen), findsOneWidget);
      expect(
        find.byType(ReelTransferBar),
        findsOneWidget,
        reason: 'the pills wait on a fetch the user can no longer see',
      );
      actions.gate.complete();
      await settle(tester);
      expect(find.byType(ReelTransferBar), findsNothing);

      expect(find.text('Share this video'), findsNothing);
      expect(actions.picks, isEmpty);
      expect(actions.state, isA<StatusActionIdle>());
    });

    for (final (outcome, expectPaywall) in [
      (StatusActionOutcome.offline, false),
      (StatusActionOutcome.premiumRequired, true),
    ]) {
      testWidgets(
        'a fetch that settles ${outcome.name} speaks after the card',
        (tester) async {
          final actions = _FakeActions(settle: outcome);
          await pump(tester, premium: true, actions: actions);
          await tester.tap(
            find.bySemanticsIdentifier('arul_status_whatsapp').first,
          );
          await tester.pump();
          actions.gate.complete();
          await settle(tester);

          expect(find.text('Share this video'), findsNothing);
          expect(find.text('Getting the video…'), findsNothing);
          if (expectPaywall) {
            expect(pushed, ['/premium?source=status_share']);
          } else {
            expect(
              find.text("You're offline. Check your connection and try again."),
              findsOneWidget,
            );
            expect(pushed, isEmpty);
          }
          expect(actions.state, isA<StatusActionIdle>());
        },
      );
    }

    testWidgets('Save shows the saving line, then its toast', (tester) async {
      final actions = _FakeActions();
      await pump(tester, premium: true, actions: actions);
      await tester.tap(find.bySemanticsIdentifier('arul_status_save').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Saving to your gallery…'), findsOneWidget);
      expect(
        find.byType(LinearProgressIndicator),
        findsNothing,
        reason: 'no transfer, no bar',
      );

      actions.gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.text('Getting it ready to share…'),
        findsNothing,
        reason: 'the fading card keeps the line it last showed',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Saving to your gallery…'), findsNothing);
      expect(find.text('Saved to your gallery'), findsOneWidget);
      expect(actions.saves, 1);
    });
  });

  group('a card is its clip\'s own shape, whole — never cut, never padded', () {
    testWidgets('the header stays through every swipe', (tester) async {
      await pump(tester, reduceMotion: true);
      final before = tester.getRect(find.byType(ArulScreenHeader));
      await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.getRect(find.byType(ArulScreenHeader)), before);
    });

    testWidgets('a 2:3 clip and a 9:16 clip each get a card of their shape inside the slot', (
      tester,
    ) async {
      await pump(tester, reduceMotion: true);
      final page = tester.getRect(find.byType(PageView));
      final first = tester.getRect(find.byType(StatusMedia).first);
      expect(first.height / first.width, closeTo(1536 / 1024, 0.01));
      expect(first.center.dx, closeTo(page.center.dx, 0.5));
      expect(first.width, lessThanOrEqualTo(page.width - 24 + 0.01));
      expect(first.center.dy, closeTo(page.center.dy, 0.5), reason: 'one page, centred');

      await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final second = tester.getRect(find.byType(StatusMedia).last);
      expect(second.height / second.width, closeTo(1824 / 1024, 0.01));
      expect(second.center.dx, closeTo(page.center.dx, 0.5));
    });

    testWidgets('the media fills its card edge to edge: poster and texture both', (
      tester,
    ) async {
      final slot = LiveVideoSlot(
        index: 0,
        playerId: 1,
        textureId: 7,
        videoSize: ValueNotifier(const Size(1024, 1536)),
        ready: ValueNotifier(true),
      );
      const card = Size(298, 447);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.fromSize(
              size: card,
              child: StatusMedia(status: _clips.first, slot: slot),
            ),
          ),
        ),
      );
      await tester.pump();
      final box = tester.getRect(find.byType(StatusMedia));
      expect(tester.getRect(find.byType(Texture)), box);
      final poster = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(poster.fit, BoxFit.fill);
      expect(tester.getRect(find.byType(CachedNetworkImage)), box);
    });
  });

  // The screen sizes signed-in users actually have (PostHog, 30 days, dp): 360 wide dominates,
  // 320x600 is the smallest and 432x960 the largest seen in volume.
  group('real user resolutions, with a photo and a name', () {
    setUpAll(loadRealFonts);

    for (final size in const [
      Size(320, 600),
      Size(360, 680),
      Size(360, 720),
      Size(360, 800),
      Size(384, 840),
      Size(392, 840),
      Size(411, 880),
      Size(432, 960),
    ]) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} @$scale', (
          tester,
        ) async {
          tester.view
            ..devicePixelRatio = 2
            ..physicalSize = size * 2;
          addTearDown(tester.view.reset);
          // The screenshot step runs real async, where the image cache and the player's event
          // stream reach for plugins a test does not have.
          final messenger = tester.binding.defaultBinaryMessenger
            ..setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => Directory.systemTemp.path,
            )
            ..setMockMethodCallHandler(
              const MethodChannel('arul_test/status_video_events'),
              (_) async => null,
            );
          addTearDown(() {
            messenger
              ..setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              )
              ..setMockMethodCallHandler(
                const MethodChannel('arul_test/status_video_events'),
                null,
              );
          });
          final photo = await tester.runAsync(_photo);
          await pump(
            tester,
            textScale: scale,
            appLanguage: 'ta',
            catalog: () async => [_tamil, ..._clips],
            extra: [
              statusPersonaSupportedProvider.overrideWith((_) async => true),
              statusPersonaProvider.overrideWith(
                () => _Persona(StatusPersona(photo: photo)),
              ),
              statusPersonaNameProvider.overrideWithValue(
                'Anish Kumar Jha Murugan',
              ),
            ],
          );
          await tester.pump(const Duration(milliseconds: 300));

          final screen = Offset.zero & size;
          final clip = tester.getRect(find.byType(StatusMedia).first);
          expect(screen.contains(clip.topLeft), isTrue);
          expect(clip.bottom, lessThanOrEqualTo(size.height));
          for (final id in const [
            'arul_status_photo',
            'arul_status_whatsapp',
            'arul_status_save',
          ]) {
            final r = tester.getRect(find.bySemanticsIdentifier(id).first);
            expect(r.bottom, lessThanOrEqualTo(size.height), reason: id);
            expect(r.right, lessThanOrEqualTo(size.width), reason: id);
            expect(r.top, greaterThanOrEqualTo(clip.bottom - 0.5), reason: '$id sits under the clip');
            expect(r.width, greaterThan(40), reason: '$id stays a real target, was $r');
          }
          expect(find.byType(StatusMedia), findsWidgets);
          final dir = Platform.environment['STATUS_SHOTS'];
          if (dir != null) {
            await tester.runAsync(() async {
              final boundary =
                  _shotKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              File(
                '$dir/status-${size.width.toInt()}x${size.height.toInt()}-$scale.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
            });
          }
        });
      }
    }
  });
}

class _Persona extends StatusPersonaNotifier {
  _Persona(this.persona);

  final StatusPersona persona;

  @override
  Future<StatusPersona> build() async => persona;
}

Future<ui.Image> _photo() {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 128, 128),
      Paint()..color = const Color(0xFF7090C0),
    )
    ..drawCircle(const Offset(64, 50), 26, Paint()..color = const Color(0xFFEBCDB4));
  canvas.drawCircle(const Offset(64, 140), 50, Paint()..color = const Color(0xFF304060));
  return recorder.endRecording().toImage(128, 128);
}
