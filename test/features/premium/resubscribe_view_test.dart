import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/presentation/resubscribe_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _phonePe = UpiApp(packageName: 'com.phonepe.app', label: 'PhonePe');

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  // The paywall reads its copy from the ARBs -> without the delegates
  // `AppLocalizations.of` resolves to null and every test here dies on its null-check.
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: SafeArea(child: child)),
  ),
);

ArulResubscribeView _view({
  UpiApp? app = _phonePe,
  bool canChange = true,
  String? accessUntil = '12 Aug 2026',
  bool busy = false,
  String? resumeAppLabel,
  VoidCallback? onResume,
  VoidCallback? onResubscribe,
}) => ArulResubscribeView(
  monthlyPrice: '₹199',
  accessUntil: accessUntil,
  selectedUpiApp: app,
  canChangeUpiApp: canChange,
  purchaseBusy: busy,
  resumeAppLabel: resumeAppLabel,
  onResume: onResume,
  onBack: () {},
  onChangeUpiApp: () {},
  onResubscribe: onResubscribe ?? () {},
);

void main() {
  group('ArulResubscribeView', () {
    testWidgets('renders warning hero and exactly three billing rows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_view()));

      expect(find.text('Auto-renew is off'), findsOneWidget);
      expect(find.text('AUTO-RENEW OFF'), findsOneWidget);
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('Access until'), findsOneWidget);
      expect(find.text('Price'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides Pay using when no UPI app is installed', (tester) async {
      await tester.pumpWidget(_host(_view(app: null)));
      expect(find.text('Pay using'), findsNothing);
      expect(find.text('Change'), findsNothing);
    });

    testWidgets('one UPI app is displayed as a fact, not a choice', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_view(canChange: false)));
      expect(find.text('PhonePe'), findsOneWidget);
      expect(find.text('Change'), findsNothing);
      final gesture = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('resubscribe-upi-selector')),
      );
      expect(gesture.onTap, isNull);
    });

    testWidgets('omits a null access-until row', (tester) async {
      await tester.pumpWidget(_host(_view(accessUntil: null)));
      expect(find.text('Access until'), findsNothing);
      expect(find.text('12 Aug 2026'), findsNothing);
    });

    testWidgets('busy CTA is disabled, spins and fits a 4.7-inch screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_view(busy: true), scale: 1.3));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('shrine-cta-progress')),
        200,
      );

      expect(find.byKey(const ValueKey('shrine-cta-progress')), findsOneWidget);
      final gesture = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('shrine-cta')),
      );
      expect(gesture.onTap, isNull);
      expect(find.byType(ListView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // A resubscribe dies in the UPI handoff exactly as a first purchase does -> the same way back in.
  group('a resubscribe mandate waiting for approval', () {
    testWidgets('re-opens the app instead of buying again, and never says '
        'trial', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var resumed = 0;
      await tester.pumpWidget(
        _host(
          _view(
            resumeAppLabel: 'PhonePe',
            onResume: () => resumed++,
            onResubscribe: () => fail('the CTA must resume, never buy again'),
          ),
        ),
      );

      expect(find.text('Open PhonePe again'), findsOneWidget);
      expect(find.text('Resubscribe'), findsNothing);
      expect(
        find.text('Approve the payment in PhonePe to continue.'),
        findsOneWidget,
      );
      expect(find.textContaining('trial'), findsNothing);
      // Nothing to back out with — the order's own deadline retires it (owner's call).
      expect(find.text('Start over'), findsNothing);
      expect(find.byKey(const ValueKey('paywall-start-over')), findsNothing);
      // The selector keeps its affordance: picking another app abandons this order and starts a
      // fresh one there, which beats telling someone their one wallet is their only option.
      expect(find.text('Change'), findsOneWidget);
      expect(
        tester
            .widget<GestureDetector>(
              find.byKey(const ValueKey('resubscribe-upi-selector')),
            )
            .onTap,
        isNotNull,
      );

      await tester.tap(find.byKey(const ValueKey('shrine-cta')));
      expect(resumed, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
