// A pending target decides which dock branch is showing -> wiring a device cannot be asked about later.
// Content targets follow "peek, don't consume" -> the tab's screen consumes one once its catalog can resolve the id.
// A tab-only link consumes on switch.
// A real GoRouter + StatefulShellRoute, because `goBranch` is the thing under test.
// The branches are stand-ins -> the feed and the ringtone list have their own suites for what follows the switch.
// Status is a static third branch whose dock item follows `feature_flags.status_tab`; off = the two-tab app.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/app/shell/shell_route_observer.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/app/widgets/reel/reel_item.dart';
import 'package:arul/app/widgets/reel/reel_prefetch_service.dart';
import 'package:arul/app/widgets/reel/video_preload_controller.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';
import 'package:arul/features/status/data/status_prefetch_service.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/video_preload_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real controller talks to the native decoder pool on every branch change -> this one records only the ask.
/// Both reels write into ONE log, so the order of a swap between them is observable.
class _StubReel<T extends ReelItem> extends VideoPreloadController<T> {
  _StubReel(
    this.tag,
    this.log,
    ReelPrefetchService<T> prefetch, {
    super.visible,
  }) : super(cdnBaseUrl: 'https://cdn.test', prefetch: prefetch);

  final String tag;
  final List<String> log;

  List<String> get calls => [
    for (final e in log)
      if (e.startsWith('$tag:')) e.substring(tag.length + 1),
  ];

  /// A release that takes a moment, like the native one -> a reclaim racing it shows up in the log.
  @override
  Future<void> releaseDecoders() async {
    log.add('$tag:release');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    log.add('$tag:released');
  }

  /// Recorded, never scheduled: the real one starts a [Duration] timer, which these deep-link tests
  /// would leave pending at teardown. Its grace semantics are pinned in video_leave_grace_test.dart.
  @override
  void releaseDecodersOnLeave() => log.add('$tag:leave');

  @override
  void reclaimDecoders() => log.add('$tag:reclaim');

  @override
  set visible(bool value) {
    log.add('$tag:visible=$value');
    super.visible = value;
  }
}

class _FakeCatalog extends RingtoneCatalogNotifier {
  @override
  Future<List<Ringtone>> build() async => const [];
}

class _StubPreview extends RingtonePreviewNotifier {
  @override
  RingtonePreviewState build() => const RingtonePreviewState();

  @override
  Future<void> stop() async {}
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

/// The remote flag, flippable mid-test the way a refetched config flips it.
class _Flag extends Notifier<bool?> {
  _Flag(this._initial);
  final bool? _initial;

  @override
  bool? build() => _initial;

  void set(bool? value) => state = value;
}

final _flagState = NotifierProvider<_Flag, bool?>(() => _Flag(false));

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  late List<String> log;
  late _StubReel<Wallpaper> video;
  late _StubReel<StatusVideo> status;
  late _RecordingAnalytics analytics;
  late GoRouter router;
  late ProviderContainer container;

  Future<void> pumpShell(WidgetTester tester, {bool? flag = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    log = [];
    video = _StubReel<Wallpaper>(
      'feed',
      log,
      WallpaperPrefetchService(cdnBaseUrl: 'https://cdn.test'),
    );
    status = _StubReel<StatusVideo>(
      'status',
      log,
      StatusPrefetchService(cdnBaseUrl: 'https://cdn.test'),
      visible: false,
    );
    analytics = _RecordingAnalytics();
    router = GoRouter(
      initialLocation: '/browse',
      observers: [shellRouteObserver],
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigationShell) =>
              AppShell(navigationShell: navigationShell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/browse', builder: (_, _) => const Text('feed')),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/ringtones',
                  builder: (_, _) => const Text('ringtones'),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/status',
                  builder: (_, _) => const Text('status'),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('settings')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          _flagState.overrideWith(() => _Flag(flag)),
          statusTabFlagProvider.overrideWith((ref) => ref.watch(_flagState)),
          // No onDispose -> the stubs must never reach the native pool, not even on teardown.
          videoPreloadControllerProvider.overrideWith((_) => video),
          statusVideoControllerProvider.overrideWith((_) => status),
          ringtoneCatalogProvider.overrideWith(_FakeCatalog.new),
          ringtonePreviewProvider.overrideWith(_StubPreview.new),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    await tester.pump();
  }

  /// The switch lands on one frame and the swap's release awaits on the next -> two steps.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  int currentBranch(WidgetTester tester) => tester
      .widget<AppShell>(find.byType(AppShell))
      .navigationShell
      .currentIndex;

  List<ArulLineGlyph> dockGlyphs(WidgetTester tester) => tester
      .widget<ArulNavDock>(find.byType(ArulNavDock))
      .items
      .map((i) => i.glyph)
      .toList();

  testWidgets('no target → the shell opens on Wallpapers', (tester) async {
    await pumpShell(tester);
    await tester.pump();
    expect(currentBranch(tester), AppShell.wallpapersBranch);
  });

  testWidgets('a ringtone target parked before the shell mounts switches to '
      'Ringtones and is left for that tab to consume', (tester) async {
    // The install-referrer and deferred paths seed the target before sign-in -> the shell only exists after it.
    ArulDeepLink.requestTarget(const RingtoneLinkTarget('r1'));
    await pumpShell(tester);
    await tester.pump();
    await settle(tester);

    expect(currentBranch(tester), AppShell.ringtonesBranch);
    expect(
      ArulDeepLink.pendingTarget,
      const RingtoneLinkTarget('r1'),
      reason: 'only PEEKED here — the list resolves the id',
    );
    expect(
      video.calls,
      contains('leave'),
      reason:
          'the feed is paused at once; its decoders are freed after the grace',
    );
    expect(analytics.events, isEmpty);
  });

  testWidgets('a target that lands while the shell is up switches too', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.pump();
    expect(currentBranch(tester), AppShell.wallpapersBranch);

    ArulDeepLink.requestTarget(const RingtoneLinkTarget('r1'));
    await tester.pump(); // listener → microtask → goBranch
    await settle(tester);

    expect(currentBranch(tester), AppShell.ringtonesBranch);
  });

  testWidgets('a tab-only link is consumed on the switch and reported', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.pump();

    ArulDeepLink.requestTarget(
      const TabLinkTarget(ArulTab.ringtones, source: DeepLinkSource.meta),
    );
    await tester.pump();
    await settle(tester);

    expect(currentBranch(tester), AppShell.ringtonesBranch);
    expect(ArulDeepLink.pendingTarget, isNull, reason: 'nothing left to show');
    expect(analytics.events.single.$1, 'deep_link_opened');
    expect(analytics.events.single.$2, {
      'kind': 'tab',
      'source': 'meta',
      'tab': 'ringtones',
    });
  });

  testWidgets('a wallpaper target brings a user back from Ringtones', (
    tester,
  ) async {
    ArulDeepLink.requestTarget(const TabLinkTarget(ArulTab.ringtones));
    await pumpShell(tester);
    await tester.pump();
    await settle(tester);
    expect(currentBranch(tester), AppShell.ringtonesBranch);

    ArulDeepLink.requestTarget(const WallpaperLinkTarget('w1'));
    await tester.pump();
    await settle(tester);

    expect(currentBranch(tester), AppShell.wallpapersBranch);
    expect(
      ArulDeepLink.pendingTarget,
      const WallpaperLinkTarget('w1'),
      reason: 'the feed consumes it once its catalog is in',
    );
    expect(video.calls, contains('reclaim'));
  });

  group('status flag', () {
    testWidgets('off → exactly the two-tab dock, the status reel untouched', (
      tester,
    ) async {
      await pumpShell(tester);
      await tester.pump();
      expect(dockGlyphs(tester), [
        ArulLineGlyph.wallpapers,
        ArulLineGlyph.ringtones,
      ]);
      expect(status.calls, isEmpty);
    });

    testWidgets('not loaded yet → still two tabs', (tester) async {
      await pumpShell(tester, flag: null);
      await tester.pump();
      expect(dockGlyphs(tester), hasLength(2));
    });

    testWidgets('on → a third Status cell at the status branch index', (
      tester,
    ) async {
      await pumpShell(tester, flag: true);
      await tester.pump();
      expect(dockGlyphs(tester), [
        ArulLineGlyph.wallpapers,
        ArulLineGlyph.ringtones,
        ArulLineGlyph.status,
      ]);
      expect(AppShell.statusBranch, 2);
    });

    testWidgets('flipped off while on Status → back to Wallpapers, after the '
        'frame', (tester) async {
      await pumpShell(tester, flag: true);
      await tester.tap(find.text('Status'));
      await tester.pump();
      await settle(tester);
      expect(currentBranch(tester), AppShell.statusBranch);

      container.read(_flagState.notifier).set(false);
      await tester.pump();
      await settle(tester);

      expect(currentBranch(tester), AppShell.wallpapersBranch);
      expect(dockGlyphs(tester), hasLength(2));
    });

    testWidgets('a status link with the tab on opens Status and is left for '
        'the reel to consume', (tester) async {
      await pumpShell(tester, flag: true);
      ArulDeepLink.requestTarget(const StatusLinkTarget('s1'));
      await tester.pump();
      await settle(tester);

      expect(currentBranch(tester), AppShell.statusBranch);
      expect(ArulDeepLink.pendingTarget, const StatusLinkTarget('s1'));
      expect(analytics.events, isEmpty);
    });

    testWidgets('a status link with the tab off is consumed, reported as '
        'status and lands on Wallpapers', (tester) async {
      ArulDeepLink.requestTarget(const TabLinkTarget(ArulTab.ringtones));
      await pumpShell(tester);
      await tester.pump();
      await settle(tester);
      analytics.events.clear();

      ArulDeepLink.requestTarget(
        const StatusLinkTarget('s1', source: DeepLinkSource.installReferrer),
      );
      await tester.pump();
      await settle(tester);

      expect(currentBranch(tester), AppShell.wallpapersBranch);
      expect(ArulDeepLink.pendingTarget, isNull);
      expect(analytics.events.single.$1, 'deep_link_opened');
      expect(analytics.events.single.$2, {
        'kind': 'status',
        'source': 'install_referrer',
        'status_id': 's1',
      });
    });

    testWidgets('a cold status link waits for the config rather than being '
        'dropped as off', (tester) async {
      ArulDeepLink.requestTarget(const StatusLinkTarget('s1'));
      await pumpShell(tester, flag: null);
      await tester.pump();
      expect(currentBranch(tester), AppShell.wallpapersBranch);
      expect(ArulDeepLink.pendingTarget, const StatusLinkTarget('s1'));

      container.read(_flagState.notifier).set(true);
      await tester.pump();
      await settle(tester);
      expect(currentBranch(tester), AppShell.statusBranch);
    });
  });

  group('two reels, one decoder budget', () {
    testWidgets('Wallpapers → Status releases the feed IN FULL before Status '
        'claims anything, with no grace', (tester) async {
      await pumpShell(tester, flag: true);
      await tester.tap(find.text('Status'));
      await tester.pump();
      await settle(tester);

      expect(
        log,
        containsAllInOrder([
          'feed:visible=false',
          'feed:release',
          'feed:released',
          'status:visible=true',
          'status:reclaim',
        ]),
      );
      expect(
        log.indexOf('feed:released'),
        lessThan(log.indexOf('status:visible=true')),
        reason: 'the status pool waits for the feed pool to be gone',
      );
      expect(video.calls, isNot(contains('leave')), reason: 'no grace here');
    });

    testWidgets('Status → Wallpapers is the same swap the other way', (
      tester,
    ) async {
      await pumpShell(tester, flag: true);
      await tester.tap(find.text('Status'));
      await settle(tester);
      log.clear();

      await tester.tap(find.text('Wallpapers'));
      await tester.pump();
      await settle(tester);

      expect(
        log,
        containsAllInOrder([
          'status:visible=false',
          'status:release',
          'status:released',
          'feed:visible=true',
          'feed:reclaim',
        ]),
      );
      expect(status.calls, isNot(contains('leave')));
    });

    testWidgets('any other switch keeps the grace', (tester) async {
      await pumpShell(tester, flag: true);
      await tester.tap(find.text('Ringtones'));
      await settle(tester);
      expect(video.calls, containsAllInOrder(['visible=false', 'leave']));
      expect(video.calls, isNot(contains('release')));

      await tester.tap(find.text('Status'));
      await settle(tester);
      expect(status.calls, containsAllInOrder(['visible=true', 'reclaim']));

      await tester.tap(find.text('Ringtones'));
      await settle(tester);
      expect(status.calls, containsAllInOrder(['visible=false', 'leave']));
      expect(status.calls, isNot(contains('release')));
    });
  });

  group('a screen pushed over the shell', () {
    testWidgets('Settings over Wallpapers stops the feed and frees it after '
        'the grace; Back restores it', (tester) async {
      await pumpShell(tester);
      log.clear();

      unawaited(router.push('/settings'));
      await tester.pumpAndSettle();
      expect(video.calls, ['visible=false', 'leave']);
      expect(video.visible, isFalse, reason: 'no play() while covered');

      router.pop();
      await tester.pumpAndSettle();
      expect(video.calls, [
        'visible=false',
        'leave',
        'visible=true',
        'reclaim',
      ]);
      expect(video.visible, isTrue);
    });

    testWidgets('Settings over Status silences the status reel, not the '
        'hidden feed', (tester) async {
      await pumpShell(tester, flag: true);
      await tester.tap(find.text('Status'));
      await settle(tester);
      expect(status.visible, isTrue);
      log.clear();

      unawaited(router.push('/settings'));
      await tester.pumpAndSettle();
      expect(status.calls, ['visible=false', 'leave']);
      expect(video.calls, isEmpty);

      router.pop();
      await tester.pumpAndSettle();
      expect(status.visible, isTrue);
    });
  });

  test('branchFor maps each tab onto its dock index', () {
    expect(AppShell.branchFor(ArulTab.wallpapers), AppShell.wallpapersBranch);
    expect(AppShell.branchFor(ArulTab.ringtones), AppShell.ringtonesBranch);
    expect(AppShell.branchFor(ArulTab.status), AppShell.statusBranch);
  });
}
