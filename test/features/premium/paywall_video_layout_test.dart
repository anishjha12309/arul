import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/domain/onboarding_video.dart';
import 'package:arul/features/premium/presentation/onboarding_video_card.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `flutter test` ships Ahem, not the app's bundled families, so the paywall's
/// type has to be registered by hand before anything measures it — the whole
/// point here is real heights.
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

/// Every phone shape the app actually lands on, in logical pixels.
/// 360x640 is the floor — the smallest screen Android still ships in India.
/// Logical pixels, and these are the sizes INSIDE SafeArea — what the paywall
/// actually gets. The Nothing A001 is 1080x2392 at density 420, i.e. 411x911dp,
/// of which the status bar and the gesture pill take ~50; measuring the full
/// 911 is what hid a clipped feature label from this test once already.
const _devices = <String, Size>{
  'small_360x640': Size(360, 640),
  'small_360x600_bars': Size(360, 600),
  'common_360x800': Size(360, 800),
  'common_360x752_bars': Size(360, 752),
  'pixel_393x873': Size(393, 873),
  'a001_411x911': Size(411, 911),
  'a001_411x860_bars': Size(411, 860),
};

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: SafeArea(child: child)),
  ),
);

Widget _paywall({required bool withVideo}) => ArulPaywallView(
  trialEligible: true,
  monthlyPrice: '₹199',
  purchaseBusy: false,
  showSocialProof: true,
  // player: null is the real pre-decode state — poster only, no platform
  // channel, and exactly the geometry the card lays out on device.
  onboardingVideo: withVideo
      ? const ArulOnboardingVideoCard(
          player: null,
          source: OnboardingVideoSource(
            lang: 'ta',
            url: 'https://example.invalid/onboarding/ta.mp4',
          ),
        )
      : null,
  selectedUpiApp: const UpiApp(
    packageName: 'com.phonepe.app',
    label: 'PhonePe',
  ),
  canChangeUpiApp: true,
  onBack: () {},
  onChangeUpiApp: () {},
  onPurchase: () {},
);

void main() {
  setUpAll(_loadPaywallFonts);

  final outDir = Directory('build/paywall-shots');

  for (final MapEntry(key: name, value: size) in _devices.entries) {
    testWidgets('$name — the clip is fully on screen without scrolling', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: _host(_paywall(withVideo: true))),
      );
      await tester.pumpAndSettle();

      // 1. Nothing overflowed. A RenderFlex overflow paints the yellow stripe
      //    and is reported as an exception, which this catches for every size.
      expect(tester.takeException(), isNull, reason: '$name overflowed');

      // 2. The clip is on the first screenful — the owner's one hard
      //    requirement for this layout ("non-negotiable on the main visible
      //    screen in all devices"). Measured against the CTA, because the CTA
      //    is pinned to the bottom and everything above it is the fold.
      final clip = tester.getRect(find.byType(ArulOnboardingVideoCard));
      final cta = tester.getRect(find.text('Start Free Trial'));
      expect(
        clip.bottom,
        lessThanOrEqualTo(cta.top),
        reason: '$name: the clip runs under the pinned CTA',
      );
      // The clip's frame keeps its full 16:9 at EVERY size — it is never
      // cropped or scaled to buy room for the chrome (owner's call). A small
      // screen pays out of the offer panel's padding instead.
      final frame = tester.getRect(
        find.byKey(const Key('onboarding-video-frame')),
      );
      expect(
        frame.width / frame.height,
        closeTo(16 / 9, 0.02),
        reason: '$name: the clip frame is not 16:9',
      );
      expect(
        frame.width,
        greaterThan(size.width * 0.7),
        reason: '$name: the clip is not full width',
      );

      // 3. The price is still above the clip, which is the ordering the owner
      //    asked for (offer read first, clip as the proof under it).
      final price = tester.getRect(find.byType(PriceLockup));
      expect(price.bottom, lessThanOrEqualTo(clip.top), reason: '$name order');

      // 4. The feature labels are not sliced through the middle. They may sit
      //    below the fold entirely on a short screen — they are the one block
      //    allowed to scroll — but a label cut halfway through its second line
      //    reads as broken chrome rather than as more content (device
      //    2026-08-31: "Unlimited HD" with "Wallpapers" shaved off).
      final label = find.text('Unlimited HD Wallpapers');
      if (label.evaluate().isNotEmpty) {
        final labelRect = tester.getRect(label);
        final wholeLabelVisible = labelRect.bottom <= cta.top;
        final labelFullyBelowFold = labelRect.top >= cta.top;
        expect(
          wholeLabelVisible || labelFullyBelowFold,
          isTrue,
          reason: '$name: feature label is cut mid-word at the fold',
        );
      }

      // 5. And the CTA itself is on screen.
      expect(cta.bottom, lessThanOrEqualTo(size.height), reason: '$name CTA');

      // Dump a PNG so the composition can be eyeballed alongside the asserts.
      await tester.runAsync(() async {
        final image =
            await (tester.renderObject(find.byKey(boundary))
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ImageByteFormat.png);
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        File(
          '${outDir.path}/$name.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      });
    });
  }

  testWidgets('without a clip the handoff layout is untouched', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_paywall(withVideo: false)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The brand lockup is what the clip replaces; with no clip it must be back.
    expect(find.text('ARUL'), findsOneWidget);
    expect(find.byType(ArulOnboardingVideoCard), findsNothing);
  });
}
