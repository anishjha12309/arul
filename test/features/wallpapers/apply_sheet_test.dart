// The Home/Lock/Both target cards drop their GestureDetector's tap action when the Semantics
// ancestor excludes it — the same excludeSemantics regression as every other chip-shaped control.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/wallpapers/presentation/apply_sheet.dart';

Wallpaper _wp() => Wallpaper.fromJson({
  'id': 'id-1',
  'title': 'test',
  'type': 'static',
  'category': 'sivan',
  'full_key': 'wallpapers/sivan/1.jpg',
  'width': 1080,
  'height': 1920,
});

void main() {
  testWidgets('Home/Lock/Both cards expose a tap action and selected state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    unawaited(ApplySheet.show(ctx, wallpaper: _wp()));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(ctx);

    expect(
      tester.getSemantics(find.bySemanticsLabel(l10n.applyTargetHome)),
      matchesSemantics(
        label: l10n.applyTargetHome,
        isButton: true,
        hasTapAction: true,
        isSelected: false,
        hasSelectedState: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(l10n.applyTargetBoth)),
      matchesSemantics(
        label: l10n.applyTargetBoth,
        isButton: true,
        hasTapAction: true,
        // "Both" is the sheet's default selection.
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    handle.dispose();
  });
}
