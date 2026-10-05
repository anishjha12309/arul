// EVERY tab shows an icon AND a label -> an unnamed glyph is unreadable beside a named one.
// The active cell is whichever the shell says is active -> tapping a tab reports its OWN index.
// Settings is a pushed route off the header gear, never a dock cell -> the dock holds the tabs alone.
// The flag-off dock is the two items below; Status joins as the third only with the flag on.

import 'package:arul/app/shell/app_shell.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/theme/arul_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = <ArulNavItem>[
    (glyph: ArulLineGlyph.wallpapers, label: 'Wallpapers'),
    (glyph: ArulLineGlyph.ringtones, label: 'Ringtones'),
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

    expect(find.byType(ArulLineIcon), findsNWidgets(items.length));
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

    await tester.tap(find.text('Ringtones'));
    await tester.tap(find.text('Wallpapers'));

    expect(taps, [AppShell.ringtonesBranch, AppShell.wallpapersBranch]);
  });

  testWidgets('it renders in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await pumpDock(tester, currentIndex: 1, brightness: brightness);
      expect(tester.takeException(), isNull);
      expect(find.byType(ArulLineIcon), findsNWidgets(items.length));
    }
  });

  testWidgets('with the status flag on, a third Status cell reports the '
      'status branch', (tester) async {
    const withStatus = <ArulNavItem>[
      ...items,
      (glyph: ArulLineGlyph.status, label: 'Status'),
    ];
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          extendBody: true,
          body: const SizedBox.expand(),
          bottomNavigationBar: ArulNavDock(
            currentIndex: AppShell.statusBranch,
            onTap: taps.add,
            items: withStatus,
          ),
        ),
      ),
    );

    expect(find.byType(ArulLineIcon), findsNWidgets(3));
    expect(
      find.bySemanticsIdentifier('arul_tab_status'),
      findsOneWidget,
      reason: 'the id derives from the glyph, never the ARB label',
    );
    await tester.tap(find.text('Status'));
    expect(taps, [AppShell.statusBranch]);
    expect(tester.takeException(), isNull);
  });
}
