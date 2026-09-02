// ApplyRestore is the read-back half of the post-apply restore (docs/edge-cases.md §Apply).
// The saved page index is a position in the list the feed SERVES for the saved chip -> validate it through feedOrder().
// Validating against the raw catalog accepts indices a filtered chip lacks -> the user restores onto another wallpaper.
// That holds for All's curated head as much as for its shuffled tail.
// The pending flags are consumed exactly once, even when the restore is rejected -> no stale flag hijacks a cold start.
// The saved category chip is re-selected -> the feed lands on the wallpapers the user left, not on "All".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/wallpapers/presentation/apply_restore.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_apply_provider.dart';

Wallpaper _wp(String stem, String category) => Wallpaper.fromJson({
  'id': 'id-$stem',
  'title': stem,
  'type': 'static',
  'category': category,
  'full_key': 'wallpapers/$category/$stem.jpg',
  'width': 1080,
  'height': 1920,
});

/// 10 items with 4 in sivan -> a raw-catalog index (0..9) is NOT always a valid sivan-chip index (0..3).
/// That gap is the discriminator for the feedOrder contract.
final _catalog = [
  for (var i = 0; i < 4; i++) _wp('sivan$i', 'sivan'),
  for (var i = 0; i < 2; i++) _wp('amman$i', 'amman'),
  for (var i = 0; i < 2; i++) _wp('murugan$i', 'murugan'),
  _wp('perumal0', 'perumal'),
  _wp('temple0', 'temples'),
];

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with ApplyRestore<_Host> {
  final restoreCalls = <({int index, String category, bool wasLive})>[];
  final jumpCalls = <int>[];

  @override
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  }) {
    restoreCalls.add((index: index, category: category, wasLive: wasLive));
  }

  @override
  void jumpFeedTo({required int index}) => jumpCalls.add(index);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Records every `track()` so the GA4-only landing event can be asserted.
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
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      _HostState host,
      ProviderContainer container,
      SharedPreferences prefs,
      _RecordingAnalytics analytics,
    })
  >
  pumpHost(WidgetTester tester, Map<String, Object> savedFlags) async {
    SharedPreferences.setMockInitialValues(savedFlags);
    final prefs = await SharedPreferences.getInstance();
    final analytics = _RecordingAnalytics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: const MaterialApp(home: _Host()),
      ),
    );
    final host = tester.state<_HostState>(find.byType(_Host));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_Host)),
    );
    return (
      host: host,
      container: container,
      prefs: prefs,
      analytics: analytics,
    );
  }

  testWidgets('no pending flag → no restore, feed untouched', (tester) async {
    final h = await pumpHost(tester, {});
    h.host.maybeRestoreAfterApply(_catalog);
    await tester.pump();
    expect(h.host.restoreCalls, isEmpty);
  });

  testWidgets('valid saved position restores: chip re-selected, pager jumped, '
      'flags consumed', (tester) async {
    final h = await pumpHost(tester, {
      appliedWallpaperPendingKey: true,
      pendingApplyPageIndexKey: 2,
      pendingApplyCategoryKey: 'sivan',
      pendingApplyIsLiveKey: true,
    });

    h.host.maybeRestoreAfterApply(_catalog);
    await tester.pump(); // run the post-frame callback

    expect(h.host.restoreCalls, [(index: 2, category: 'sivan', wasLive: true)]);
    expect(
      h.container.read(selectedCategoryProvider),
      'sivan',
      reason: 'the feed must land on the chip the user left, not All',
    );
    expect(h.prefs.getBool(appliedWallpaperPendingKey), isNull);
    expect(h.prefs.getInt(pendingApplyPageIndexKey), isNull);
  });

  testWidgets(
    'the saved index is validated through feedOrder, not the raw catalog: '
    'an index past the filtered chip is rejected even though the catalog '
    'is longer',
    (tester) async {
      // 7 is a valid raw-catalog index but sivan serves only 4 -> the exact confusion that restored the wrong wallpaper.
      final h = await pumpHost(tester, {
        appliedWallpaperPendingKey: true,
        pendingApplyPageIndexKey: 7,
        pendingApplyCategoryKey: 'sivan',
        pendingApplyIsLiveKey: false,
      });

      h.host.maybeRestoreAfterApply(_catalog);
      await tester.pump();

      expect(h.host.restoreCalls, isEmpty);
      expect(
        h.prefs.getBool(appliedWallpaperPendingKey),
        isNull,
        reason: 'flags are consumed even when the restore is rejected',
      );
    },
  );

  testWidgets(
    'an All-chip index at the tail is valid — All serves the whole catalog '
    '(shuffled), so its bounds are the full length',
    (tester) async {
      final all = WallpaperCategory.allSlug;
      final h = await pumpHost(tester, {
        appliedWallpaperPendingKey: true,
        pendingApplyPageIndexKey: _catalog.length - 1,
        pendingApplyCategoryKey: all,
        pendingApplyIsLiveKey: false,
      });

      h.host.maybeRestoreAfterApply(_catalog);
      await tester.pump();

      expect(h.host.restoreCalls, [
        (index: _catalog.length - 1, category: all, wasLive: false),
      ]);
    },
  );

  testWidgets(
    'an All index resolves through the POPULARITY order: index 0 is the '
    'most-applied wallpaper, not the newest one',
    (tester) async {
      // temple0 sits last in catalog order but applies move it to slot 0 -> that is the slot the saved index refers to.
      // This is why apply_restore goes through feedOrder() -> a restart landing on the wrong wallpaper is the bug.
      final applied = [
        for (final w in _catalog)
          w.id == 'id-temple0' ? w.copyWith(applyCount: 12) : w,
      ];
      final all = WallpaperCategory.allSlug;
      final h = await pumpHost(tester, {
        appliedWallpaperPendingKey: true,
        pendingApplyPageIndexKey: 0,
        pendingApplyCategoryKey: all,
        pendingApplyIsLiveKey: false,
      });

      h.host.maybeRestoreAfterApply(applied);
      await tester.pump();

      expect(h.host.restoreCalls, [(index: 0, category: all, wasLive: false)]);
      expect(
        feedOrder(all, applied).first.id,
        'id-temple0',
        reason: 'the index the restore accepted must address the served list',
      );
      expect(
        feedOrder(all, _catalog).first.id,
        isNot('id-temple0'),
        reason: '…and that is only meaningful because the applies moved it',
      );
    },
  );

  testWidgets(
    'a category no longer in the catalog restores nothing (empty feed list) '
    'and still consumes the flags',
    (tester) async {
      final h = await pumpHost(tester, {
        appliedWallpaperPendingKey: true,
        pendingApplyPageIndexKey: 0,
        pendingApplyCategoryKey: 'ganesha',
        pendingApplyIsLiveKey: false,
      });

      h.host.maybeRestoreAfterApply(_catalog);
      await tester.pump();

      expect(h.host.restoreCalls, isEmpty);
      expect(h.prefs.getBool(appliedWallpaperPendingKey), isNull);
    },
  );

  testWidgets('the restore check runs at most once per screen life', (
    tester,
  ) async {
    final h = await pumpHost(tester, {
      appliedWallpaperPendingKey: true,
      pendingApplyPageIndexKey: 1,
      pendingApplyCategoryKey: 'amman',
      pendingApplyIsLiveKey: false,
    });

    h.host.maybeRestoreAfterApply(_catalog);
    await tester.pump();
    // A catalog revalidate calls this again with fresh data — must be a no-op.
    h.host.maybeRestoreAfterApply(_catalog);
    await tester.pump();

    expect(h.host.restoreCalls, hasLength(1));
  });

  // ── Deep link ──────────────────────────────────────────────────────────────
  // The other thing that turns a saved reference into a page index -> it shares the feedOrder() contract above.
  // An id resolved against the raw catalog would open a DIFFERENT wallpaper than the link named.
  group('deep link', () {
    setUp(ArulDeepLink.reset);
    tearDown(ArulDeepLink.reset);

    testWidgets('opens the requested wallpaper on All, at its served index', (
      tester,
    ) async {
      // Give temple0 the applies so All's popularity order puts it first.
      // The index handed to the pager must be its position in THAT list, not in the catalog, where it is last.
      final catalog = [
        for (final w in _catalog)
          w.id == 'id-temple0' ? w.copyWith(applyCount: 9) : w,
      ];
      ArulDeepLink.request('id-temple0');
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(catalog);
      await tester.pump();

      expect(h.host.jumpCalls, [0]);
      expect(
        h.container.read(selectedCategoryProvider),
        WallpaperCategory.allSlug,
        reason: 'a link must never drop the user into a filtered chip',
      );
      expect(
        feedOrder(WallpaperCategory.allSlug, catalog).first.id,
        'id-temple0',
      );
    });

    testWidgets('an unknown id is silently ignored, not an error', (
      tester,
    ) async {
      // The wallpaper may have been unpublished since the link was shared.
      ArulDeepLink.request('id-that-was-deleted');
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.host.jumpCalls, isEmpty);
    });

    testWidgets('the target is consumed exactly once', (tester) async {
      // A catalog revalidate calls this again with fresh data -> a target left behind would drag the user back every time.
      ArulDeepLink.request('id-temple0');
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();
      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.host.jumpCalls, hasLength(1));
      expect(ArulDeepLink.consumeWallpaper(), isNull);
    });

    testWidgets('a pending RINGTONE passes through the feed untouched', (
      tester,
    ) async {
      // The feed builds before the shell switches to Ringtones -> its wallpaper-typed take must leave a ringtone link alone.
      // It must not clear the persisted copy either.
      ArulDeepLink.requestTarget(const RingtoneLinkTarget('id-ring0'));
      final h = await pumpHost(tester, {
        'pending_deeplink_ringtone': 'id-ring0',
      });

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.host.jumpCalls, isEmpty);
      expect(ArulDeepLink.pendingTarget, const RingtoneLinkTarget('id-ring0'));
      expect(h.prefs.getString('pending_deeplink_ringtone'), 'id-ring0');
    });

    testWidgets('opening reports deep_link_opened with the link\'s source', (
      tester,
    ) async {
      // GA4-only: the event answers "which channel lands people on content".
      ArulDeepLink.requestTarget(
        const WallpaperLinkTarget('id-temple0', source: DeepLinkSource.meta),
      );
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.host.jumpCalls, hasLength(1));
      expect(h.analytics.events.single.$1, 'deep_link_opened');
      expect(h.analytics.events.single.$2, {
        'kind': 'wallpaper',
        'source': 'meta',
        'wallpaper_id': 'id-temple0',
      });
    });

    testWidgets('a target parked AFTER the first catalog still opens', (
      tester,
    ) async {
      // Two links land here LATE by design -> an App Link tapped while the app is warm, and a Google Ads deferred link.
      // GA4F fetches the deferred one over the network and can deliver at any point -> a once-per-mount flag ate both.
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();
      expect(h.host.jumpCalls, isEmpty);

      ArulDeepLink.request('id-temple0');
      h.host.maybeOpenDeepLink(_catalog);
      // The feed calls this from build(), so its post-frame callback always has a frame -> nothing is dirty here.
      tester.element(find.byType(_Host)).markNeedsBuild();
      await tester.pump();

      expect(h.host.jumpCalls, hasLength(1));
    });

    testWidgets('consuming clears the deferred copy so it cannot re-fire on '
        'the next launch', (tester) async {
      // main.dart seeds ArulDeepLink AND leaves the pref in place -> either can win the startup race.
      // Consuming one without the other would re-open this wallpaper next launch.
      ArulDeepLink.request('id-temple0');
      final h = await pumpHost(tester, {
        'pending_deeplink_wallpaper': 'id-temple0',
      });

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.prefs.getString('pending_deeplink_wallpaper'), isNull);
    });

    testWidgets('does nothing when no link asked for anything', (tester) async {
      final h = await pumpHost(tester, {});

      h.host.maybeOpenDeepLink(_catalog);
      await tester.pump();

      expect(h.host.jumpCalls, isEmpty);
    });
  });
}
