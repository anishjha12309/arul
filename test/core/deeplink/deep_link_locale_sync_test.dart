// The language half of a deep link. Pins: a `lang` parked before the first
// frame lands on the live locale, one that lands later does too, it goes
// through the same persisted `arul_locale` Settings writes, the deferred
// pending copy is cleared, and an unsupported code changes nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/deeplink/deep_link_locale_sync.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  Future<({ProviderContainer container, SharedPreferences prefs})> pump(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
        child: const DeepLinkLocaleSync(child: SizedBox.shrink()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DeepLinkLocaleSync)),
    );
    return (container: container, prefs: sp);
  }

  testWidgets('a language parked before the first frame is applied', (
    tester,
  ) async {
    ArulDeepLink.requestLocale('hi');
    final h = await pump(tester, prefs: {'pending_deeplink_lang': 'hi'});
    await tester.pump();

    expect(h.container.read(localeProvider), const Locale('hi'));
    expect(
      h.prefs.getString('arul_locale'),
      'hi',
      reason: 'persisted exactly like a Settings pick',
    );
    expect(
      h.prefs.getString('pending_deeplink_lang'),
      isNull,
      reason: 'the deferred copy is cleared once applied',
    );
    expect(ArulDeepLink.consumeLocale(), isNull);
  });

  testWidgets('a language that lands later is applied live', (tester) async {
    final h = await pump(tester);
    await tester.pump();
    expect(h.container.read(localeProvider), const Locale('en'));

    ArulDeepLink.requestLocale('ta');
    await tester.pump();

    expect(h.container.read(localeProvider), const Locale('ta'));
  });

  testWidgets('the link ALWAYS wins, even over an explicit Settings choice', (
    tester,
  ) async {
    // Owner's call, 2026-08-26: an ad in a language switches the app to it.
    final h = await pump(tester, prefs: {'arul_locale': 'ml'});
    await tester.pump();
    expect(h.container.read(localeProvider), const Locale('ml'));

    ArulDeepLink.requestLocale('kn');
    await tester.pump();

    expect(h.container.read(localeProvider), const Locale('kn'));
    expect(h.prefs.getString('arul_locale'), 'kn');
  });

  testWidgets('a code outside the shipped six changes nothing', (tester) async {
    final h = await pump(tester);
    await tester.pump();

    ArulDeepLink.requestLocale('fr');
    await tester.pump();

    expect(h.container.read(localeProvider), const Locale('en'));
    expect(h.prefs.getString('arul_locale'), isNull);
  });
}
