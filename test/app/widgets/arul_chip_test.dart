// A Semantics(excludeSemantics: true) ancestor drops its GestureDetector child's tap action from
// the accessibility tree unless the same callback is also passed as Semantics(onTap:) — this is
// the regression contract for every chip-shaped control (docs/edge-cases.md pattern).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/widgets/arul_chip.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('an active chip exposes a tap action and its selected state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ArulChip(
          label: 'Sivan',
          selected: true,
          variant: ArulChipVariant.category,
          onTap: () => taps++,
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(ArulChip)),
      matchesSemantics(
        label: 'Sivan',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.byType(ArulChip));
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('an unselected chip with no onTap is not a button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const ArulChip(
          label: 'Amman',
          selected: false,
          variant: ArulChipVariant.category,
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(ArulChip)),
      matchesSemantics(
        label: 'Amman',
        isButton: false,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: false,
      ),
    );
    handle.dispose();
  });
}
