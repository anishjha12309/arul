import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/widgets/cta_button.dart';
import 'package:arul/features/referral/presentation/share_moment_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required ThemeMode mode, required bool premium}) => ProviderScope(
  child: MaterialApp(
    themeMode: mode,
    theme: ThemeData.light(),
    darkTheme: ThemeData.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => ShareMomentSheet.show(
              context,
              title: "You're in",
              body:
                  'Arul Premium is active. Know someone who would love these '
                  'wallpapers? Send them one.',
              source: 'test',
              premium: premium,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  Future<void> open(
    WidgetTester tester, {
    required bool premium,
    required ThemeMode mode,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(mode: mode, premium: premium));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('premium celebration stays short and uses shrine chrome', (
    tester,
  ) async {
    await open(tester, premium: true, mode: ThemeMode.light);
    expect(find.text("You're in"), findsOneWidget);
    expect(find.text('Share Arul'), findsOneWidget);
    expect(find.byKey(const ValueKey('shrine-cta')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('default celebration remains unchanged in ${mode.name}', (
      tester,
    ) async {
      await open(tester, premium: false, mode: mode);
      expect(find.text("You're in"), findsOneWidget);
      expect(find.text('Share Arul'), findsOneWidget);
      expect(find.byKey(const ValueKey('shrine-cta')), findsNothing);
      expect(find.byType(CtaButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
