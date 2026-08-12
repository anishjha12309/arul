import 'dart:io';

import 'package:arul/features/premium/presentation/member_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadPremiumFonts() async {
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
        File(path).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    await loader.load();
  }
}

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SafeArea(child: child)),
  ),
);

ArulMemberView _view({
  required bool trialing,
  String? renewalDate = '13 Aug 2026',
  bool cancelBusy = false,
  VoidCallback? onCancel,
}) => ArulMemberView(
  trialing: trialing,
  renewalDate: renewalDate,
  cancelBusy: cancelBusy,
  onBack: () {},
  onCancel: onCancel ?? () {},
);

void main() {
  setUpAll(_loadPremiumFonts);

  group('ArulMemberView', () {
    testWidgets('active state fits a large phone and renders member copy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_view(trialing: false)));

      expect(find.text("You're a member"), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('Renews on'), findsOneWidget);
      expect(find.text('13 Aug 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('trial state scrolls without overflow on a 4.7-inch phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_view(trialing: true), textScale: 1.3));

      expect(find.text("You're on the free trial"), findsOneWidget);
      expect(find.text('FREE TRIAL'), findsOneWidget);
      expect(find.text('Trial ends'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('omits the date row when the renewal date is null', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_view(trialing: false, renewalDate: null)));

      expect(find.text('Renews on'), findsNothing);
      expect(find.text('13 Aug 2026'), findsNothing);
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('busy cancel action is disabled and shows a spinner', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var presses = 0;

      await tester.pumpWidget(
        _host(
          _view(trialing: true, cancelBusy: true, onCancel: () => presses++),
        ),
      );

      expect(find.text('Cancel subscription'), findsNothing);
      expect(
        find.byKey(const ValueKey('member-cancel-progress')),
        findsOneWidget,
      );
      final gesture = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('member-cancel-button')),
      );
      expect(gesture.onTap, isNull);
      expect(presses, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
