// F11: at 360 dp wide and 1.3x font the pinned CTA grows tall enough to push the clip under the
// fold. The clip is never dropped: it pins above the CTA, scaled no lower than 100 dp tall.

import 'dart:io';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/domain/onboarding_video.dart';
import 'package:arul/features/premium/presentation/onboarding_video_card.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../l10n/support/load_real_fonts.dart';

Future<void> _paywallFonts() async {
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
  for (final e in families.entries) {
    final l = FontLoader(e.key);
    for (final p in e.value) {
      l.addFont(File(p).readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await l.load();
  }
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    await _paywallFonts();
  });
  for (final loc in ['en', 'ta', 'ml']) {
    for (final h in [640.0, 724.0, 800.0]) {
      testWidgets(
        '$loc 360x$h at 1.3x: the whole clip and the price sit above the CTA',
        (tester) async {
          tester.view.physicalSize = Size(360, h);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                locale: Locale(loc),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (c, child) => MediaQuery(
                  data: MediaQuery.of(c).copyWith(
                    textScaler: const TextScaler.linear(1.3),
                    padding: const EdgeInsets.only(top: 24, bottom: 24),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: SafeArea(
                    child: ArulPaywallView(
                      trialEligible: true,
                      monthlyPrice: '₹199',
                      purchaseBusy: false,
                      showSocialProof: true,
                      onboardingVideo: const ArulOnboardingVideoCard(
                        player: null,
                        source: OnboardingVideoSource(
                          lang: 'ta',
                          url: 'https://example.invalid/x.mp4',
                        ),
                      ),
                      selectedUpiApp: const UpiApp(
                        packageName: 'com.phonepe.app',
                        label: 'PhonePe',
                      ),
                      canChangeUpiApp: true,
                      onBack: () {},
                      onChangeUpiApp: () {},
                      onPurchase: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final frame = tester.getRect(
            find.byKey(const Key('onboarding-video-frame')),
          );
          final price = tester.getRect(find.byType(PriceLockup));
          final l10n = AppLocalizations.of(
            tester.element(find.byType(ArulPaywallView)),
          );
          final ctaTop = tester.getRect(find.text(l10n.premiumCtaTrial)).top;
          expect(
            frame.bottom,
            lessThanOrEqualTo(ctaTop),
            reason: 'clip under the CTA',
          );
          expect(
            frame.height,
            greaterThanOrEqualTo(100 - 0.5),
            reason: 'clip below its floor',
          );
          expect(frame.width / frame.height, closeTo(16 / 9, 0.02));
          expect(
            price.bottom,
            lessThanOrEqualTo(frame.top),
            reason: 'price not above the clip',
          );
        },
      );
    }
  }
}
