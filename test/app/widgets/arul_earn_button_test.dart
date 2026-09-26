// The button's Semantics excludes its GestureDetector child, so the tap action has to be
// re-declared on the Semantics node itself, same as every other excludeSemantics site.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/widgets/arul_earn_button.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('exposes a tap action and fires onTap once per press', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    late String label;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) {
            label = AppLocalizations.of(context).earn;
            return ArulEarnButton(onTap: () => taps++);
          },
        ),
      ),
    );

    // The button's own root widget (Transform.translate) is not the Semantics boundary, so the
    // node has to be located by its label rather than by type.
    expect(
      tester.getSemantics(find.bySemanticsLabel(label)),
      matchesSemantics(label: label, isButton: true, hasTapAction: true),
    );

    await tester.tap(find.byType(ArulEarnButton));
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });
}
