import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/domain/onboarding_video.dart';
import 'package:arul/features/premium/presentation/onboarding_video_card.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:arul/features/premium/presentation/trial_return_page.dart';
import 'package:arul/features/premium/presentation/upi_option_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` ships Ahem, not the app's bundled families -> register the type by hand or the
/// heights are fiction.
Future<void> _loadPaywallFonts() async {
  const families = {
    'Cinzel': ['assets/fonts/Cinzel-Medium.ttf'],
    'Lora': [
      'assets/fonts/Lora-Regular.ttf',
      'assets/fonts/Lora-Medium.ttf',
      'assets/fonts/Lora-SemiBold.ttf',
      'assets/fonts/Lora-Italic.ttf',
    ],
    'Gelasio': ['assets/fonts/Gelasio-Regular.ttf'],
  };
  for (final MapEntry(key: family, value: paths) in families.entries) {
    final loader = FontLoader(family);
    for (final path in paths) {
      loader.addFont(
        File(path).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    }
    await loader.load();
  }
}

/// The screens Arul's signed-in users actually hold (PostHog `login_success`, 30 days to
/// 24 Sep 2026, in dp), less the ~24dp status bar SafeArea takes — the room the page really gets.
/// 360x724 alone is 5.3% of users and 360-wide is half of them; 320x638 is the smallest shape that
/// still counts in the hundreds.
const _devices = <String, Size>{
  'common_360x724': Size(360, 700),
  'common_360x800': Size(360, 776),
  'short_360x684': Size(360, 660),
  'small_320x638': Size(320, 614),
  'tall_384x853': Size(384, 829),
  'large_411x914': Size(411, 890),
};

const _locales = ['en', 'ta', 'te', 'kn', 'ml', 'hi'];

const _threeApps = [
  UpiApp(packageName: 'com.phonepe.app', label: 'PhonePe'),
  UpiApp(
    packageName: 'com.google.android.apps.nbu.paisa.user',
    label: 'Google Pay',
  ),
  UpiApp(packageName: 'net.one97.paytm', label: 'Paytm'),
];

const _sevenApps = [
  ..._threeApps,
  UpiApp(packageName: 'in.org.npci.upiapp', label: 'BHIM'),
  UpiApp(packageName: 'com.dreamplug.androidapp', label: 'CRED'),
  UpiApp(packageName: 'in.amazon.mShop.android.shopping', label: 'Amazon'),
  UpiApp(packageName: 'money.super.payments', label: 'super.money'),
];

Widget _host(Widget child, {required String locale, required double scale}) =>
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    );

Widget _page({
  List<UpiApp> apps = _threeApps,
  bool busy = false,
}) => ArulTrialReturnView(
  // player: null is the real pre-decode state -> poster only, no platform channel.
  clip: const ArulOnboardingVideoCard(
    key: ValueKey('return-video'),
    player: null,
    source: OnboardingVideoSource(
      lang: 'ta',
      url: 'https://example.invalid/onboarding/return/ta.mp4',
    ),
    poster: kReturnPoster,
    eventPrefix: 'return_video',
    padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
  ),
  apps: apps,
  selection: apps.first.packageName,
  lastUsedPackage: apps.first.packageName,
  busy: busy,
  onBack: () {},
  onSelect: (_) {},
  onStart: () {},
);

void main() {
  setUpAll(_loadPaywallFonts);

  final outDir = Directory('build/return-shots');

  for (final MapEntry(key: name, value: size) in _devices.entries) {
    for (final scale in [1.0, 1.3]) {
      for (final locale in _locales) {
        testWidgets('$name x$scale $locale — clip, chosen app and button all '
            'on the first screenful', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: _host(_page(), locale: locale, scale: scale),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull, reason: 'overflowed');

          final cta = tester.getRect(find.byType(ShrineCta));
          expect(cta.bottom, lessThanOrEqualTo(size.height), reason: 'CTA');

          // The clip keeps its full 16:9 and sits wholly above the pinned button, unscrolled.
          final frame = tester.getRect(
            find.byKey(const Key('onboarding-video-frame')),
          );
          expect(frame.width / frame.height, closeTo(16 / 9, 0.02));
          expect(frame.top, greaterThanOrEqualTo(0));
          expect(frame.bottom, lessThanOrEqualTo(cta.top), reason: 'clip');

          // The chosen app — the one the button acts on — is readable without a scroll.
          final chosen = tester.getRect(find.byType(UpiOptionRow).first);
          expect(chosen.bottom, lessThanOrEqualTo(cta.top), reason: 'row 1');

          await tester.runAsync(() async {
            final image =
                await (tester.renderObject(find.byKey(boundary))
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ImageByteFormat.png);
            if (!outDir.existsSync()) outDir.createSync(recursive: true);
            File(
              '${outDir.path}/${name}_x${scale}_$locale.png',
            ).writeAsBytesSync(data!.buffer.asUint8List());
          });
        });
      }
    }
  }

  testWidgets('seven apps on the smallest phone scroll under a pinned button', (
    tester,
  ) async {
    tester.view.physicalSize = _devices['small_320x638']!;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(_page(apps: _sevenApps), locale: 'ta', scale: 1.3),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final ctaBefore = tester.getRect(find.byType(ShrineCta));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    // The QR row is last and reachable; the button never moved.
    expect(find.byType(UpiQrOptionRow), findsOneWidget);
    final qr = tester.getRect(find.byType(UpiQrOptionRow));
    expect(qr.bottom, lessThanOrEqualTo(ctaBefore.top));
    expect(tester.getRect(find.byType(ShrineCta)), ctaBefore);
  });

  testWidgets('busy: rows answer nothing and the button spins', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        ArulTrialReturnView(
          clip: null,
          apps: _threeApps,
          selection: _threeApps.first.packageName,
          lastUsedPackage: null,
          busy: true,
          onBack: () {},
          onSelect: picked.add,
          onStart: () => picked.add('start'),
        ),
        locale: 'en',
        scale: 1,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Google Pay'));
    await tester.tap(find.byType(ShrineCta));
    await tester.pump();
    expect(picked, isEmpty);
    expect(find.byKey(const ValueKey('shrine-cta-progress')), findsOneWidget);
  });

  testWidgets('a row tap selects; only the button starts', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final events = <String>[];
    await tester.pumpWidget(
      _host(
        ArulTrialReturnView(
          clip: null,
          apps: _threeApps,
          selection: _threeApps.first.packageName,
          lastUsedPackage: null,
          busy: false,
          onBack: () {},
          onSelect: (s) => events.add('select:$s'),
          onStart: () => events.add('start'),
        ),
        locale: 'en',
        scale: 1,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Paytm'));
    await tester.tap(find.text('Pay with QR'));
    expect(events, ['select:net.one97.paytm', 'select:$kUpiPickQr']);
    await tester.tap(find.byType(ShrineCta));
    expect(events.last, 'start');
  });
}
