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
}) => ArulResubscribeView(
  monthlyPrice: '₹199',
  accessUntil: accessUntil,
  selectedUpiApp: app,
  canChangeUpiApp: canChange,
  purchaseBusy: busy,
  onBack: () {},
  onChangeUpiApp: () {},
  onResubscribe: () {},
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
}
