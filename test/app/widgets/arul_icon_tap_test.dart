// `ArulIconTap` is the one shape every icon-only control takes -> its three promises are pinned:
// the box is Android's 48 whatever the glyph size, the control is NAMED for TalkBack (the glyph
// alone announces nothing), and a press lands on `onTap` once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/widgets/arul_icon_tap.dart';
import 'package:arul/theme/arul_tokens.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('a 20 px glyph is tapped at 48 × 48', (tester) async {
    await tester.pumpWidget(
      _host(
        ArulIconTap(icon: Icons.edit, size: 20, label: 'Edit', onTap: () {}),
      ),
    );
    final box = tester.getSize(find.byType(ArulIconTap));
    expect(box.width, ArulTokens.minHitTarget);
    expect(box.height, ArulTokens.minHitTarget);
    expect(tester.getSize(find.byIcon(Icons.edit)).width, 20);
  });

  testWidgets('it is named for TalkBack and fires onTap once per press', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ArulIconTap(
          icon: Icons.arrow_back,
          label: 'Back',
          identifier: 'test_back',
          onTap: () => taps++,
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('Back'),
      findsOneWidget,
      reason: 'the label, not the glyph, is what TalkBack reads',
    );
    // The slack outside the glyph is real hit area: press the box's corner, not the icon.
    final rect = tester.getRect(find.byType(ArulIconTap));
    await tester.tapAt(rect.topLeft + const Offset(4, 4));
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('a null onTap is inert', (tester) async {
    await tester.pumpWidget(
      _host(const ArulIconTap(icon: Icons.edit, label: 'Edit', onTap: null)),
    );
    await tester.tap(find.byType(ArulIconTap));
    await tester.pump();
    // No throw, no state change: the disabled control simply ignores the press.
    expect(find.byIcon(Icons.edit), findsOneWidget);
  });
}
