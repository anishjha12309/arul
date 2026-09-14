// A tapped campaign must land where it says whatever sits on screen, and must never walk a signed-out
// person past the sign-in wall. A real GoRouter, because `go` replacing a covering route is the thing
// under test; the screens are stand-ins -> app_shell_deep_link_test.dart pins what the shell does with
// a parked target once it mounts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/features/push/data/push_tap_router.dart';

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  late GoRouter router;
  late PushTapRouter taps;
  late List<String> events;

  String location() => router.routerDelegate.currentConfiguration.uri.toString();

  Future<void> pumpApp(WidgetTester tester, {String initial = '/browse'}) async {
    events = [];
    router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('splash')),
        GoRoute(path: '/sign-in', builder: (_, _) => const Text('sign-in')),
        GoRoute(path: '/browse', builder: (_, _) => const Text('feed')),
        GoRoute(path: '/ringtones', builder: (_, _) => const Text('ringtones')),
        GoRoute(path: '/premium', builder: (_, _) => const Text('premium')),
        GoRoute(path: '/refer', builder: (_, _) => const Text('refer')),
      ],
    );
    taps = PushTapRouter(
      router: router,
      onSelectCategory: (slug) => events.add('select $slug at ${location()}'),
    );
    addTearDown(taps.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  group('past the launch', () {
    testWidgets('a wallpaper tap over a premium screen opened by a push lands on the feed', (
      tester,
    ) async {
      // The production walk: a premium campaign tapped first (`go`, so no shell underneath), then this.
      await pumpApp(tester);
      taps.open(const PremiumLinkTarget(source: DeepLinkSource.push));
      await tester.pumpAndSettle();
      expect(find.text('premium'), findsOneWidget);

      taps.open(const WallpaperLinkTarget('w1', source: DeepLinkSource.push));
      await tester.pumpAndSettle();

      expect(find.text('feed'), findsOneWidget);
      expect(find.text('premium'), findsNothing);
      expect(location(), '/browse');
      expect(
        ArulDeepLink.pendingTarget,
        const WallpaperLinkTarget('w1', source: DeepLinkSource.push),
        reason: 'parked for the feed to consume once its catalog resolves the id',
      );
    });

    testWidgets('a ringtone tap under a pushed screen closes it and opens Ringtones', (
      tester,
    ) async {
      await pumpApp(tester);
      unawaited(router.push('/refer'));
      await tester.pumpAndSettle();
      expect(find.text('refer'), findsOneWidget);

      taps.open(const RingtoneLinkTarget('r1', source: DeepLinkSource.push));
      await tester.pumpAndSettle();

      expect(find.text('ringtones'), findsOneWidget);
      expect(find.text('refer'), findsNothing);
      expect(location(), '/ringtones');
      expect(router.canPop(), isFalse, reason: 'nothing left stacked on top');
    });

    testWidgets('a category is selected BEFORE the feed is routed to', (tester) async {
      await pumpApp(tester, initial: '/ringtones');

      taps.open(const CategoryLinkTarget('sivan', source: DeepLinkSource.push));
      await tester.pumpAndSettle();

      expect(events, ['select sivan at /ringtones']);
      expect(location(), '/browse');
      expect(ArulDeepLink.pendingTarget, isNull, reason: 'a category is selected, never parked');
    });

    testWidgets('a premium tap opens the paywall stamped source=push', (tester) async {
      await pumpApp(tester, initial: '/ringtones');

      taps.open(const PremiumLinkTarget(source: DeepLinkSource.push));
      await tester.pumpAndSettle();

      expect(location(), '/premium?source=push');
      expect(ArulDeepLink.pendingTarget, isNull);
    });
  });

  group('during the launch', () {
    testWidgets('a cold tap on the splash is held until the splash routes', (tester) async {
      await pumpApp(tester, initial: '/');

      taps.open(const PremiumLinkTarget(source: DeepLinkSource.push));
      await tester.pumpAndSettle();
      expect(find.text('splash'), findsOneWidget, reason: 'the auth decision is not in yet');

      router.go('/browse'); // the splash: a stored session was found
      await tester.pumpAndSettle();

      expect(location(), '/premium?source=push');
    });

    testWidgets('a signed-out cold tap never passes the sign-in wall', (tester) async {
      await pumpApp(tester, initial: '/');

      taps.open(const CategoryLinkTarget('sivan', source: DeepLinkSource.push));
      taps.open(const PremiumLinkTarget(source: DeepLinkSource.push));
      await tester.pumpAndSettle();
      expect(find.text('splash'), findsOneWidget);

      router.go('/sign-in'); // the splash: no session
      await tester.pumpAndSettle();
      expect(find.text('sign-in'), findsOneWidget);
      expect(find.text('premium'), findsNothing);
      expect(find.text('feed'), findsNothing);

      router.go('/browse'); // signed in
      await tester.pumpAndSettle();
      expect(location(), '/premium?source=push', reason: 'last tap wins, applied once');

      router.go('/ringtones');
      await tester.pumpAndSettle();
      expect(location(), '/ringtones', reason: 'the held tap does not replay on later navigation');
    });

    testWidgets('a held wallpaper tap is parked at once for the shell to follow', (tester) async {
      await pumpApp(tester, initial: '/sign-in');

      taps.open(const WallpaperLinkTarget('w1', source: DeepLinkSource.push));
      await tester.pumpAndSettle();
      expect(find.text('sign-in'), findsOneWidget);
      expect(
        ArulDeepLink.pendingTarget,
        const WallpaperLinkTarget('w1', source: DeepLinkSource.push),
      );

      router.go('/browse');
      await tester.pumpAndSettle();
      expect(location(), '/browse');
    });
  });

  test('locationFor sends content to its tab and premium to the paywall', () {
    expect(PushTapRouter.locationFor(const WallpaperLinkTarget('w')), '/browse');
    expect(PushTapRouter.locationFor(const CategoryLinkTarget('sivan')), '/browse');
    expect(PushTapRouter.locationFor(const RingtoneLinkTarget('r')), '/ringtones');
    expect(PushTapRouter.locationFor(const TabLinkTarget(ArulTab.ringtones)), '/ringtones');
    expect(PushTapRouter.locationFor(const PremiumLinkTarget()), '/premium?source=push');
  });
}
