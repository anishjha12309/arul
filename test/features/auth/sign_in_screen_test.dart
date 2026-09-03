// The nudge is the only thing the sign-in wall says to a user who did not get in, so these pin the
// two ways it can lie: showing a line that is not true of THIS attempt, and offering a link that
// quietly does something else. A help tap in particular must never touch the sign-in attempt —
// re-entering the Google flow from a text link would put a second surface over the first, which is
// the one bug this screen exists to have fixed.

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/auth/data/sign_in_help_links.dart';
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

class _RecordingHelpLinks implements SignInHelpLinks {
  final List<String> opened = [];

  @override
  Future<void> openAccountSettings() async => opened.add('accountSettings');

  @override
  Future<void> openPlayServices() async => opened.add('playServices');
}

void main() {
  late _CountingAuthService auth;
  late _RecordingHelpLinks links;
  late List<String> routes;
  late SharedPreferences prefs;

  setUp(() async {
    auth = _CountingAuthService();
    links = _RecordingHelpLinks();
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
          signInHelpLinksProvider.overrideWithValue(links),
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

  group('the line each outcome shows', () {
    testWidgets('idle asks for an account and explains nothing', (
      tester,
    ) async {
      final l10n = await pump(tester);

      expect(find.text(l10n.signInSubtitleIdle), findsOneWidget);
      expect(find.text(l10n.signInGoogle), findsOneWidget);
      expect(find.text(l10n.signInCaption), findsOneWidget);
      // Nothing failed -> nothing to fix.
      expect(find.text(l10n.signInFixBackedOutSlow), findsNothing);
      expect(find.text(l10n.signInLinkAccountSettings), findsNothing);
      expect(find.text(l10n.signInLinkPlayServices), findsNothing);
      expect(find.text(l10n.signInLinkPlayStore), findsNothing);
    });

    testWidgets('the exchange is the ONE wait the app claims', (tester) async {
      final l10n = await pump(tester, outcome: SignInOutcome.backedOutQuick);
      SignInPhase.exchanging.value = true;
      await tester.pump();

      expect(find.text(l10n.signInSubtitleExchanging), findsOneWidget);
      expect(
        find.text(l10n.signInNudgeBackedOutQuick),
        findsNothing,
        reason: 'an attempt in flight has not failed yet',
      );
    });

    testWidgets('a quick back-out gets the plain retry line and no fix line', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.backedOutQuick);

      expect(find.text(l10n.signInNudgeBackedOutQuick), findsOneWidget);
      expect(find.byType(GestureDetector), findsWidgets);
      expect(find.text(l10n.signInFixBackedOutSlow), findsNothing);
    });

    testWidgets('a slow surface blames the phone, and offers no link', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.backedOutSlow);

      expect(find.text(l10n.signInNudgeBackedOutSlow), findsOneWidget);
      expect(find.text(l10n.signInFixBackedOutSlow), findsOneWidget);
      expect(find.text(l10n.signInLinkAccountSettings), findsNothing);
      expect(find.text(l10n.signInLinkPlayServices), findsNothing);
    });

    testWidgets('a surface that never drew never claims the user backed out', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.neverOpened);

      expect(find.text(l10n.signInNudgeNeverOpened), findsOneWidget);
      expect(find.text(l10n.signInNudgeBackedOutQuick), findsNothing);
      expect(find.text(l10n.signInFixBackedOutSlow), findsNothing);
    });

    testWidgets('the add-account walkout is told it needed no new account', (
      tester,
    ) async {
      final l10n = await pump(
        tester,
        outcome: SignInOutcome.addAccountAbandoned,
      );

      expect(find.text(l10n.signInNudgeAddAccount), findsOneWidget);
      expect(find.text(l10n.signInFixAddAccount), findsOneWidget);
      // Nothing outside the app can help here -> no link.
      expect(find.text(l10n.signInLinkAccountSettings), findsNothing);
    });

    testWidgets('a failed re-auth points at the phone\'s Google settings', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.reauthFailed);

      expect(find.text(l10n.signInNudgeReauth), findsOneWidget);
      expect(find.text(l10n.signInFixReauth), findsOneWidget);
      expect(find.text(l10n.signInLinkAccountSettings), findsOneWidget);
    });

    testWidgets('a closed window names Play services and links its listing', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.activityClosed);

      expect(find.text(l10n.signInNudgeActivityClosed), findsOneWidget);
      expect(find.text(l10n.signInFixActivityClosed), findsOneWidget);
      expect(find.text(l10n.signInLinkPlayServices), findsOneWidget);
    });

    testWidgets('a missing provider offers the update and nothing else', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.noProvider);

      expect(find.text(l10n.signInNudgeNoProvider), findsOneWidget);
      expect(find.text(l10n.signInLinkPlayStore), findsOneWidget);
      // The toast already carried the explanation -> the fix line is the link alone.
      expect(find.text(l10n.signInFixActivityClosed), findsNothing);
    });

    testWidgets('every outcome renders a subtitle — none falls through', (
      tester,
    ) async {
      for (final outcome in SignInOutcome.values) {
        final l10n = await pump(tester, outcome: outcome);
        final subtitle = switch (outcome) {
          SignInOutcome.backedOutQuick => l10n.signInNudgeBackedOutQuick,
          SignInOutcome.backedOutSlow => l10n.signInNudgeBackedOutSlow,
          SignInOutcome.neverOpened => l10n.signInNudgeNeverOpened,
          SignInOutcome.addAccountAbandoned => l10n.signInNudgeAddAccount,
          SignInOutcome.reauthFailed => l10n.signInNudgeReauth,
          SignInOutcome.activityClosed => l10n.signInNudgeActivityClosed,
          SignInOutcome.noProvider => l10n.signInNudgeNoProvider,
        };
        expect(find.text(subtitle), findsOneWidget, reason: outcome.name);
        expect(
          find.text(l10n.signInSubtitleIdle),
          findsNothing,
          reason: '${outcome.name} must not fall back to the idle line',
        );
      }
    });
  });

  group('a help link opens its target and touches nothing else', () {
    testWidgets('re-auth opens the account settings screen', (tester) async {
      final l10n = await pump(tester, outcome: SignInOutcome.reauthFailed);

      await tester.tap(find.text(l10n.signInLinkAccountSettings));
      await tester.pump();

      expect(links.opened, ['accountSettings']);
      expect(auth.signInCalls, 0, reason: 'a link tap is not a sign-in');
      expect(auth.abandonCalls, 0, reason: 'nor a cancel');
      expect(routes, isEmpty, reason: 'and it never leaves the wall');
    });

    testWidgets('a closed window opens the Play services listing', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.activityClosed);

      await tester.tap(find.text(l10n.signInLinkPlayServices));
      await tester.pump();

      expect(links.opened, ['playServices']);
      expect(auth.signInCalls, 0);
    });

    testWidgets('a missing provider opens the same listing', (tester) async {
      final l10n = await pump(tester, outcome: SignInOutcome.noProvider);

      await tester.tap(find.text(l10n.signInLinkPlayStore));
      await tester.pump();

      expect(links.opened, ['playServices']);
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

    testWidgets('the nudge survives the tap — the screen does not reset', (
      tester,
    ) async {
      final l10n = await pump(tester, outcome: SignInOutcome.reauthFailed);

      await tester.tap(find.text(l10n.signInLinkAccountSettings));
      await tester.pump();

      expect(find.text(l10n.signInNudgeReauth), findsOneWidget);
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
  // The way out of a language you cannot read, on the one screen where being stuck is terminal.
  // Everything here is about it NOT being part of the sign-in attempt: the pill owns that, and a
  // trigger that quietly re-entered the Google flow would put a second surface over the first.
  group('the language trigger', () {
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

    testWidgets('a pick re-renders the screen and PERSISTS', (tester) async {
      await pump(tester);
      expect(find.text('EN'), findsOneWidget);

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
}
