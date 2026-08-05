// The floating dock. Its look is a device check, but two things about the
// redesign are worth pinning down here because they are exactly what a careless
// edit would undo:
//
//   - ALL THREE tabs show an icon AND a label. The dock this replaced revealed
//     the label only on the active side, which left two unnamed glyphs; with
//     three destinations that is no longer readable.
//   - The active cell is the one the shell says is active, and tapping a tab
//     reports its own index (so Settings, now a branch rather than a pushed
//     route, cannot silently land on the wrong one).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/theme/arul_tokens.dart';

void main() {
  const items = <ArulNavItem>[
    (glyph: ArulLineGlyph.wallpapers, label: 'Wallpapers'),
    (glyph: ArulLineGlyph.ringtones, label: 'Ringtones'),
    (glyph: ArulLineGlyph.settings, label: 'Settings'),
  ];

  Future<List<int>> pumpDock(
    WidgetTester tester, {
    required int currentIndex,
    Brightness brightness = Brightness.dark,
  }) async {
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          extendBody: true,
          body: const SizedBox.expand(),
          bottomNavigationBar: ArulNavDock(
            currentIndex: currentIndex,
            onTap: taps.add,
            items: items,
          ),
        ),
      ),
    );
    return taps;
  }

  testWidgets('every tab carries both its glyph and its name', (tester) async {
    await pumpDock(tester, currentIndex: 1);

    expect(find.byType(ArulLineIcon), findsNWidgets(3));
    for (final item in items) {
      expect(
        find.text(item.label),
        findsOneWidget,
        reason: '${item.label} must be named, active or not',
      );
    }
  });

  testWidgets('the active cell follows currentIndex', (tester) async {
    for (var active = 0; active < items.length; active++) {
      await pumpDock(tester, currentIndex: active);

      // The active tab is the only one that paints a cell behind itself.
      final decorated = tester
          .widgetList<Container>(find.byType(Container))
          .where(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).borderRadius ==
                    BorderRadius.circular(ArulTokens.dockActiveTabRadius),
          );
      expect(decorated, hasLength(1), reason: 'exactly one lit cell');
    }
  });

  testWidgets('a tap reports that tab\'s own index', (tester) async {
    final taps = await pumpDock(tester, currentIndex: 0);

    await tester.tap(find.text('Settings'));
    await tester.tap(find.text('Ringtones'));
    await tester.tap(find.text('Wallpapers'));

    expect(taps, [2, 1, 0]);
  });

  testWidgets('it renders in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await pumpDock(tester, currentIndex: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      expect(find.byType(ArulLineIcon), findsNWidgets(3));
    }
  });
}
