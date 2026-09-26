// docs/edge-cases.md: "A refresh that proves the session dead signs the UI out and sends any
// signed-in screen to the wall." Pinned here for the listener in `ArulApp.initState`
// (lib/app/app.dart, the `ref.listenManual(authStateStreamProvider, ...)` block) — copied
// VERBATIM below because the logic lives inline in a State's initState with no seam to import it,
// and CLAUDE.md forbids editing lib/ to extract one.
//
// `ArulApp` itself could not be pumped for this: `_ArulAppState.initState` reads
// `notificationServiceProvider` and `sharedPreferencesProvider`, both of which throw unless
// overridden in `main()` (fixable), but the real blocker is `SplashScreen._decideRoute`, which
// gates its routing decision on `AppConfig.hasBackend` — a compile-time `String.fromEnvironment`
// that is always false under `flutter test` (no `--dart-define` reaches it), so the splash always
// routes to `/sign-in` however the injected `AuthService.currentState` answers, and there is no
// way to start the pumped app already on a signed-in route. Splash's own `GoRouter.go` inside
// `initState` also trips flutter_test's "setState() called during build" assertion, a known
// go_router/widget-test interaction (immaterial to this contract, but one more reason a full
// `ArulApp` pump is not the way to pin this).
//
// So this is the "smallest host" the task brief allows: the exact listener body, on a LOCAL
// GoRouter shaped like push_tap_router_test.dart's (stand-in routes; the app's real global
// `router` carries no test seam either — it's a top-level singleton with no constructor to
// substitute).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';

/// Records every state the stream pushes; `push`/`fail` drive it from outside like a real
/// `AuthService` implementation would.
class _StreamAuthService implements AuthService {
  final _controller = StreamController<AuthUserState>.broadcast();

  AuthUserState _current = AuthUserState.unauthenticated();

  void push(AuthUserState state) {
    _current = state;
    _controller.add(state);
  }

  @override
  Stream<AuthUserState> get authStateChanges => _controller.stream;

  @override
  AuthUserState get currentState => _current;

  @override
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool afterOffline = false,
    bool reopened = false,
  }) async => const AuthCancelled();

  @override
  void abandonPendingSignIn() {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<void> get initialized async {}

  @override
  Future<void> updateDisplayName(String name) async {}

  Future<void> dispose() => _controller.close();
}

/// The exact body of `ArulApp.initState`'s auth-death listener (lib/app/app.dart), wired to a
/// local router instead of the app's global singleton — the one substitution this host makes.
class _AuthWallHost extends ConsumerStatefulWidget {
  const _AuthWallHost({required this.router});

  final GoRouter router;

  @override
  ConsumerState<_AuthWallHost> createState() => _AuthWallHostState();
}

class _AuthWallHostState extends ConsumerState<_AuthWallHost> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(authStateStreamProvider, (previous, next) {
      final wasSignedIn = previous?.value?.isAuthenticated ?? false;
      if (!wasSignedIn || (next.value?.isAuthenticated ?? true)) return;
      final path = widget.router.routerDelegate.currentConfiguration.uri.path;
      if (path == '/' || path == '/sign-in') return;
      ref.read(authControllerProvider.notifier).sessionEnded();
      widget.router.go('/sign-in');
    });
  }

  @override
  Widget build(BuildContext context) =>
      MaterialApp.router(routerConfig: widget.router);
}

void main() {
  late _StreamAuthService auth;
  late GoRouter router;

  String location() =>
      router.routerDelegate.currentConfiguration.uri.toString();

  Future<void> pumpHost(WidgetTester tester, {required String initial}) async {
    router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('splash')),
        GoRoute(path: '/sign-in', builder: (_, _) => const Text('sign-in')),
        GoRoute(path: '/browse', builder: (_, _) => const Text('feed')),
        GoRoute(path: '/settings', builder: (_, _) => const Text('settings')),
        GoRoute(path: '/premium', builder: (_, _) => const Text('premium')),
      ],
    );
    addTearDown(router.dispose);

    final container = ProviderContainer(
      overrides: [authServiceProvider.overrideWithValue(auth)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _AuthWallHost(router: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    auth = _StreamAuthService();
  });

  tearDown(() => auth.dispose());

  // The provider's `previous` is only ever populated by a value the STREAM emitted after the
  // widget subscribed (a broadcast stream buffers nothing for a late listener, and the very first
  // emission always arrives with `previous` unset). So every scenario below establishes the
  // "was signed in" half with an explicit push AFTER `pumpHost`, then drives the transition under
  // test with a second push — exactly two real stream events, like a live app's refresh dying.

  testWidgets(
    'a signed-in screen goes to the wall when a dead refresh flips auth to signed-out',
    (tester) async {
      await pumpHost(tester, initial: '/settings');
      auth.push(AuthUserState.authenticated(userId: 'u1'));
      await tester.pump();
      expect(location(), '/settings', reason: 'still authenticated, no move');

      auth.push(AuthUserState.unauthenticated());
      await tester.pumpAndSettle();

      expect(location(), '/sign-in');
    },
  );

  testWidgets(
    'the splash route needs nothing — a flip while on "/" is left alone',
    (tester) async {
      await pumpHost(tester, initial: '/');
      auth.push(AuthUserState.authenticated(userId: 'u1'));
      await tester.pump();
      expect(location(), '/');

      auth.push(AuthUserState.unauthenticated());
      await tester.pumpAndSettle();

      expect(
        location(),
        '/',
        reason: 'the splash already routes on its own auth decision',
      );
    },
  );

  testWidgets(
    'already on the wall, a flip navigates nowhere (no redundant go)',
    (tester) async {
      await pumpHost(tester, initial: '/sign-in');
      auth.push(AuthUserState.authenticated(userId: 'u1'));
      await tester.pump();
      expect(location(), '/sign-in');

      auth.push(AuthUserState.unauthenticated());
      await tester.pumpAndSettle();

      expect(location(), '/sign-in');
    },
  );

  testWidgets(
    'a session that was never signed in this stream never triggers the wall',
    (tester) async {
      // The FIRST event this stream ever delivers is the unauthenticated one below -> `previous`
      // is unset, `wasSignedIn` reads false, and the listener must stay quiet.
      await pumpHost(tester, initial: '/browse');
      expect(location(), '/browse');

      auth.push(AuthUserState.unauthenticated());
      await tester.pumpAndSettle();

      expect(
        location(),
        '/browse',
        reason: 'no prior authenticated state -> nothing "ended"',
      );
    },
  );

  testWidgets(
    'signing IN (unauthenticated -> authenticated) is never mistaken for the wall trigger',
    (tester) async {
      await pumpHost(tester, initial: '/premium');
      auth.push(AuthUserState.unauthenticated());
      await tester.pump();
      expect(location(), '/premium');

      auth.push(AuthUserState.authenticated(userId: 'u1'));
      await tester.pumpAndSettle();

      expect(location(), '/premium');
    },
  );

  testWidgets(
    'two authenticated states in a row (e.g. a display-name update) never redirects',
    (tester) async {
      await pumpHost(tester, initial: '/premium');
      auth.push(AuthUserState.authenticated(userId: 'u1'));
      await tester.pump();

      auth.push(AuthUserState.authenticated(userId: 'u1', displayName: 'A'));
      await tester.pumpAndSettle();

      expect(location(), '/premium');
    },
  );
}
