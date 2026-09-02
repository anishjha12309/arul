// A pending target decides which dock branch is showing -> wiring a device cannot be asked about later.
// Content targets follow "peek, don't consume" -> the tab's screen consumes one once its catalog can resolve the id.
// A tab-only link consumes on switch.
// A real GoRouter + StatefulShellRoute, because `goBranch` is the thing under test.
// The branches are stand-ins -> the feed and the ringtone list have their own suites for what follows the switch.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/presentation/video_preload_controller.dart';
import 'package:arul/features/wallpapers/providers/video_preload_provider.dart';

/// The real controller talks to the native decoder pool on every branch change -> this one records only the ask.
class _StubVideo extends VideoPreloadController {
  _StubVideo()
    : super(
        cdnBaseUrl: 'https://cdn.test',
        prefetch: WallpaperPrefetchService(cdnBaseUrl: 'https://cdn.test'),
      );

  final calls = <String>[];

  @override
  Future<void> releaseDecoders() async => calls.add('release');

  @override
  void reclaimDecoders() => calls.add('reclaim');
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
}

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  late _StubVideo video;
  late _RecordingAnalytics analytics;

  Future<void> pumpShell(WidgetTester tester) async {
    video = _StubVideo();
    analytics = _RecordingAnalytics();
    final router = GoRouter(
      initialLocation: '/browse',
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
                  path: '/settings',
                  builder: (_, _) => const Text('settings'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // No onDispose -> the stub must never reach the native pool, not even on teardown.
          videoPreloadControllerProvider.overrideWith((_) => video),
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
    await tester.pump();
  }

  int currentBranch(WidgetTester tester) => tester
      .widget<AppShell>(find.byType(AppShell))
      .navigationShell
      .currentIndex;

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
    await tester.pump(const Duration(milliseconds: 400));

    expect(currentBranch(tester), AppShell.ringtonesBranch);
    expect(
      ArulDeepLink.pendingTarget,
      const RingtoneLinkTarget('r1'),
      reason: 'only PEEKED here — the list resolves the id',
    );
    expect(video.calls, contains('release'), reason: 'feed decoders freed');
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
    await tester.pump(const Duration(milliseconds: 400));

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
    await tester.pump(const Duration(milliseconds: 400));

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
    await tester.pump(const Duration(milliseconds: 400));
    expect(currentBranch(tester), AppShell.ringtonesBranch);

    ArulDeepLink.requestTarget(const WallpaperLinkTarget('w1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(currentBranch(tester), AppShell.wallpapersBranch);
    expect(
      ArulDeepLink.pendingTarget,
      const WallpaperLinkTarget('w1'),
      reason: 'the feed consumes it once its catalog is in',
    );
    expect(video.calls, contains('reclaim'));
  });

  test('branchFor maps each tab onto its dock index', () {
    expect(AppShell.branchFor(ArulTab.wallpapers), AppShell.wallpapersBranch);
    expect(AppShell.branchFor(ArulTab.ringtones), AppShell.ringtonesBranch);
  });
}
