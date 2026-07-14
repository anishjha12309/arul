// Tests for the offline gate on the feed.
//
//   - FeedError renders offline copy vs the generic load-failure copy.
//   - FeedScreen: OFFLINE shows the offline FeedError even with a cached
//     catalog on hand (and the Apply/Share rail is unreachable), while ONLINE
//     the normal feed states render and the gate stays inert.
//
// The live-video pool is a native platform channel; here it is backed by fake
// channels (with null mock handlers) so building FeedScreen never touches a
// real plugin. The reel itself (video textures / cached images) needs a device
// and is out of scope — the online case is exercised via the normal empty state.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/wallpapers/data/feed_video_player.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/presentation/feed_screen.dart';
import 'package:arul/features/wallpapers/presentation/feed_states.dart';
import 'package:arul/features/wallpapers/presentation/video_preload_controller.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';
import 'package:arul/features/wallpapers/providers/video_preload_provider.dart';

Wallpaper _wp(String id) => Wallpaper.fromJson({
  'id': id,
  'title': id,
  'type': 'static',
  'category': 'murugan',
  'full_key': 'wallpapers/murugan/$id.jpg',
  'width': 1080,
  'height': 1920,
});

/// A catalog notifier that just yields a fixed list — no disk cache, no network.
class _FakeCatalog extends CatalogNotifier {
  _FakeCatalog(this._items);
  final List<Wallpaper> _items;
  @override
  Future<List<Wallpaper>> build() async => _items;
}

const _method = MethodChannel('arul_test/feed_video');
const _events = MethodChannel('arul_test/feed_video_events');

/// A VideoPreloadController wired to fake channels so it never hits the real
/// FeedVideoPlugin. The reel isn't built in these tests, so it only ever
/// constructs + disposes.
VideoPreloadController _testController() => VideoPreloadController(
  cdnBaseUrl: 'https://cdn.test',
  prefetch: WallpaperPrefetchService(cdnBaseUrl: 'https://cdn.test'),
  pool: FeedVideoPlayerPool.withChannels(
    _method,
    const EventChannel('arul_test/feed_video_events'),
  ),
);

void main() {
  const offlineTitle = 'No internet';
  const errorTitle = "Couldn't load wallpapers";

  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );

  group('FeedError copy', () {
    testWidgets('offline mode shows the "no internet" copy', (tester) async {
      await tester.pumpWidget(
        wrap(Scaffold(body: FeedError(offline: true, onRetry: () {}))),
      );
      expect(find.text(offlineTitle), findsOneWidget);
      expect(
        find.text('Turn on the internet to see wallpapers.'),
        findsOneWidget,
      );
      expect(find.text(errorTitle), findsNothing);
    });

    testWidgets('default mode keeps the generic load-failure copy', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(Scaffold(body: FeedError(onRetry: () {}))));
      expect(find.text(errorTitle), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.text(offlineTitle), findsNothing);
    });
  });

  group('FeedScreen offline gate', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<void> pumpFeed(
      WidgetTester tester, {
      required bool online,
      required List<Wallpaper> catalog,
    }) async {
      // Fake native channels: return null for every call/listen.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _method,
        (_) async => null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _events,
        (_) async => null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            isOnlineProvider.overrideWith((ref) => Stream.value(online)),
            catalogProvider.overrideWith(() => _FakeCatalog(catalog)),
            videoPreloadControllerProvider.overrideWith((ref) {
              final c = _testController();
              ref.onDispose(c.dispose);
              return c;
            }),
          ],
          child: wrap(const FeedScreen()),
        ),
      );
      // Let the isOnline stream + fake catalog resolve. NOT pumpAndSettle — the
      // header gift icon and loading pulse animate forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
    }

    testWidgets(
      'OFFLINE shows the offline state even with a cached catalog, and the '
      'Apply/Share rail is unreachable',
      (tester) async {
        await pumpFeed(
          tester,
          online: false,
          catalog: [_wp('a'), _wp('b')], // cached wallpapers ARE available
        );

        expect(find.text(offlineTitle), findsOneWidget);
        expect(find.text(errorTitle), findsNothing);
        // The reel (and thus the gated actions) must not be built offline.
        expect(find.text('Apply'), findsNothing);
        expect(find.text('Share'), findsNothing);
      },
    );

    testWidgets('ONLINE renders the normal feed state, gate inert', (
      tester,
    ) async {
      await pumpFeed(tester, online: true, catalog: const []);

      // Normal empty state renders; the offline gate does NOT fire.
      expect(find.text(offlineTitle), findsNothing);
      expect(find.text('Nothing here yet'), findsOneWidget);
    });
  });
}
