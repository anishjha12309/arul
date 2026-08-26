// Widget tests for the redesigned Ringtones screen. These cover the contracts a
// device can't be asked about later — the ones that live in wiring rather than
// in pixels:
//
//   - ONE row plays at a time. Tapping a second row moves the state off the
//     first; tapping the playing row clears it and asks the player to stop. The
//     row's whole now-playing look derives from that single value, so the test
//     asserts on the medallions' `playing` flags rather than on colours.
//   - Category chips filter the list, and only the list — no All/New anywhere.
//   - "Set" is gated: a free user never reaches setRingtone(), gets exactly one
//     `ringtone_set_blocked_premium`, and lands on /premium?source=ringtone_set.
//     A premium user goes straight through.
//
// The real RingtonePreviewNotifier owns a just_audio AudioPlayer, which needs a
// platform. It is replaced by a stub with the SAME toggle semantics that records
// what the screen asked it to do — the screen's wiring is what's under test, and
// the audio engine's own behaviour is not reachable from a test host anyway.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/ringtones/data/ringtone_set_service.dart';
import 'package:arul/features/ringtones/presentation/ringtone_tile.dart';
import 'package:arul/features/ringtones/presentation/ringtones_screen.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';
import 'package:arul/features/ringtones/providers/ringtone_set_provider.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

Ringtone _rt(String id, String title, String category) =>
    Ringtone(id: id, title: title, category: category, audioKey: '$id.mp3');

final _catalog = [
  _rt('r1', 'Kanda Sashti Kavasam', 'murugan'),
  _rt('r2', 'Om Namah Shivaya', 'sivan'),
  _rt('r3', 'Kolaru Pathigam', 'sivan'),
  _rt('r4', 'Aigiri Nandini', 'amman'),
];

class _FakeCatalog extends RingtoneCatalogNotifier {
  _FakeCatalog(this._items);
  final List<Ringtone> _items;
  @override
  Future<List<Ringtone>> build() async => _items;
}

/// The real notifier's toggle contract, without the audio engine: same track →
/// pause/resume, different track → the state moves. Records every halt so the
/// test can assert that clearing the row really did stop playback.
class _StubPreview extends RingtonePreviewNotifier {
  final halts = <String>[];

  @override
  RingtonePreviewState build() => const RingtonePreviewState();

  @override
  Future<void> toggle(Ringtone ringtone) async {
    if (state.currentId == ringtone.id) {
      if (state.isPlaying) {
        halts.add('pause:${ringtone.id}');
        state = state.copyWith(isPlaying: false);
      } else {
        state = state.copyWith(isPlaying: true);
      }
      return;
    }
    if (state.currentId != null) halts.add('stop:${state.currentId}');
    state = RingtonePreviewState(currentId: ringtone.id, isPlaying: true);
  }

  @override
  Future<void> stop() async {
    if (state.currentId != null) halts.add('stop:${state.currentId}');
    state = const RingtonePreviewState();
  }
}

/// Records the ringtones the set pipeline was actually asked to install. If the
/// premium gate works, a free user never adds one.
class _RecordingSet extends RingtoneSetNotifier {
  final installed = <String>[];

  @override
  Future<void> setRingtone(Ringtone ringtone, RingtoneTarget target) async {
    installed.add(ringtone.id);
  }
}

class _RecordingAnalytics implements AnalyticsService {
  final events = <String>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add(event);

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}
}

// ─── Harness ──────────────────────────────────────────────────────────────────

void main() {
  late _StubPreview preview;
  late _RecordingSet setter;
  late _RecordingAnalytics analytics;
  late List<String> paywallSources;

  /// Pumps the screen inside a real GoRouter (the screen reads
  /// `GoRouter.of(context)` for its stop-audio-on-leaving listener) with a
  /// /premium route that records the source it was opened with — so the gate is
  /// asserted through real navigation rather than a mock of it.
  Future<void> pumpScreen(
    WidgetTester tester, {
    List<Ringtone> catalog = const [],
    bool premium = false,
  }) async {
    preview = _StubPreview();
    setter = _RecordingSet();
    analytics = _RecordingAnalytics();
    paywallSources = [];
    // The deep-link consume clears its persisted copy through
    // installReferrerServiceProvider, which reads SharedPreferences.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final router = GoRouter(
      initialLocation: '/ringtones',
      routes: [
        GoRoute(path: '/ringtones', builder: (_, _) => const RingtonesScreen()),
        GoRoute(
          path: '/premium',
          builder: (_, state) {
            paywallSources.add(state.uri.queryParameters['source'] ?? '');
            return const SizedBox.shrink();
          },
        ),
        GoRoute(path: '/refer', builder: (_, _) => const SizedBox.shrink()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
          ringtoneCatalogProvider.overrideWith(() => _FakeCatalog(catalog)),
          ringtonePreviewProvider.overrideWith(() => preview),
          ringtoneSetProvider.overrideWith(() => setter),
          entitlementProvider.overrideWith((ref) async => premium),
          analyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    // NOT pumpAndSettle: the now-playing diya flickers forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  /// The ids of every row currently drawing its lit (now-playing) cover art.
  List<String> playingRows(WidgetTester tester) => [
    for (final row in tester.widgetList<RingtoneRow>(find.byType(RingtoneRow)))
      if (tester
          .widget<RingtoneTile>(
            find.descendant(
              of: find.byWidget(row),
              matching: find.byType(RingtoneTile),
            ),
          )
          .playing)
        row.ringtone.id,
  ];

  Finder playButtonOf(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(RingtoneRow)),
    matching: find.bySemanticsLabel('Preview'),
  );

  // The Set pill and the Earn chip are found through their labels rather than
  // their semantics: a Semantics whose label duplicates a Text child leaves the
  // label on the Text's node, so bySemanticsLabel does not match the wrapper.
  Finder setPillOf(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(RingtoneRow)),
    matching: find.widgetWithText(GestureDetector, 'Set'),
  );

  // ── One playing row at a time ──────────────────────────────────────────────

  group('now-playing is a single value', () {
    testWidgets('tapping a second row moves the state off the first', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog);
      expect(playingRows(tester), isEmpty, reason: 'nothing plays on open');

      await tester.tap(playButtonOf('Om Namah Shivaya'));
      await tester.pump();
      expect(playingRows(tester), ['r2']);

      await tester.tap(playButtonOf('Kolaru Pathigam'));
      await tester.pump();
      expect(
        playingRows(tester),
        ['r3'],
        reason: 'exactly one row may be lit, and it must be the new one',
      );
      expect(
        preview.halts,
        contains('stop:r2'),
        reason: 'the outgoing track has to actually stop, not just dim',
      );
    });

    testWidgets('tapping the playing row clears it and stops audio', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog);

      await tester.tap(playButtonOf('Kolaru Pathigam'));
      await tester.pump();
      expect(playingRows(tester), ['r3']);

      await tester.tap(playButtonOf('Kolaru Pathigam'));
      await tester.pump();
      expect(playingRows(tester), isEmpty, reason: 'no row stays highlighted');
      expect(preview.halts, contains('pause:r3'));
    });

    testWidgets('leaving the ringtones location stops preview audio', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog);
      await tester.tap(playButtonOf('Kolaru Pathigam'));
      await tester.pump();
      expect(preview.state.currentId, 'r3');

      // The Earn chip pushes /refer OVER this screen — the IndexedStack-style
      // keep-alive means nothing disposes, so only the route listener can
      // silence the audio.
      await tester.tap(find.widgetWithText(GestureDetector, 'Earn'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(preview.state.currentId, isNull);
      expect(preview.halts, contains('stop:r3'));
    });
  });

  // ── Category filtering ─────────────────────────────────────────────────────

  group('category chips', () {
    testWidgets('selecting a category filters the list', (tester) async {
      await pumpScreen(tester, catalog: _catalog);

      // All, up front.
      expect(find.byType(RingtoneRow), findsNWidgets(4));

      await tester.tap(find.widgetWithText(GestureDetector, 'Sivan').first);
      await tester.pump();

      expect(find.byType(RingtoneRow), findsNWidgets(2));
      expect(find.text('Om Namah Shivaya'), findsOneWidget);
      expect(find.text('Kolaru Pathigam'), findsOneWidget);
      expect(find.text('Kanda Sashti Kavasam'), findsNothing);
      expect(find.text('Aigiri Nandini'), findsNothing);
    });

    testWidgets('All restores the whole list, and there is no New tab', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog);

      await tester.tap(find.widgetWithText(GestureDetector, 'Amman').first);
      await tester.pump();
      expect(find.byType(RingtoneRow), findsOneWidget);

      await tester.tap(find.widgetWithText(GestureDetector, 'All').first);
      await tester.pump();
      expect(find.byType(RingtoneRow), findsNWidgets(4));

      // Category is THE browse axis (CLAUDE.md §5b).
      expect(find.text('New'), findsNothing);
      expect(find.text('Live'), findsNothing);
    });

    testWidgets('chips come from the catalog, never a hardcoded list', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: [_rt('r9', 'Bhajan', 'ganesha')]);

      expect(find.widgetWithText(GestureDetector, 'Ganesha'), findsWidgets);
      expect(find.widgetWithText(GestureDetector, 'Murugan'), findsNothing);
    });
  });

  // ── The premium gate ───────────────────────────────────────────────────────

  group('Set is premium-gated', () {
    testWidgets('a free user is blocked, tracked once, and sent to /premium', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog, premium: false);

      await tester.tap(setPillOf('Kolaru Pathigam'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        setter.installed,
        isEmpty,
        reason: 'the set pipeline must never start for a free user',
      );
      expect(analytics.events, ['ringtone_set_blocked_premium']);
      expect(paywallSources, ['ringtone_set']);
    });

    testWidgets('a premium user goes straight through to the set pipeline', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: _catalog, premium: true);

      await tester.tap(setPillOf('Kolaru Pathigam'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(setter.installed, ['r3']);
      expect(analytics.events, isEmpty);
      expect(paywallSources, isEmpty);
    });

    testWidgets('the gate AWAITS the entitlement: a loading read never bounces '
        'a paying user', (tester) async {
      // Same contract as ensure_premium_test, asserted through the real button:
      // the gate may only answer after the entitlement read settles.
      final entitled = Completer<bool>();
      preview = _StubPreview();
      setter = _RecordingSet();
      analytics = _RecordingAnalytics();
      paywallSources = [];

      final router = GoRouter(
        initialLocation: '/ringtones',
        routes: [
          GoRoute(
            path: '/ringtones',
            builder: (_, _) => const RingtonesScreen(),
          ),
          GoRoute(
            path: '/premium',
            builder: (_, state) {
              paywallSources.add(state.uri.queryParameters['source'] ?? '');
              return const SizedBox.shrink();
            },
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isOnlineProvider.overrideWith((ref) => Stream.value(true)),
            ringtoneCatalogProvider.overrideWith(() => _FakeCatalog(_catalog)),
            ringtonePreviewProvider.overrideWith(() => preview),
            ringtoneSetProvider.overrideWith(() => setter),
            entitlementProvider.overrideWith((ref) => entitled.future),
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
      await tester.pump(const Duration(milliseconds: 30));

      await tester.tap(setPillOf('Kolaru Pathigam'));
      await tester.pump();
      await tester.pump();

      expect(paywallSources, isEmpty, reason: 'no answer while still loading');
      expect(analytics.events, isEmpty);

      entitled.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(setter.installed, ['r3']);
      expect(paywallSources, isEmpty);
    });
  });

  // ── Layout: the floating dock must never eat the last row ──────────────────

  testWidgets('with no dock overhead, the list reserves nothing for one', (
    tester,
  ) async {
    // The screen is pumped without an AppShell here, which is exactly the case
    // that used to strand 120px of dead space at the bottom of a pushed route.
    await pumpScreen(tester, catalog: _catalog);

    final list = tester.widget<ListView>(find.byType(ListView).last);
    expect(
      list.padding,
      isA<EdgeInsets>().having((e) => e.bottom, 'bottom inset', 0),
    );
  });

  testWidgets('inside the shell it reserves the dock its full clearance', (
    tester,
  ) async {
    late double clearance;

    // A real shell, because the rule is "is there an AppShell above me" and a
    // stub would be testing the stub. This doubles as a smoke test that the
    // shell and its dock build at all.
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigationShell) =>
              AppShell(navigationShell: navigationShell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/a',
                  builder: (context, _) {
                    clearance = AppShell.dockClearance(context);
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(
      clearance,
      greaterThanOrEqualTo(120),
      reason: "the handoff's 120, plus whatever the gesture bar takes",
    );
  });

  // ── Deep link ──────────────────────────────────────────────────────────────
  // A ringtone ad link (`/r/<id>`, `fb…://open?ringtone_id=`) lands here: the
  // row is scrolled to the top of ALL, the pref copy is cleared, and the
  // GA4-only landing event fires. Nothing auto-plays.

  group('deep link', () {
    setUp(ArulDeepLink.reset);
    tearDown(ArulDeepLink.reset);

    /// A catalog long enough that the target row is off-screen at the top.
    final long = [
      for (var i = 0; i < 30; i++)
        _rt('r$i', 'Track $i', i.isEven ? 'sivan' : 'amman'),
    ];

    testWidgets('scrolls the requested row to the top of All', (tester) async {
      ArulDeepLink.requestTarget(const RingtoneLinkTarget('r20'));
      await pumpScreen(tester, catalog: long);
      await tester.pump(); // the post-frame jump

      final list = tester.widget<ListView>(find.byType(ListView).last);
      final extent = RingtoneRow.extent + 10;
      expect(list.controller?.offset, 20 * extent);
      // The target row is the first one laid out at the top edge.
      final rowTop = tester.getTopLeft(
        find.ancestor(
          of: find.text('Track 20'),
          matching: find.byType(RingtoneRow),
        ),
      );
      final listTop = tester.getTopLeft(find.byType(ListView).last);
      expect(rowTop.dy, closeTo(listTop.dy, 0.01));
      expect(ArulDeepLink.pendingTarget, isNull, reason: 'consumed');
      expect(analytics.events, contains('deep_link_opened'));
    });

    testWidgets('lands on All even when another chip was selected', (
      tester,
    ) async {
      await pumpScreen(tester, catalog: long);
      await tester.tap(find.widgetWithText(GestureDetector, 'Amman').first);
      await tester.pump();
      expect(find.text('Track 20'), findsNothing, reason: 'r20 is sivan');

      ArulDeepLink.requestTarget(const RingtoneLinkTarget('r20'));
      await tester.pump(); // listener → setState → consume + select(All)
      await tester.pump(); // All list built → jump scheduled
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(RingtonesScreen)),
      );
      expect(
        container.read(selectedRingtoneCategoryProvider),
        WallpaperCategory.allSlug,
      );
      final list = tester.widget<ListView>(find.byType(ListView).last);
      expect(list.controller?.offset, 20 * (RingtoneRow.extent + 10));
    });

    testWidgets('an unknown id is silently ignored', (tester) async {
      ArulDeepLink.requestTarget(const RingtoneLinkTarget('gone'));
      await pumpScreen(tester, catalog: long);
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView).last);
      expect(list.controller?.offset, 0);
      expect(ArulDeepLink.pendingTarget, isNull, reason: 'still consumed');
      expect(analytics.events, isNot(contains('deep_link_opened')));
    });

    testWidgets('a pending WALLPAPER passes through untouched', (tester) async {
      // The feed owns that one; this tab must not eat it.
      ArulDeepLink.requestTarget(const WallpaperLinkTarget('w1'));
      await pumpScreen(tester, catalog: long);
      await tester.pump();

      expect(ArulDeepLink.pendingTarget, const WallpaperLinkTarget('w1'));
    });
  });
}
