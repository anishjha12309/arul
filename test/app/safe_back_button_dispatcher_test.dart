// go_router 17.3's popRoute throws on an unmounted shell navigator (flutter/flutter#188993); the
// binding reported it FATAL and then closed the app. SafeBackButtonDispatcher contains it.

import 'dart:async';

import 'package:arul/app/safe_back_button_dispatcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a pop that throws is reported and declined when nothing can pop',
    (tester) async {
      final errors = <Object>[];
      final key = GlobalKey<NavigatorState>();
      final dispatcher = SafeBackButtonDispatcher(
        rootNavigator: key,
        onError: (e, _) => errors.add(e),
      );
      dispatcher.addCallback(() => Future<bool>.error(TypeError()));

      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );

      expect(await dispatcher.didPopRoute(), isFalse);
      expect(errors, hasLength(1));
    },
  );

  testWidgets('a pop that throws still pops the root navigator when it can', (
    tester,
  ) async {
    final errors = <Object>[];
    final key = GlobalKey<NavigatorState>();
    final dispatcher = SafeBackButtonDispatcher(
      rootNavigator: key,
      onError: (e, _) => errors.add(e),
    );
    dispatcher.addCallback(() => Future<bool>.error(TypeError()));

    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const SizedBox()),
    );
    unawaited(
      key.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('pushed')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    final handled = dispatcher.didPopRoute();
    await tester.pumpAndSettle();

    expect(await handled, isTrue);
    expect(find.text('pushed'), findsNothing);
    expect(errors, hasLength(1));
  });

  testWidgets('a working pop passes straight through, nothing reported', (
    tester,
  ) async {
    final errors = <Object>[];
    final dispatcher = SafeBackButtonDispatcher(
      rootNavigator: GlobalKey<NavigatorState>(),
      onError: (e, _) => errors.add(e),
    );
    dispatcher.addCallback(() => Future<bool>.value(true));

    expect(await dispatcher.didPopRoute(), isTrue);
    expect(errors, isEmpty);
  });
}
