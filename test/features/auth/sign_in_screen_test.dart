// The retry line is the only thing the sign-in wall says to a user who did not get in, and it is the
// SAME line for every outcome (owner's call: no explanation, no link — this audience cannot act on
// either). These pin that: one line, never the idle line, never a sentence under the pill.

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/auth/data/sign_in_surface_clock.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/domain/sign_in_outcome.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts what the screen asked of the auth layer. Zero is the assertion for every help tap.
class _CountingAuthService implements AuthService {
  int signInCalls = 0;
  int abandonCalls = 0;

  @override
  Future<AuthResult> signInWith(AuthProvider provider, {bool auto = false}) {
    signInCalls++;
    return Future.value(const AuthCancelled());
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
    List<Locale> phoneLocales = const [Locale('en')],
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
          builder: (_, _) => SignInScreen(debugOutcome: outcome),
        ),
        for (final path in const ['/browse', '/legal/terms', '/legal/privacy'])
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
        // The panel is caption, pill and the terms line — no sentence under the pill, and the only
        // links on the screen are Terms and Privacy.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.link == true &&
                w.properties.label != l10n.signInTermsLink &&
                w.properties.label != l10n.signInPrivacyLink,
          ),
          findsNothing,
          reason: '${outcome.name} must offer no help link',
        );
      }
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
