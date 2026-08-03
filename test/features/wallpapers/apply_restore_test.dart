// Tests for ApplyRestore — the read-back half of the post-apply restore
// (docs/edge-cases.md §Apply). The contract under guard:
//   - the saved page index is a position in the list the feed SERVES for the
//     saved chip, so it must be validated through feedOrder() — validating
//     against the raw catalog accepts indices that don't exist in a filtered
//     chip and restores the user onto a different wallpaper. That holds for
//     All's curated head as much as for its shuffled tail.
//   - the pending flags are consumed exactly once, even when the restore is
//     rejected, so a stale flag can never hijack every future cold start.
//   - the saved category chip is re-selected, so the feed lands on the
//     wallpapers the user actually left, not on "All".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 10 items: sivan has 4, so a raw-catalog index (0..9) is NOT always a valid
/// sivan-chip index (0..3) — the discriminator for the feedOrder contract.
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

  @override
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  }) {
    restoreCalls.add((index: index, category: category, wasLive: wasLive));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({_HostState host, ProviderContainer container, SharedPreferences prefs})
  >
  pumpHost(WidgetTester tester, Map<String, Object> savedFlags) async {
    SharedPreferences.setMockInitialValues(savedFlags);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(home: _Host()),
      ),
    );
    final host = tester.state<_HostState>(find.byType(_Host));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_Host)),
    );
    return (host: host, container: container, prefs: prefs);
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
      // 7 is a valid raw-catalog index (10 items) but sivan serves only 4 —
      // the exact confusion that restored users onto a different wallpaper.
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
    'an All index resolves through the CURATED order: index 0 is the curated '
    'head, not the first item of the shuffle',
    (tester) async {
      // temple0 sits mid-shuffle uncurated; a rank moves it to slot 0, which is
      // the slot the saved index refers to.
      final curated = [
        for (final w in _catalog)
          w.id == 'id-temple0' ? w.copyWith(feedRank: 10) : w,
      ];
      final all = WallpaperCategory.allSlug;
      final h = await pumpHost(tester, {
        appliedWallpaperPendingKey: true,
        pendingApplyPageIndexKey: 0,
        pendingApplyCategoryKey: all,
        pendingApplyIsLiveKey: false,
      });

      h.host.maybeRestoreAfterApply(curated);
      await tester.pump();

      expect(h.host.restoreCalls, [(index: 0, category: all, wasLive: false)]);
      expect(
        feedOrder(all, curated).first.id,
        'id-temple0',
        reason: 'the index the restore accepted must address the curated list',
      );
      expect(
        feedOrder(all, _catalog).first.id,
        isNot('id-temple0'),
        reason: '…and that is only meaningful because curation moved it',
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
}
