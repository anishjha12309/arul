import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:arul/theme/arul_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` ships Ahem, not the app's bundled families -> register the type by hand before measuring or rendering.
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

Widget _host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  // The paywall reads its copy from the ARBs -> without the delegates
  // `AppLocalizations.of` resolves to null and every test here dies on its null-check.
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SafeArea(child: child)),
);

ArulPaywallView _paywall({required bool trialEligible}) => ArulPaywallView(
  trialEligible: trialEligible,
  monthlyPrice: '₹199',
  purchaseBusy: false,
  showSocialProof: true,
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
  // ─── The price lockup ─────────────────────────────────────────────────────
  // The one piece of this screen with arithmetic behind it -> the rupee sign is 16px smaller and must land centred.
  // Gelasio carries Georgia's old-style figures -> a digit string's ink centre MOVES with the digits.
  // So "₹2" and "₹199" need different offsets -> a fixed nudge would be right for at most one price.

  group('PriceLockup ink metrics', () {
    test('a full-height rupee sits at half its own height', () {
      // ₹ spans baseline → 0.693em, so its ink centre is half of that.
      expect(PriceLockup.inkCentreEm('₹'), closeTo(0.3467, 0.0001));
    });

    test('descending figures pull the amount\'s centre down', () {
      // "199": 1 stops at x-height and 9 drops to -0.172 -> a LOWER centre than "11", which never crosses the baseline.
      expect(
        PriceLockup.inkCentreEm('199'),
        lessThan(PriceLockup.inkCentreEm('11')),
      );
      // "2" has no descender at all, so it sits highest of the three.
      expect(
        PriceLockup.inkCentreEm('2'),
        greaterThan(PriceLockup.inkCentreEm('199')),
      );
    });

    test('the offset actually centres the two glyphs', () {
      for (final amount in ['199', '2', '99', '1499', '249.50']) {
        final dy = PriceLockup.rupeeOffset('₹', amount);
        // Both sit on one baseline -> applying dy to the rupee must put the two ink centres in the same place.
        final rupeeCentre =
            PriceLockup.inkCentreEm('₹') * ArulTokens.paywallRupeeSize - dy;
        final amountCentre =
            PriceLockup.inkCentreEm(amount) * ArulTokens.paywallAmountSize;
        expect(rupeeCentre, closeTo(amountCentre, 0.001), reason: amount);
      }
    });

    test('the offset is not a constant — it tracks the digits', () {
      expect(
        PriceLockup.rupeeOffset('₹', '199'),
        isNot(closeTo(PriceLockup.rupeeOffset('₹', '2'), 0.5)),
      );
    });

    test('an unmeasurable amount degrades to the rupee\'s own centre', () {
      expect(PriceLockup.rupeeOffset('₹', '???'), closeTo(-5.547, 0.001));
    });
  });

  // The table above is only worth anything if it describes the font Flutter actually rasterises.
  // So this measures RENDERED pixels -> paint the lockup, find the ink blocks either side of the gap, compare centres.
  // It fails if the glyph table drifts from the bundled TTF, if Gelasio is swapped, or if the rupee falls back.
  // A system-font fallback on the rupee is the defect this whole lockup exists to prevent.
  group('PriceLockup renders centred', () {
    setUpAll(_loadPaywallFonts);

    const boundaryKey = ValueKey('lockup');

    Future<void> check(WidgetTester tester, String price) async {
      final symbol = price.substring(0, price.indexOf(RegExp(r'[0-9]')));
      final amount = price.substring(price.indexOf(RegExp(r'[0-9]')));

      await tester.pumpWidget(
        _host(
          Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: PriceLockup(price: price),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );

      late final List<int> pixels;
      late final int width;
      late final int height;
      const scale = 3.0;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: scale);
        final data = await image.toByteData(format: ImageByteFormat.rawRgba);
        pixels = data!.buffer.asUint8List();
        width = image.width;
        height = image.height;
      });

      // Ink = anything appreciably darker than the white ground.
      bool ink(int x, int y) => pixels[(y * width + x) * 4] < 200;

      // The two halves are located by the widgets' own rects, never by hunting for a blank column.
      // At 56pt the gap between two old-style figures can exceed the 4pt lockup gap -> a pixel heuristic splits wrong.
      final origin = tester.getTopLeft(find.byKey(boundaryKey));
      (double, double) inkBounds(Finder finder) {
        final rect = tester.getRect(finder);
        final from = ((rect.left - origin.dx) * scale).floor().clamp(0, width);
        final to = ((rect.right - origin.dx) * scale).ceil().clamp(0, width);
        var top = height, bottom = -1;
        for (var x = from; x < to; x++) {
          for (var y = 0; y < height; y++) {
            if (!ink(x, y)) continue;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
        expect(bottom, greaterThan(-1), reason: 'no ink under $finder');
        return (top.toDouble(), bottom.toDouble());
      }

      final (symbolTop, symbolBottom) = inkBounds(find.text(symbol));
      final (amountTop, amountBottom) = inkBounds(find.text(amount));

      final symbolCentre = (symbolTop + symbolBottom) / 2;
      final amountCentre = (amountTop + amountBottom) / 2;

      // 3px at pixelRatio 3 is one logical pixel -> the most an antialiased glyph edge can shift a measured centre.
      expect(
        symbolCentre,
        closeTo(amountCentre, 3),
        reason:
            '$price: rupee ink ${symbolTop.toInt()}..${symbolBottom.toInt()} '
            'vs amount ${amountTop.toInt()}..${amountBottom.toInt()}',
      );

      // And the rupee really is the smaller of the two.
      expect(symbolBottom - symbolTop, lessThan(amountBottom - amountTop));
    }

    testWidgets('₹199', (tester) => check(tester, '₹199'));
    testWidgets('₹2', (tester) => check(tester, '₹2'));
    testWidgets('₹1499', (tester) => check(tester, '₹1499'));
  });

  // ─── The two screens ──────────────────────────────────────────────────────

  group('ArulPaywallView', () {
    setUpAll(_loadPaywallFonts);

    testWidgets('the monthly screen states the price and the fixed fine print', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_paywall(trialEligible: false)));

      expect(find.text('₹'), findsOneWidget);
      expect(find.text('199'), findsOneWidget);
      expect(find.text('PER MONTH'), findsOneWidget);
      expect(find.text('Subscribe Now'), findsOneWidget);
      // Contractually fixed -> a reworded version is a compliance problem, not a copy tweak.
      expect(
        find.text('₹199/month via autopay. Cancel anytime.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the trial screen leads with ₹2 and names the refund', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_paywall(trialEligible: true)));

      expect(find.text('2'), findsOneWidget);
      expect(find.text('REFUNDED INSTANTLY'), findsOneWidget);
      expect(find.text('Start Free Trial'), findsOneWidget);
      expect(
        find.text('Then ₹199/month via autopay. Cancel anytime.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 4.7" screen scrolls rather than clipping the CTA', (
      tester,
    ) async {
      // The handoff's page is ~925 tall and this viewport is not -> the footer is pinned, so the buy button stays visible.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_paywall(trialEligible: false)));

      expect(tester.takeException(), isNull);
      final cta = tester.getRect(find.text('Subscribe Now'));
      expect(cta.bottom, lessThanOrEqualTo(640));
    });

    testWidgets('social proof is removable by config', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: false,
            monthlyPrice: '₹199',
            purchaseBusy: false,
            showSocialProof: false,
            selectedUpiApp: null,
            canChangeUpiApp: false,
            onBack: () {},
            onChangeUpiApp: () {},
            onPurchase: () {},
          ),
        ),
      );

      expect(
        find.textContaining('just applied a live wallpaper'),
        findsNothing,
      );
      // No installed UPI app → no selector row, and the CTA still stands.
      expect(find.text('Selected UPI App'), findsNothing);
      expect(find.text('Subscribe Now'), findsOneWidget);
    });

    testWidgets('a purchase in flight disables the CTA and spins', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var pressed = 0;
      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: false,
            monthlyPrice: '₹199',
            purchaseBusy: true,
            showSocialProof: true,
            selectedUpiApp: null,
            canChangeUpiApp: false,
            onBack: () {},
            onChangeUpiApp: () {},
            onPurchase: () => pressed++,
          ),
        ),
      );

      expect(find.text('Subscribe Now'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(CircularProgressIndicator));
      expect(pressed, 0);
    });

    testWidgets('the trial CTA also stays pinned on a 4.7" screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_paywall(trialEligible: true)));

      expect(tester.takeException(), isNull);
      final cta = tester.getRect(find.text('Start Free Trial'));
      expect(cta.bottom, lessThanOrEqualTo(640));
    });
  });
}
