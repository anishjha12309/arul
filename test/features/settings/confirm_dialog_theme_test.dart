// The confirm dialog is built on the root navigator, under the app's theme. /premium pins LIGHT at
// its route, so a dark phone showed a dark card over the light paywall until the dialog took the
// caller's theme with it.

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/features/settings/presentation/confirm_dialog.dart';
import 'package:arul/theme/arul_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({ThemeData? pinned}) {
  final opener = Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showArulConfirmDialog(
            context,
            title: 'Cancel subscription?',
            message: 'Body',
            confirmLabel: 'Cancel it',
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  return MaterialApp(
    theme: ArulTheme.light(),
    darkTheme: ArulTheme.dark(),
    themeMode: ThemeMode.dark,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: pinned == null ? opener : Theme(data: pinned, child: opener),
  );
}

Color? _cardColor(WidgetTester tester) {
  final card = tester.widget<Container>(
    find
        .ancestor(
          of: find.text('Cancel subscription?'),
          matching: find.byType(Container),
        )
        .first,
  );
  return (card.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('a light-pinned caller gets the light card on a dark phone', (
    tester,
  ) async {
    await tester.pumpWidget(_host(pinned: ArulTheme.light()));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(_cardColor(tester), ArulTokens.cardBgLight);
  });

  testWidgets('everywhere else it still follows the app theme', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(_cardColor(tester), ArulTokens.darkSheetSurface);
  });
}
