// The retry line is the only thing the sign-in wall says to a user who did not get in, and it is the
// SAME line for every outcome (owner's call: no explanation, no link — this audience cannot act on
// either). These pin that: one line, never the idle line, never a sentence under the pill.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
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

  @override
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reopened = false,
  }) {
    signInCalls++;
    returnedFlags.add(returned);
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

  // The way out of a language you cannot read — the region now picks the wall's language, and a
  // wrong state guess must be one tap from undone. Everything here is about it NOT being part of the
  // sign-in attempt: the pill owns that, and a chip that quietly re-entered the Google flow would
  // put a second surface over the first.
  group('the language chip', () {
    testWidgets('sits bottom-left, clear of the panel', (tester) async {
      await pump(tester);
      final screen = tester.getRect(find.byType(SignInScreen));
      final chip = tester.getRect(find.byKey(kSignInLanguageTriggerKey));
      final panel = tester.getRect(find.byKey(kSignInPanelKey));

      expect(chip.left, 20, reason: 'lined up with the panel inset');
      expect(chip.bottom, screen.bottom - 16);
      expect(chip.top, greaterThan(panel.bottom));
    });

    testWidgets('the pill and the chip are the ONLY tappable things', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);

      expect(find.semantics.byAction(SemanticsAction.tap), findsExactly(2));
      semantics.dispose();
    });

    testWidgets('shows the CURRENT language as its code', (tester) async {
      await pump(tester, phoneLocales: const [Locale('ta')]);

      // The CODE, not the native name: two Latin capitals measure the same in every language, so
      // the chip never resizes and never wraps.
      expect(find.text('TA'), findsOneWidget);
      expect(find.text('தமிழ்'), findsNothing);
      expect(find.byIcon(Icons.translate), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('follows the phone when nothing is persisted', (tester) async {
      await pump(tester, phoneLocales: const [Locale('ml')]);

      expect(find.text('ML'), findsOneWidget);
      // The whole screen came up in that language, not just the trigger.
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignInScreen).first),
      );
      expect(l10n.localeName, 'ml');
    });

    testWidgets('follows the REGION over the phone', (tester) async {
      await prefs.setString('arul_geo_lang', 'ta');
      await pump(tester);

      expect(find.text('TA'), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignInScreen).first),
      );
      expect(l10n.localeName, 'ta');
    });

    testWidgets('a region answer landing on the open wall re-renders it', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('EN'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SignInScreen)),
        listen: false,
      );

      await container
          .read(localeProvider.notifier)
          .setGeoHint(lang: 'ta', region: 'TN');
      await tester.pump();

      expect(find.text('TA'), findsOneWidget);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignInScreen).first),
      );
      expect(l10n.localeName, 'ta');
      expect(prefs.getString('arul_locale'), isNull, reason: 'a hint only');
    });

    testWidgets('carries a button semantics label', (tester) async {
      final l10n = await pump(tester);
      final node = tester.getSemantics(find.byKey(kSignInLanguageTriggerKey));

      // The wrapper names the CONTROL and the label inside it names the current VALUE, so the
      // merged node reads "Language, English" — a screen-reader user learns both without a second
      // focus stop. Excluding the child would announce the button and never what it is set to.
      expect(node.label, startsWith(l10n.settingsLanguage));
      expect(node.label, contains('EN'));
      expect(node.flagsCollection.isButton, isTrue);
    });

    testWidgets('a pick re-renders the screen and PERSISTS as a pick', (
      tester,
    ) async {
      await prefs.setString('arul_geo_lang', 'hi');
      await pump(tester);
      expect(find.text('HI'), findsOneWidget);

      await tester.tap(find.byKey(kSignInLanguageTriggerKey));
      await tester.pumpAndSettle();
      expect(find.text('Tamil'), findsOneWidget, reason: 'the sheet is up');

      await tester.tap(find.text('Tamil'));
      await tester.pumpAndSettle();

      expect(find.text('TA'), findsOneWidget, reason: 'chip re-rendered');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignInScreen).first),
      );
      expect(l10n.localeName, 'ta');
      expect(prefs.getString('arul_locale'), 'ta');
      expect(prefs.getString('arul_locale_source'), 'pick');
    });

    testWidgets('opening and picking never touches the sign-in attempt', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(kSignInLanguageTriggerKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hindi'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 0, reason: 'the trigger is not the pill');
      expect(auth.abandonCalls, 0);
      expect(routes, isEmpty);
    });

    testWidgets('stays tappable while an attempt is in flight', (tester) async {
      await pump(tester);
      SignInPhase.exchanging.value = true;
      await tester.pump();

      await tester.tap(find.byKey(kSignInLanguageTriggerKey));
      await tester.pumpAndSettle();

      // A user who cannot read the pill is exactly the user with an attempt running.
      expect(find.text('Kannada'), findsOneWidget);
      expect(auth.signInCalls, 0);
    });

    testWidgets('the sheet follows the DEVICE mode, not the app theme', (
      tester,
    ) async {
      // The wall is always dark over video whatever the user picked in Settings, so the app's own
      // theme mode says nothing about what a sheet rising out of it should look like.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await pump(tester);
      await tester.tap(find.byKey(kSignInLanguageTriggerKey));
      await tester.pumpAndSettle();

      final sheetTheme = Theme.of(tester.element(find.text('Tamil').first));
      expect(sheetTheme.brightness, Brightness.light);

      // And the other way round. (The English tile carries the native label AND the English name,
      // which are the same word — dismiss the sheet instead of picking through an ambiguous find.)
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.tap(find.text('Tamil'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kSignInLanguageTriggerKey));
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.text('Tamil').first)).brightness,
        Brightness.dark,
      );
    });

    testWidgets(
      'a session landing with the sheet OPEN still reaches the feed',
      (tester) async {
        await pump(tester);
        await tester.tap(find.byKey(kSignInLanguageTriggerKey));
        await tester.pumpAndSettle();
        expect(find.text('Telugu'), findsOneWidget);

        // What the pill does when the Worker exchange lands.
        final context = tester.element(find.byType(SignInScreen).first);
        GoRouter.of(context).go('/browse');
        await tester.pumpAndSettle();

        expect(routes, ['/browse']);
        expect(
          find.text('Telugu'),
          findsNothing,
          reason: 'no picker may be left over the feed',
        );
        expect(find.byType(SignInScreen), findsNothing);
      },
    );
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
