// A tile picked between discrete values but announced neither a button role nor its selected
// state — TalkBack read it as an unlabelled group with no state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/features/settings/presentation/language_sheet.dart';

void main() {
  testWidgets(
    'the current language tile announces button role, selected state and its name',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showLanguageSheet(context, 'English'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final selected = tester.getSemantics(
        find.bySemanticsLabel('English English'),
      );
      expect(
        selected,
        matchesSemantics(
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );

      final unselected = tester.getSemantics(
        find.bySemanticsLabel('தமிழ் Tamil'),
      );
      expect(
        unselected,
        matchesSemantics(
          isButton: true,
          isSelected: false,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    },
  );
}
