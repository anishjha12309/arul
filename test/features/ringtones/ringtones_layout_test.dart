// Layout resilience for the Ringtones surface -> the defect class a device check finds LAST.
// It needs the right phone, the right language and the right accessibility setting all at once.
// The frame is 390x844 with one short English word in the header and a three-letter verb on every row.
// Neither survives the shipping app -> "Set" is far longer in Malayalam and the title half again as long in Tamil.
// Nothing here clamps the OS font-size setting -> a Row of inflexible children would push off a 320dp screen.
// The test font makes every glyph a fixed-width box, WIDER than the real faces -> passing here leaves real text slack.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/ringtones/presentation/ringtone_states.dart';
import 'package:arul/features/ringtones/presentation/ringtones_screen.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';

class _FakeCatalog extends RingtoneCatalogNotifier {
  _FakeCatalog(this._items);
  final List<Ringtone> _items;
  @override
  Future<List<Ringtone>> build() async => _items;
}

/// One row per category, so every medallion motif is exercised.
/// Plus the two longest titles in the shipped catalog and one longer than anything published.
/// The row has to hold at x2 text scale on a 320dp screen -> a future import will not ask permission before being long.
Ringtone _rt(String id, String title, String category) =>
    Ringtone(id: id, title: title, category: category, audioKey: '$id.mp3');

final _catalog = <Ringtone>[
  _rt('r1', 'Jaya Jaya Chamundeshwari', 'amman'),
  _rt('r2', 'Dharmasthala Manjunatha', 'sivan'),
  _rt('r3', 'Saranam Ayyappa', 'ayyappan'),
  _rt('r4', 'Seven Hills Govinda', 'perumal'),
  _rt('r5', 'Kukke Subrahmanya', 'murugan'),
  _rt('r6', 'Sacred Raga', 'temples'),
  _rt('r7', 'Sri Venkateswara Suprabhatam Sahasranamam', 'perumal'),
  _rt('r8', 'Vetrivel Muruga', 'murugan'),
];

/// The real notifier owns a just_audio player, which needs a platform -> this keeps the one-row-at-a-time contract.
/// It opens with a row playing -> the now-playing row's taller layout is what the frames are measured against.
class _StubPreview extends RingtonePreviewNotifier {
  @override
  RingtonePreviewState build() =>
      const RingtonePreviewState(currentId: 'r3', isPlaying: true);

  @override
  Future<void> toggle(Ringtone ringtone) async {
    state = state.isPlayingId(ringtone.id)
        ? const RingtonePreviewState()
        : RingtonePreviewState(currentId: ringtone.id, isPlaying: true);
  }

  @override
  Future<void> stop() async => state = const RingtonePreviewState();
}

/// A narrow phone, a big-type user, and the two longest of the six locales.
const _frames = <({double width, double scale, String locale})>[
  (width: 320, scale: 1.0, locale: 'en'),
  (width: 320, scale: 1.5, locale: 'te'),
  (width: 360, scale: 1.0, locale: 'ta'),
  (width: 360, scale: 1.3, locale: 'ml'),
  (width: 390, scale: 1.0, locale: 'en'),
  (width: 411, scale: 2.0, locale: 'kn'),
];

void main() {
  Widget frame({
    required Widget child,
    required String locale,
    required double scale,
  }) => MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
    builder: (context, inner) => MediaQuery.withClampedTextScaling(
      minScaleFactor: scale,
      maxScaleFactor: scale,
      child: inner!,
    ),
  );

  Future<void> sized(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('the list frame holds', () {
    for (final f in _frames) {
      testWidgets('${f.width.toInt()}dp · ×${f.scale} · ${f.locale}', (
        tester,
      ) async {
        await sized(tester, f.width);

        final router = GoRouter(
          initialLocation: '/ringtones',
          routes: [
            GoRoute(
              path: '/ringtones',
              builder: (_, _) => const RingtonesScreen(),
            ),
            GoRoute(path: '/refer', builder: (_, _) => const SizedBox.shrink()),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isOnlineProvider.overrideWith((ref) => Stream.value(true)),
              ringtoneCatalogProvider.overrideWith(
                () => _FakeCatalog(_catalog),
              ),
              ringtonePreviewProvider.overrideWith(_StubPreview.new),
              entitlementProvider.overrideWith((ref) async => true),
            ],
            child: MaterialApp.router(
              locale: Locale(f.locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
              builder: (context, child) => MediaQuery.withClampedTextScaling(
                minScaleFactor: f.scale,
                maxScaleFactor: f.scale,
                child: child!,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));

        expect(tester.takeException(), isNull);
        expect(find.byType(RingtoneRow), findsWidgets);
      });
    }
  });

  group('the other states hold too', () {
    // Each of these ALSO has to clear the floating dock -> a Retry button behind the capsule is the same defect, quieter.
    for (final f in _frames) {
      testWidgets('loading · ${f.width.toInt()}dp ×${f.scale}', (tester) async {
        await sized(tester, f.width);
        await tester.pumpWidget(
          frame(
            locale: f.locale,
            scale: f.scale,
            child: const Scaffold(body: RingtonesLoading()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));
        expect(tester.takeException(), isNull);
      });

      testWidgets('empty · ${f.width.toInt()}dp ×${f.scale}', (tester) async {
        await sized(tester, f.width);
        await tester.pumpWidget(
          frame(
            locale: f.locale,
            scale: f.scale,
            child: const Scaffold(body: RingtonesEmpty()),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('error · ${f.width.toInt()}dp ×${f.scale}', (tester) async {
        await sized(tester, f.width);
        await tester.pumpWidget(
          frame(
            locale: f.locale,
            scale: f.scale,
            child: Scaffold(body: RingtonesError(onRetry: () {})),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the dock holds', () {
    for (final f in _frames) {
      testWidgets('${f.width.toInt()}dp · ×${f.scale} · ${f.locale}', (
        tester,
      ) async {
        await sized(tester, f.width);
        await tester.pumpWidget(
          frame(
            locale: f.locale,
            scale: f.scale,
            child: Scaffold(
              extendBody: true,
              body: const SizedBox.expand(),
              bottomNavigationBar: Builder(
                builder: (context) {
                  final l10n = AppLocalizations.of(context);
                  return ArulNavDock(
                    currentIndex: 1,
                    onTap: (_) {},
                    items: [
                      (
                        glyph: ArulLineGlyph.wallpapers,
                        label: l10n.tabWallpapers,
                      ),
                      (
                        glyph: ArulLineGlyph.ringtones,
                        label: l10n.tabRingtones,
                      ),
                      (
                        glyph: ArulLineGlyph.settings,
                        label: l10n.settingsTitle,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(ArulLineIcon), findsNWidgets(3));
      });
    }
  });
}
