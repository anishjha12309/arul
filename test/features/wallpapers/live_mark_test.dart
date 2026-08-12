import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/wallpapers/presentation/live_mark.dart';
import 'package:arul/theme/arul_tokens.dart';

/// The live marker replaced a text badge, so the properties worth pinning are
/// the ones that made a glyph the right answer at all: it carries no text, it
/// borrows the Share circle's glass from the SAME tokens rather than restating
/// them, and it keeps the shadow that is the only reason it survives a white
/// temple.
void main() {
  Future<void> pumpMark(WidgetTester tester) => tester.pumpWidget(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: LiveMark()),
    ),
  );

  BoxDecoration decorationOf(WidgetTester tester) =>
      tester.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration
          as BoxDecoration;

  testWidgets('carries no text — nothing to localize, which is the point', (
    tester,
  ) async {
    await pumpMark(tester);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('is smoked glass — dark fill, ivory rim, no literals', (
    tester,
  ) async {
    await pumpMark(tester);
    final d = decorationOf(tester);

    expect(
      d.color,
      ArulTokens.overMediaInkFill,
      reason:
          'SMOKED, not frosted: the Share circle can be the bright half of the '
          'pair because the scrim is behind it — this sits on raw artwork, and '
          'ivory-on-white marble is invisible at any alpha',
    );
    expect(d.shape, BoxShape.circle);
    expect(
      d.border,
      const Border.fromBorderSide(
        BorderSide(color: ArulTokens.overMediaGlassBorder),
      ),
    );
  });

  testWidgets('carries NO shadow — the halo read as a smudge on real artwork', (
    tester,
  ) async {
    await pumpMark(tester);
    expect(
      decorationOf(tester).boxShadow,
      isNull,
      reason:
          'it shipped with the rail glyphs dark halo and was visible as a '
          'black backdrop on every wallpaper; the hairline carries the edge',
    );
  });

  testWidgets('the glyph is centred in the disc, not hung off its corner', (
    tester,
  ) async {
    await pumpMark(tester);

    expect(
      tester.getSize(find.byType(DecoratedBox)),
      const Size(LiveMark.diameter, LiveMark.diameter),
    );
    expect(
      tester.getCenter(find.byIcon(Icons.play_arrow_rounded)),
      tester.getCenter(find.byType(DecoratedBox)),
    );
  });

  testWidgets('paints nothing that animates — it must never ask for a frame', (
    tester,
  ) async {
    await pumpMark(tester);
    // Settles rather than timing out: proof there is no ticker in here. The
    // mark shares a card with a live video texture.
    await tester.pumpAndSettle();
  });
}
