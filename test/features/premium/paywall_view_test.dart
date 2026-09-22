import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/presentation/paywall_ornaments.dart';
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
      // No installed UPI app → no selector row to show, and with no QR route either the CTA is dead.
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
      // Keyed, not typed: the busy indicator is the branded [ArulSpinner] and the key is what
      // `resubscribe_view_test` already finds the same widget by.
      final busy = find.byKey(const ValueKey('shrine-cta-progress'));
      expect(busy, findsOneWidget);
      await tester.tap(busy);
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

  // ─── No mandate-capable app on the phone ────────────────────────────────────
  // 13.4% of everyone who tapped Subscribe landed here. The hosted PhonePe page that used to catch
  // them completed 4 setups in 790, and the install links that replaced it asked someone mid-checkout
  // to go and fetch a payment app first. Both are gone: the CTA keeps its own words and opens the QR,
  // because a phone with nothing installed has exactly one way to pay and that is not a choice to
  // put in front of anyone.

  group('no app on the phone', () {
    Future<void> pumpNoApp(
      WidgetTester tester, {
      required bool trialEligible,
      VoidCallback? onPurchase,
      VoidCallback? onPayByQr,
      bool purchaseBusy = false,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: trialEligible,
            monthlyPrice: '₹199',
            purchaseBusy: purchaseBusy,
            showSocialProof: false,
            selectedUpiApp: null,
            canChangeUpiApp: false,
            onBack: () {},
            onChangeUpiApp: () {},
            onPurchase: onPurchase ?? () {},
            onPayByQr: onPayByQr,
          ),
        ),
      );
    }

    testWidgets('the CTA opens the QR and says nothing different about it', (
      tester,
    ) async {
      var qr = 0;
      var bought = 0;
      await pumpNoApp(
        tester,
        trialEligible: true,
        onPurchase: () => bought++,
        onPayByQr: () => qr++,
      );

      await tester.tap(find.text('Start Free Trial'));

      expect(qr, 1);
      // `onPurchase` would target a UPI app that is not on this phone.
      expect(bought, 0);
    });

    testWidgets('nothing sits above the CTA any more — no store links, no '
        'second line to read', (tester) async {
      await pumpNoApp(tester, trialEligible: true, onPayByQr: () {});

      expect(find.textContaining('Install'), findsNothing);
      expect(find.text('PhonePe'), findsNothing);
      expect(find.text('Google Pay'), findsNothing);
      expect(find.textContaining('scanning a QR'), findsNothing);
      // And no app row either: there is no app to name.
      expect(find.text('Selected UPI App'), findsNothing);
    });

    testWidgets('DEAD while the probe is still out — an empty list is not yet '
        'an answer', (tester) async {
      // Loading and "none installed" are both an empty list and mean opposite things. A live CTA
      // here would open a QR at someone who has PhonePe, one frame before the picker appears.
      var pressed = 0;
      await pumpNoApp(tester, trialEligible: true, onPurchase: () => pressed++);

      await tester.tap(find.text('Start Free Trial'));
      expect(pressed, 0);
    });

    testWidgets('a checkout already in flight cannot start a second one', (
      tester,
    ) async {
      // Otherwise the Worker refuses the repeat with 409 setup_in_progress, which users read as
      // payments being broken.
      var qr = 0;
      await pumpNoApp(
        tester,
        trialEligible: true,
        purchaseBusy: true,
        onPayByQr: () => qr++,
      );

      // Busy swaps the label for the spinner, so the button is found by type, not by its words.
      expect(find.text('Start Free Trial'), findsNothing);
      await tester.tap(find.byType(ShrineCta));
      expect(qr, 0);
    });

    testWidgets('the paid variant never promises a trial it cannot give', (
      tester,
    ) async {
      await pumpNoApp(tester, trialEligible: false, onPayByQr: () {});

      expect(find.text('Subscribe Now'), findsOneWidget);
      expect(find.text('Start Free Trial'), findsNothing);
    });
  });

  // ─── The mandate the user has not approved yet ──────────────────────────────
  // They came back from the UPI app without approving, and the order is STILL LIVE at PhonePe.
  // So the footer stops selling and starts pointing: one line saying what has to happen and the CTA
  // re-opening the app that holds the sheet. Nothing else — no way out to find, because the
  // deadline retires the order by itself (owner's call).

  group('the resumable footer', () {
    setUpAll(_loadPaywallFonts);

    Future<void> pumpResuming(
      WidgetTester tester, {
      bool trialEligible = true,
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: trialEligible,
            monthlyPrice: '₹199',
            purchaseBusy: false,
            showSocialProof: true,
            selectedUpiApp: const UpiApp(
              packageName: 'com.phonepe.app',
              label: 'PhonePe',
            ),
            canChangeUpiApp: true,
            resumeAppLabel: 'PhonePe',
            onResume: () {},
            onBack: () {},
            onChangeUpiApp: () {},
            onPurchase: () {},
          ),
        ),
      );
    }

    testWidgets('names the app in the CTA and in the one line under it', (
      tester,
    ) async {
      await pumpResuming(tester);

      expect(find.text('Open PhonePe again'), findsOneWidget);
      expect(
        find.text(
          'Approve the ₹2 verification in PhonePe to start your trial.',
        ),
        findsOneWidget,
      );
      // The sell is over — the reassurance line it replaced must be gone, not stacked with it.
      expect(find.textContaining('refunded instantly · Cancel'), findsNothing);
      // No way out to find: the footer is the line, the CTA and the chip, nothing more.
      expect(find.text('Start over'), findsNothing);
      expect(find.byKey(const ValueKey('paywall-start-over')), findsNothing);
      expect(find.text('Start Free Trial'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the paid variant never mentions a trial', (tester) async {
      await pumpResuming(tester, trialEligible: false);

      expect(
        find.text('Approve the payment in PhonePe to continue.'),
        findsOneWidget,
      );
      expect(find.textContaining('trial'), findsNothing);
    });

    testWidgets('the CTA resumes instead of buying again', (tester) async {
      var resumed = 0;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: true,
            monthlyPrice: '₹199',
            purchaseBusy: false,
            showSocialProof: true,
            selectedUpiApp: const UpiApp(
              packageName: 'com.phonepe.app',
              label: 'PhonePe',
            ),
            canChangeUpiApp: true,
            resumeAppLabel: 'PhonePe',
            onResume: () => resumed++,
            onBack: () {},
            onChangeUpiApp: () {},
            onPurchase: () => fail('the CTA must resume, never buy again'),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('shrine-cta')));
      expect(resumed, 1);
    });

    testWidgets('the UPI chip is still changeable — an open order is not a '
        'lock-in to one wallet', (tester) async {
      var changes = 0;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          ArulPaywallView(
            trialEligible: true,
            monthlyPrice: '₹199',
            purchaseBusy: false,
            showSocialProof: true,
            selectedUpiApp: const UpiApp(
              packageName: 'com.phonepe.app',
              label: 'PhonePe',
            ),
            canChangeUpiApp: true,
            resumeAppLabel: 'PhonePe',
            onResume: () {},
            onBack: () {},
            onChangeUpiApp: () => changes++,
            onPurchase: () {},
          ),
        ),
      );

      // The chip's own label, not the CTA's "Open PhonePe again".
      await tester.tap(find.text('PhonePe'));
      expect(
        changes,
        1,
        reason: 'the picker opens while resumable — switching is a real choice',
      );
      // The caret is the affordance -> it stays wherever the tap target is.
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
    });

    testWidgets('the whole footer still fits a 4.7" screen', (tester) async {
      await pumpResuming(tester, size: const Size(360, 640));

      expect(tester.takeException(), isNull);
      // The footer rule is the last thing in the pinned footer -> if it is on screen, so is
      // everything above it: the chip, the CTA and the one line that says what to approve.
      expect(
        tester
            .getRect(
              find.byWidgetPredicate(
                (w) =>
                    w is PaywallOrnamentImage &&
                    w.ornament == PaywallOrnament.footerRule,
              ),
            )
            .bottom,
        lessThanOrEqualTo(640),
      );
    });
  });
}
