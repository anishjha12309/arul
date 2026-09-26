// The retry line is the only thing the sign-in wall says to a user who did not get in, and it is the
// SAME line for every outcome (owner's call: no explanation, no link — this audience cannot act on
// either). These pin that: one line, never the idle line, never a sentence under the pill.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/auth/data/sign_in_surface_clock.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/domain/sign_in_outcome.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts what the screen asked of the auth layer. Zero is the assertion for every help tap.
class _CountingAuthService implements AuthService {
  int signInCalls = 0;
  int abandonCalls = 0;

  /// The `returned` flag of every attempt, in order -> the return re-arm is visible from the screen.
  final List<bool> returnedFlags = [];

  /// The `reconnected` flag of every attempt -> the same for the reconnect re-arm.
  final List<bool> reconnectedFlags = [];

  /// The `afterOffline` flag of every attempt -> the launch held while the phone was offline.
  final List<bool> afterOfflineFlags = [];

  /// What the NEXT attempt settles as. A network-class failure is what the reconnect rule needs
  /// behind it, and nothing else on this screen cares which quiet outcome it gets.
  AuthResult next = const AuthCancelled();

  @override
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool afterOffline = false,
    bool reopened = false,
  }) {
    signInCalls++;
    returnedFlags.add(returned);
    reconnectedFlags.add(reconnected);
    afterOfflineFlags.add(afterOffline);
    return Future.value(next);
  }

  @override
  void abandonPendingSignIn() => abandonCalls++;

  @override
  Stream<AuthUserState> get authStateChanges => const Stream.empty();

  @override
  AuthUserState get currentState => AuthUserState.unauthenticated();

  @override
  Future<void> get initialized async {}

  @override
  Future<void> updateDisplayName(String name) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}

void main() {
  late _CountingAuthService auth;
  late List<String> routes;
  late SharedPreferences prefs;

  setUp(() async {
    auth = _CountingAuthService();
    routes = [];
    SignInPhase.exchanging.value = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() => SignInPhase.exchanging.value = false);

  Future<AppLocalizations> pump(
    WidgetTester tester, {
    SignInOutcome? outcome,
    bool waiting = false,
    List<Locale> phoneLocales = const [Locale('en')],
    Stream<bool>? online,
  }) async {
    // The video background and the haptics reach for platform channels that do not exist here.
    for (final name in const [
      'arul/feed_video',
      'com.hsrutility.arul/build_info',
      'plugins.flutter.io/url_launcher',
    ]) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }

    final router = GoRouter(
      initialLocation: '/sign-in',
      routes: [
        GoRoute(
          path: '/sign-in',
          builder: (_, _) => SignInScreen(
            debugOutcome: outcome,
            debugWaitingForInternet: waiting,
          ),
        ),
        for (final path in const ['/browse'])
          GoRoute(
            path: path,
            builder: (_, _) {
              routes.add(path);
              return const SizedBox.shrink();
            },
          ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          platformLocalesProvider.overrideWithValue(phoneLocales),
          authServiceProvider.overrideWithValue(auth),
          // The wall watches the link from its first frame; connectivity_plus has no channel under
          // `flutter test`, and its EventChannel reports that failure through FlutterError.
          isOnlineProvider.overrideWith((ref) => online ?? Stream.value(true)),
        ],
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            // The app drives its own locale off the provider, exactly like `app.dart`, so a pick
            // made on this screen re-renders it.
            locale: ref.watch(localeProvider),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pump();
    return AppLocalizations.of(tester.element(find.byType(SignInScreen).first));
  }

  group('the sign-in pill', () {
    // The pill's Semantics carried no button role and no onTap — a `container: true` node with a
    // GestureDetector child announces as a plain group, not a tappable control.
    testWidgets('exposes a tap action to TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      expect(
        tester.getSemantics(find.bySemanticsIdentifier('arul_signin_pill')),
        matchesSemantics(isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });
  });

  group('the line under the pill', () {
    testWidgets('idle asks for an account and never shows the retry line', (
      tester,
    ) async {
      final l10n = await pump(tester);

      expect(find.text(l10n.signInSubtitleIdle), findsOneWidget);
      expect(find.text(l10n.signInGoogle), findsOneWidget);
      expect(find.text(l10n.signInCaption), findsOneWidget);
      expect(find.text(l10n.signInNudgeRetry), findsNothing);
    });

    testWidgets('the exchange is the ONE wait the app claims', (tester) async {
      final l10n = await pump(tester, outcome: SignInOutcome.backedOutQuick);
      SignInPhase.exchanging.value = true;
      await tester.pump();

      expect(find.text(l10n.signInSubtitleExchanging), findsOneWidget);
      expect(
        find.text(l10n.signInNudgeRetry),
        findsNothing,
        reason: 'an attempt in flight has not failed yet',
      );
    });

    testWidgets('every failure shows the same retry line and nothing else', (
      tester,
    ) async {
      for (final outcome in SignInOutcome.values) {
        final l10n = await pump(tester, outcome: outcome);
        expect(
          find.text(l10n.signInNudgeRetry),
          findsOneWidget,
          reason: outcome.name,
        );
        expect(
          find.text(l10n.signInSubtitleIdle),
          findsNothing,
          reason: '${outcome.name} must not fall back to the idle line',
        );
        // The panel is caption and pill, nothing else — no sentence under it and no link at all.
        // Terms and Privacy left with the rest: the policy reader opens from Settings now.
        expect(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.link == true,
          ),
          findsNothing,
          reason: '${outcome.name} must offer no links at all',
        );
      }
    });
  });

  // The wall FEEDS the controller its lifecycle and joins whatever that re-arms. The rule itself is
  // pinned in auth_test.dart; this pins the WIRE, because an observer that is never registered (or
  // that a dispose leaves attached) makes the whole re-arm dead code with every unit test still green.
  group('the return re-arm reaches the wall', () {
    testWidgets('a resume after a real away stretch fires ONE more automatic '
        'attempt, marked as a return', (tester) async {
      await pump(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );
      final t0 = DateTime(2026, 9, 15, 10);
      var clock = t0;
      final controller = container.read(authControllerProvider.notifier)
        ..now = (() => clock)
        ..stallTick = const Duration(milliseconds: 10);

      // The cold-start attempt the splash fires. This build has no API define, so the screen's own
      // first frame stood down -> firing it here is the only way the wall has a spent launch.
      unawaited(controller.autoSignIn(AuthProvider.google)!);
      await tester.pump();
      expect(auth.signInCalls, 1);

      clock = t0.add(const Duration(seconds: 100));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 200));
      // Android's real return order — `inactive` must not count as coming back, or the away
      // stretch is spent on the transition into the resume it is meant to qualify.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(auth.signInCalls, 2);
      expect(auth.returnedFlags, [false, true]);
    });

    // Same wire, the other feed: a reading the screen never subscribes to leaves the whole
    // reconnect rule dead code with every unit test still green.
    testWidgets('the link coming back after a network failure fires ONE more '
        'automatic attempt, marked as a reconnect', (tester) async {
      final link = StreamController<bool>();
      addTearDown(link.close);
      auth.next = const AuthFailure(
        message: 'Sign-in didn\'t complete. Check your internet connection…',
        kind: AuthFailureKind.unknown,
      );
      await pump(tester, online: link.stream);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );
      final t0 = DateTime(2026, 9, 15, 10);
      var clock = t0;
      final controller = container.read(authControllerProvider.notifier)
        ..now = (() => clock)
        ..stallTick = const Duration(milliseconds: 10)
        ..lifecycleProbe = (() => AppLifecycleState.resumed);

      // The cold-start attempt, dying the way a phone with mobile data off kills one.
      unawaited(controller.autoSignIn(AuthProvider.google)!);
      await tester.pump();
      expect(auth.signInCalls, 1);
      // The re-armed attempt is the one under test; a second failure would only toast.
      auth.next = const AuthCancelled();

      clock = t0.add(const Duration(seconds: 10));
      link.add(false);
      await tester.pump();
      clock = t0.add(const Duration(seconds: 20));
      link.add(true);
      await tester.pump();
      await tester.pump();

      expect(auth.signInCalls, 2);
      expect(auth.reconnectedFlags, [false, true]);
      expect(auth.returnedFlags, [false, false]);
    });

    testWidgets('a launch held for the network shows the wait line, and the '
        'link coming up fires it ONCE, stamped as held', (tester) async {
      final link = StreamController<bool>();
      addTearDown(link.close);
      await pump(tester, online: link.stream);
      link.add(false);
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );
      final controller = container.read(authControllerProvider.notifier)
        ..stallTick = const Duration(milliseconds: 10)
        ..lifecycleProbe = (() => AppLifecycleState.resumed);

      // What the splash does on an offline cold start, then a resume while data is still off.
      expect(controller.autoSignIn(AuthProvider.google, offline: true), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Waiting for internet…'), findsOneWidget);
      expect(auth.signInCalls, 0);

      link.add(true);
      await tester.pump();
      await tester.pump();

      expect(auth.signInCalls, 1);
      expect(auth.afterOfflineFlags, [true]);
      expect(find.text('Waiting for internet…'), findsNothing);
    });

    testWidgets('the wait line is the pill subtitle and nothing else on the '
        'wall', (tester) async {
      await pump(tester, waiting: true, online: Stream.value(false));
      final subtitle = tester.widget<Text>(find.byKey(kSignInSubtitleKey));
      expect(subtitle.data, 'Waiting for internet…');
      expect(find.text('Choose an account to start'), findsNothing);
      expect(find.text('Click here to sign in'), findsNothing);
    });

    testWidgets('a resume with no away stretch behind it changes nothing', (
      tester,
    ) async {
      await pump(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );
      final controller = container.read(authControllerProvider.notifier)
        ..stallTick = const Duration(milliseconds: 10);

      unawaited(controller.autoSignIn(AuthProvider.google)!);
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(auth.signInCalls, 1);
    });
  });

  // The wall carries NO language control (owner's call, measured): Google's sheet covers this
  // screen, so a second control is only reachable by dismissing the sheet first — the people who
  // reached the old chip made ~4 attempts against under 2 and signed in far less. The region picks
  // the first-launch language and Settings is where it changes. These pin that it cannot come back.
  group('the wall has no language control', () {
    testWidgets('the pill is the ONLY tappable thing', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      expect(find.semantics.byAction(SemanticsAction.tap), findsExactly(1));
      expect(
        find.bySemanticsIdentifier('arul_signin_pill'),
        findsOneWidget,
        reason: 'and the one that is left is the pill',
      );
      expect(
        find.bySemanticsIdentifier('arul_signin_language'),
        findsNothing,
        reason: 'no language control may return to the wall',
      );
      semantics.dispose();
    });

    testWidgets('nothing on the wall names or opens a language', (
      tester,
    ) async {
      final l10n = await pump(tester, phoneLocales: const [Locale('ta')]);

      // The chip's own marks: the code, the glyph and the chevron that opened the sheet.
      expect(find.text('TA'), findsNothing);
      expect(find.text(l10n.settingsLanguage), findsNothing);
      expect(find.byIcon(Icons.translate), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    });
  });

  // The region still decides what the WALL is written in — only the way to change it moved out.
  group('the wall speaks the resolved language', () {
    testWidgets('follows the phone when nothing is persisted', (tester) async {
      final l10n = await pump(tester, phoneLocales: const [Locale('ml')]);

      expect(l10n.localeName, 'ml');
    });

    testWidgets('follows the REGION over the phone', (tester) async {
      await prefs.setString('arul_geo_lang', 'ta');
      final l10n = await pump(tester);

      expect(l10n.localeName, 'ta');
    });

    testWidgets('a region answer landing on the open wall re-renders it', (
      tester,
    ) async {
      final l10n = await pump(tester);
      expect(l10n.localeName, 'en');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );

      await container
          .read(localeProvider.notifier)
          .setGeoHint(lang: 'ta', region: 'TN');
      await tester.pump();

      expect(
        AppLocalizations.of(
          tester.element(find.byType(SignInScreen).first),
        ).localeName,
        'ta',
      );
      expect(prefs.getString('arul_locale'), isNull, reason: 'a hint only');
    });
  });

  // The clock the nudges split on. It reads the app's OWN lifecycle, because a Credential Manager
  // surface is a GMS activity over ours and there is no other signal that it appeared.
  group('BindingSignInSurfaceClock', () {
    testWidgets('records the FIRST time the app went inactive', (tester) async {
      final clock = BindingSignInSurfaceClock()..startAttempt();
      addTearDown(clock.endAttempt);

      expect(clock.msToSurface, isNull, reason: 'nothing has appeared yet');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final first = clock.msToSurface;
      expect(first, isNotNull);

      // Coming back and leaving again is the user, not Google's surface arriving.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(clock.msToSurface, first);
    });

    testWidgets('a resume alone is not a surface', (tester) async {
      final clock = BindingSignInSurfaceClock()..startAttempt();
      addTearDown(clock.endAttempt);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      expect(clock.msToSurface, isNull);
    });

    testWidgets('ending an attempt drops the reading and stops listening', (
      tester,
    ) async {
      final clock = BindingSignInSurfaceClock()..startAttempt();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(clock.msToSurface, isNotNull);

      clock.endAttempt();
      expect(
        clock.msToSurface,
        isNull,
        reason: 'the next attempt must not inherit this one\'s wait',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(clock.msToSurface, isNull, reason: 'no longer observing');
      // Idempotent -> the service calls it on both the guard path and the finally.
      clock.endAttempt();
    });

    testWidgets('a hidden app counts as a surface too', (tester) async {
      final clock = BindingSignInSurfaceClock()..startAttempt();
      addTearDown(clock.endAttempt);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      expect(clock.msToSurface, isNotNull);
    });
  });
}
