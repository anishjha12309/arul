import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/analytics/analytics_cohort.dart';
import 'core/analytics/analytics_events.dart';
import 'core/deeplink/deep_link_target.dart';
import 'core/deeplink/deferred_link_service.dart';
import 'core/api/api_client.dart';
import 'core/auth/google_sign_in_init.dart';
import 'core/config/app_config.dart';
import 'core/crash/non_crash_errors.dart';
import 'core/perf/boot_trace.dart';
import 'core/providers/shared_preferences_provider.dart';
import 'features/notifications/data/notification_service.dart';
import 'features/notifications/providers/notification_providers.dart';
import 'features/referral/data/install_referrer_service.dart';

/// App entry point.
///
/// Crashlytics, Performance and GA4 run in EVERY real build — debug, profile and release -> the
/// dashboards receive data during development too.
/// `flutter test` has no platform channel and a build without `google-services.json` has no config ->
/// both would throw -> `AppConfig.firebaseEnabled` gates them, the same guard
/// `crashReporterProvider` / `performanceMonitorProvider` / `analyticsServiceProvider` use, so the
/// SDK is never touched uninitialised.
Future<void> main() async {
  _silenceLogsInRelease();
  BootTrace.mark('main() entry');
  if (!AppConfig.firebaseEnabled) {
    _maybeEnableFlutterDriver();
    WidgetsFlutterBinding.ensureInitialized();
    unawaited(ApiClient.warmSecureStorage());
    await _startApp();
    return;
  }

  // Guarded zone -> uncaught async errors get reported -> framework and platform errors route to
  // Crashlytics too.
  await runZonedGuarded(
    () async {
      _maybeEnableFlutterDriver();
      WidgetsFlutterBinding.ensureInitialized();
      // Encrypted-storage + keystore init is the longest pole to the account picker on a fresh install
      // (the stored-session check gates `authenticate()`, and its first read pays master-key setup) ->
      // fire it BEFORE Firebase so the two overlap; after Firebase serialised the costs.
      // Fire-and-forget -> see `ApiClient.warmSecureStorage`.
      unawaited(ApiClient.warmSecureStorage());
      await Firebase.initializeApp();
      BootTrace.mark('firebase core initialized');
      // The three collection toggles are independent platform-channel calls -> run them concurrently.
      // GA4 is PostHog's mirror AND the Google Ads conversion source -> link the Firebase project ↔
      // the Ads account in the console; no code. Events go through `GoogleAnalyticsService` behind the
      // `AnalyticsService` seam.
      // Enabling COLLECTION (not per-event) is also what turns on auto-collected first_open/screen_view.
      await Future.wait([
        FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true),
        FirebasePerformance.instance.setPerformanceCollectionEnabled(true),
        FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true),
      ]);
      BootTrace.mark('firebase init done');

      // Assigning `recordFlutterFatalError` straight to `FlutterError.onError` swallows the default
      // presenter -> a layout error paints its banner with ZERO logcat output (no "RenderFlex
      // overflowed", no widget tree), so a logcat overflow sweep reads clean on broken screens ->
      // WRAP, don't replace: `presentError` first, and Crashlytics still gets every error.
      // Same line in Pakiza.
      // FATAL is the default -> `isNonCrashError` demotes what the app provably survives (image loads,
      // transport failures) -> the crash-free rate measures crashes; see that function for why.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        FirebaseCrashlytics.instance.recordFlutterError(
          details,
          fatal: !isNonCrashError(details.exception, library: details.library),
        );
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(
          error,
          stack,
          fatal: !isNonCrashError(error),
        );
        return true;
      };

      await _startApp();
    },
    (error, stack) => FirebaseCrashlytics.instance.recordError(
      error,
      stack,
      fatal: !isNonCrashError(error),
    ),
  );
}

/// Routes every `debugPrint` — this app's and every package's — into a no-op in release.
///
/// A Play install must leak nothing readable with `adb logcat` -> one assignment is the whole Dart
/// half of the release-hygiene contract -> call sites stay as they are and stay useful in debug.
/// Field triage -> sideload a release APK with `--dart-define=DIAG=true` and the logs come back.
/// `kReleaseMode` is false in debug and profile -> the compiler drops the whole guard there.
/// Crashlytics is the only diagnostic channel that reaches a Play install; nothing here changes that.
void _silenceLogsInRelease() {
  if (kReleaseMode && !const bool.fromEnvironment('DIAG')) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
}

/// Agent UI automation — Dart MCP `dtd` discovery + `flutter_driver_command`; workflow in the
/// on-device skill.
///
/// Opt-in per run with `--dart-define=ENABLE_FLUTTER_DRIVER=true` on top of the usual define file ->
/// the const gate compiles the extension out of every other build.
/// The extension installs its own driver binding and asserts it owns `WidgetsBinding.instance` -> a
/// normal binding created first is fatal -> call this BEFORE `ensureInitialized()` on BOTH paths.
void _maybeEnableFlutterDriver() {
  if (const bool.fromEnvironment('ENABLE_FLUTTER_DRIVER')) {
    enableFlutterDriverExtension();
  }
}

/// Starts the PostHog SDK, then emits the one autocaptured event worth keeping.
///
/// Disabling `captureApplicationLifecycleEvents` unregisters the integration that owns
/// `Application Installed` (`PostHogAppInstallIntegration`), and the flag cannot be narrowed to one
/// event -> capture it by hand.
/// Reuse the SDK's own event NAME -> existing PostHog insights keep resolving; the native SDK stamps
/// `$app_version`/`$app_build` either way, so nothing is poorer than the autocaptured one.
/// Captured on the SDK, NOT through `AnalyticsService` -> it is PostHog bootstrap, not a `track()`
/// call site (the allow-list governs only those), GA4 auto-collects `first_open` for the same moment,
/// and a name with a space is not a legal GA4 event name.
/// A capture before native init finishes is DROPPED -> await `setup()` first.
Future<void> _startPostHog(PostHogConfig config) async {
  await Posthog().setup(config);
  if (!AnalyticsCohort.isFreshInstall) return;
  await Posthog().capture(eventName: ArulEvents.applicationInstalled);
}

/// Configures the app (system UI, image cache, PostHog, Meta, Google Sign-In,
/// referral capture) and runs it inside a Riverpod scope. Shared by the
/// Firebase and non-Firebase entry paths above.
Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();

  // Without a client Flutter never builds semantics -> `uiautomator dump` returns one empty
  // FlutterView -> hold it open in debug so tools/drive.mjs (on-device skill) sees labelled nodes.
  // Debug only -> profile measures jank and must not pay the semantics cost; release keeps stock
  // behaviour, where TalkBack and friends request it themselves.
  // The handle is never disposed -> semantics stays on for the whole run.
  if (kDebugMode) {
    SemanticsBinding.instance.ensureSemantics();
  }

  // Edge-to-edge is already the default at targetSdk 35+ and OS-enforced (the immersive modes are
  // no-ops) -> stated anyway so the intent is legible rather than inherited by accident.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  // Every catalog asset is 9:16 -> portrait only. Android 16+ ignores this on large screens by
  // policy; phones honour it, and phones are the whole install base.
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );

  // A 1080x1920 wallpaper decodes to ~8.3 MB of RGBA whatever its file size -> Flutter's default
  // 100 MB image cache holds only ~12 -> thrash, and an OOM kill on a 2 GB device.
  // 32 MB, not the default 100: on a MediaTek mt6878 a heavy browse (20 grid flings + 10 viewer
  // pages) peaked at 525 MB PSS with a 48 MB cache, most of it GPU texture memory.
  // The disk cache still holds the bytes -> a smaller memory cache costs a re-DECODE on scroll-back,
  // never a re-download.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 32 << 20
    ..maximumSize = 40;

  // The native Meta SDK auto-initialises and auto-logs install/launch from the AndroidManifest
  // meta-data (app id + client token baked in from dart-defines) -> `activateApp()` only re-affirms
  // the launch event; the ★ conversions go explicitly through `MetaAnalyticsService`.
  // Key-less dev builds and `flutter test` have no platform channel -> gate on `metaEnabled`,
  // mirroring the PostHog guard and `analyticsServiceProvider`.
  // Startup work regardless of Firebase -> it lives here on the shared path.
  if (AppConfig.metaEnabled) {
    unawaited(FacebookAppEvents().activateApp());
  }

  // Wallpaper-apply persists its restore flags on the path to a native call that can recreate the
  // Activity, with no room there to await a handle -> resolve prefs before `runApp`.
  BootTrace.mark('SharedPreferences start');
  final prefs = await SharedPreferences.getInstance();
  BootTrace.mark('SharedPreferences done');

  // Lean config: manual events only, session replay and surveys OFF, and no
  // `PosthogObserver`/`PostHogWidget` anywhere -> no element autocapture and no `$screen` at all.
  // `captureApplicationLifecycleEvents` is OFF (owner's call: PostHog shows the journey and nothing
  // else). The flag is all-or-nothing and its events never pass through `AnalyticsService`, so it is
  // the ONLY control over them -> keeping `Application Installed` would also buy `Application
  // Opened`/`Backgrounded` on every launch and backgrounding — most of the event stream and none of
  // the funnel -> off, and the install event is re-emitted by hand below.
  // Verified against posthog-android 3.58.3, not assumed: sessions still work (the lifecycle observer
  // is registered either way — only the two captures inside it are gated), and GA4 still
  // auto-collects first_open/session_start/screen_view at 100%, where DAU and retention are read.
  // The cohort gates `setup()` itself, not individual captures -> a non-panel install pays zero
  // native init, network and battery, which matters on the budget devices this app targets, and an
  // SDK that never started cannot autocapture.
  // The cohort draw is persisted in prefs -> this must stay BELOW the prefs await.
  // Mirrored in Pakiza -> keep both in sync.
  if (AppConfig.posthogEnabled && AnalyticsCohort.resolve(prefs)) {
    final config = PostHogConfig(AppConfig.posthogKey)
      ..host = AppConfig.posthogHost
      ..captureApplicationLifecycleEvents = false
      ..sessionReplay = false
      ..surveys = false
      ..debug = kDebugMode;
    // `setup()` does native init and opens the SDK's first network work -> awaiting it here puts that
    // on the critical path to the first frame for every panel member -> fire-and-forget, matching the
    // contract every other PostHog call already uses (`PostHogAnalyticsService`).
    // Nothing captures before the first user action anyway — lifecycle autocapture is off above.
    unawaited(_startPostHog(config));
  }

  // The Play Install Referrer is read once per install: the referral code for the first sign-in, and,
  // for an ad/share tap that predates the install, the wallpaper or ringtone to open plus the
  // language the ad was in. Fire-and-forget -> off the critical path, a no-op without Play Services.
  // `captureOnce` needs an async Play Services round-trip -> on a first launch it can land either
  // side of the feed draining its first catalog -> seed the deep link from BOTH ends: the persisted
  // values here, before any UI exists, for the race it loses; `captureOnce` seeds `ArulDeepLink`
  // itself for the race it wins.
  // Whoever consumes a value clears it (the tab that shows the target, `DeepLinkLocaleSync` for the
  // language) -> each is delivered exactly once however the timing falls.
  final referrer = InstallReferrerService(prefs);
  final deferredTarget = referrer.pendingTarget;
  if (deferredTarget != null) ArulDeepLink.requestTarget(deferredTarget);
  final deferredLang = referrer.pendingLang;
  if (deferredLang != null) ArulDeepLink.requestLocale(deferredLang);
  unawaited(referrer.captureOnce());

  // Ad installs Play's referrer cannot describe arrive over the network instead — Google App
  // Campaigns hand their App URL to Analytics for Firebase, Meta ads to the SDK's deferred App Link
  // fetch. Native Android buffers both across the Flutter-engine startup race -> they feed the SAME
  // persisted one-shot handoff used above.
  // Fire-and-forget -> a network-delivered ad target can never delay the first frame.
  final deferredLinks = DeferredLinkService(referrer);
  unawaited(deferredLinks.start());

  // google_sign_in v7: initialize the singleton once at startup. Both env files
  // carry a real client id, so this runs in every real build; the guard only
  // matters for define-less / test runs, where sign-in degrades to a graceful
  // failure instead of a crash-loop against Google's servers with a bogus
  // audience.
  // NOT awaited: the wait is MOVED, not removed. `GoogleSignInInit.ready` is
  // awaited in the sign-in path right before `supportsAuthenticate()`, so the
  // v7 contract (initialize → authenticate) still holds — but an
  // already-signed-in launch, which never calls `authenticate()`, no longer
  // pays Credential Manager / Play Services init before the first frame.
  // `google_sign_in`'s own example does not await it either. Failure is
  // swallowed inside the holder (see its doc comment) so the unawaited future
  // can never reach the zone handler as a FATAL.
  //
  // The nonce is generated HERE, once per process, and handed to
  // `initialize()` — the only place the plugin accepts one. Every ID token
  // this process gets (sheet or button) then carries it, and the Worker
  // rejects a login whose request nonce and token claim disagree.
  if (AppConfig.googleAuthConfigured) {
    BootTrace.mark('GoogleSignIn.initialize started (not awaited)');
    GoogleSignInInit.start(
      serverClientId: AppConfig.googleWebClientId,
      nonce: GoogleSignInInit.generateNonce(),
    );
  }

  // Local devotional reminders. Constructed BEFORE runApp so a tap that LAUNCHED
  // the app has a live plugin to replay into, but `initialize()` is deliberately
  // NOT awaited here — see below.
  final notificationService = NotificationService();

  BootTrace.mark('runApp()');
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        notificationServiceProvider.overrideWithValue(notificationService),
      ],
      child: const ArulApp(),
    ),
  );

  // Notification setup (IANA timezone-database parse + channel creation) is
  // deferred ENTIRELY off the startup path. The tz parse is synchronous
  // UI-isolate work and channel creation is a Binder round-trip, and neither is
  // needed until either the reminders screen opens or the bootstrap provider
  // arms the schedule. Both of those call `initialize()` themselves, and it is
  // single-flight, so this is a warm-up rather than a prerequisite — dropping it
  // would cost latency, never correctness.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(notificationService.initialize().catchError((Object _) {}));
  });
}
