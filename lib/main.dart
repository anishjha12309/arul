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
import 'package:google_sign_in/google_sign_in.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/analytics/analytics_cohort.dart';
import 'core/deeplink/deep_link_target.dart';
import 'core/deeplink/google_ads_deferred_link_service.dart';
import 'core/api/api_client.dart';
import 'core/config/app_config.dart';
import 'core/perf/boot_trace.dart';
import 'core/providers/shared_preferences_provider.dart';
import 'features/notifications/data/notification_service.dart';
import 'features/notifications/providers/notification_providers.dart';
import 'features/referral/data/install_referrer_service.dart';

/// App entry point.
///
/// Crash + performance telemetry (Firebase Crashlytics + Performance Monitoring)
/// and GA4 analytics run in **every real app build — debug, profile and
/// release** — so the dashboards receive data during development too. Two builds
/// skip Firebase: `flutter test` (the SDK has no platform channel and would
/// throw) and any build without android/app/google-services.json — both are
/// captured by `AppConfig.firebaseEnabled` (FIREBASE_ENABLED define + not a
/// test), the same guard used in `crashReporterProvider` /
/// `performanceMonitorProvider` / `analyticsServiceProvider`, so the SDK is
/// never touched uninitialised.
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

  // Run the whole app inside a guarded zone so uncaught async errors are
  // reported, and route Flutter framework + platform errors to Crashlytics as
  // fatal.
  await runZonedGuarded(
    () async {
      _maybeEnableFlutterDriver();
      WidgetsFlutterBinding.ensureInitialized();
      // Encrypted-storage channel + keystore init, fired BEFORE Firebase so the
      // two overlap. On a fresh install this is the longest pole on the path to
      // the account picker (the stored-session check gates `authenticate()`,
      // and its first read pays the keystore master-key setup); starting it
      // after Firebase serialised the two costs (boot trace, 2026-08-22).
      // Fire-and-forget; see ApiClient.warmSecureStorage.
      unawaited(ApiClient.warmSecureStorage());
      await Firebase.initializeApp();
      BootTrace.mark('firebase core initialized');
      // The three collection toggles are independent platform-channel calls —
      // run them concurrently, not serially.
      //
      // GA4 analytics — the product-analytics mirror of PostHog AND the
      // conversion source for Google Ads (link the Firebase project ↔ Google
      // Ads account in the console; no code). Events are sent via
      // GoogleAnalyticsService behind the AnalyticsService seam. Enabling
      // collection (not per-event) also turns on auto-collected
      // first_open/screen_view.
      await Future.wait([
        FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true),
        FirebasePerformance.instance.setPerformanceCollectionEnabled(true),
        FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true),
      ]);
      BootTrace.mark('firebase init done');

      // WRAP, don't replace. Assigning `recordFlutterFatalError` straight to
      // `FlutterError.onError` swallows the default presenter, so a layout
      // error paints its yellow-and-black banner on screen and emits ZERO
      // logcat output — no "A RenderFlex overflowed by N pixels", no widget
      // tree naming the culprit. A logcat-based overflow sweep then reports a
      // clean run on visibly broken screens. presentError first restores the
      // console dump; Crashlytics still gets every error, so nothing is traded
      // away for it. Same line in Pakiza (fixed there 2026-08-21).
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      await _startApp();
    },
    (error, stack) =>
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
  );
}

/// Release builds ship SILENT: one assignment routes every `debugPrint` — this
/// app's and every package's — into a no-op, so nothing a user can read with
/// `adb logcat` leaks from a Play install. It is the whole Dart half of the
/// release-hygiene contract; individual call sites stay as they are, which is
/// what keeps them useful in debug and profile.
///
/// Escape hatch for field triage: build a SIDELOADED release APK with
/// `--dart-define=DIAG=true` and the logs come back. Debug and profile are
/// untouched — `kReleaseMode` is false there, so the whole guard is dead code
/// the compiler drops.
///
/// Crashlytics is the only diagnostic channel that reaches a Play install;
/// nothing here changes that.
void _silenceLogsInRelease() {
  if (kReleaseMode && !const bool.fromEnvironment('DIAG')) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
}

/// Agent UI automation (Dart MCP server: `dtd` discovery +
/// `flutter_driver_command`) — workflow in the on-device skill. Opt-in per
/// run: `flutter run --dart-define=ENABLE_FLUTTER_DRIVER=true` on top of the
/// usual define file; the const gate compiles the extension out of every
/// other build. Must run BEFORE ensureInitialized() on both entry paths — the
/// extension installs its own driver binding and asserts it owns
/// `WidgetsBinding.instance`, which a normal binding created first would make
/// fatal.
void _maybeEnableFlutterDriver() {
  if (const bool.fromEnvironment('ENABLE_FLUTTER_DRIVER')) {
    enableFlutterDriverExtension();
  }
}

/// Starts the PostHog SDK, then emits the one autocaptured event worth keeping.
///
/// `Application Installed` is captured by hand because disabling
/// `captureApplicationLifecycleEvents` also unregisters the SDK integration that
/// owns it (`PostHogAppInstallIntegration` is only added when the flag is on),
/// and the flag cannot be narrowed to a single event. The SDK's own event NAME
/// is reused so existing PostHog insights keep resolving across the change, and
/// the native SDK stamps `$app_version`/`$app_build` onto every event anyway, so
/// nothing about the event is poorer than the autocaptured one.
///
/// Captured on the SDK directly, NOT through AnalyticsService: it belongs to the
/// PostHog bootstrap rather than to a `track()` call site (the allow-list only
/// governs those), GA4 already auto-collects `first_open` for the same moment,
/// and a name with a space is not a legal GA4 event name.
///
/// Awaits setup() before capturing — setup is fire-and-forget from the caller's
/// side, and capturing into an SDK that has not finished native init drops the
/// event.
Future<void> _startPostHog(PostHogConfig config) async {
  await Posthog().setup(config);
  if (!AnalyticsCohort.isFreshInstall) return;
  await Posthog().capture(eventName: 'Application Installed');
}

/// Configures the app (system UI, image cache, PostHog, Meta, Google Sign-In,
/// referral capture) and runs it inside a Riverpod scope. Shared by the
/// Firebase and non-Firebase entry paths above.
Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();

  // Keep the semantics tree built in debug so `uiautomator dump` sees
  // labelled, tappable nodes (tools/drive.mjs — on-device skill); without a
  // client Flutter never builds semantics and a dump is one empty
  // FlutterView. Debug-only on purpose: profile runs measure jank and must
  // not pay the semantics cost, and release keeps stock behaviour (TalkBack
  // and friends request it themselves). The returned handle is never
  // disposed — semantics stays on for the whole run.
  if (kDebugMode) {
    SemanticsBinding.instance.ensureSemantics();
  }

  // Edge-to-edge. This is already the default at targetSdk 35+ (and the OS
  // enforces it — the immersive modes are now no-ops), but it is stated here so
  // the intent is legible rather than inherited by accident.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  // Portrait only: every asset in the catalog is 9:16. (Android 16+ ignores this
  // on large screens by policy; phones honour it, which is the whole install base.)
  unawaited(
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
  );

  // A full-screen 1080x1920 wallpaper decodes to ~8.3 MB of RGBA regardless of
  // its file size, so Flutter's default 100 MB image cache holds only ~12 of them
  // — enough to thrash, and on a 2 GB device enough to get OOM-killed. Cap it.
  //
  // 32 MB, not the default 100: measured on a MediaTek mt6878, a heavy browse
  // (20 grid flings + 10 viewer pages) peaked at 525 MB PSS with a 48 MB cache,
  // most of it GPU texture memory. The disk cache still holds the bytes, so a
  // smaller memory cache costs a re-DECODE on scroll-back, never a re-download.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 32 << 20
    ..maximumSize = 40;

  // Meta (Facebook) App Events. The native SDK auto-initialises + auto-logs
  // install/launch via the AndroidManifest meta-data (app id + client token
  // baked in from dart-defines); the ★ conversion events are sent explicitly
  // through MetaAnalyticsService. We only nudge it here when a real app id +
  // client token are configured — `activateApp()` re-affirms the app-launch
  // event and is a no-op/no-cost otherwise. Skipped for key-less dev builds and
  // `flutter test` (no platform channel), mirroring the PostHog guard above and
  // `analyticsServiceProvider`. Belongs to startup regardless of Firebase, so it
  // lives here in the shared path.
  if (AppConfig.metaEnabled) {
    unawaited(FacebookAppEvents().activateApp());
  }

  // Resolved before runApp: the wallpaper-apply flow persists its restore flags
  // on the path to a native call that can recreate the Activity, and there is no
  // room there to await a prefs handle. (The secure-storage warm-up fires even
  // earlier — top of main(), before Firebase — see the comment there.)
  BootTrace.mark('SharedPreferences start');
  final prefs = await SharedPreferences.getInstance();
  BootTrace.mark('SharedPreferences done');

  // PostHog — lean config: manual events only, and only for the analytics panel
  // (AnalyticsCohort, currently every install). Session replay OFF and surveys
  // OFF, and we never install PosthogObserver/PostHogWidget, so there is no
  // element-autocapture and PostHog records no `$screen` at all.
  //
  // captureApplicationLifecycleEvents is OFF (owner's call, 2026-08-18: PostHog
  // shows the journey and nothing else). The flag is all-or-nothing and its
  // events never pass through AnalyticsService, so it is the ONLY control over
  // them — leaving it on to keep `Application Installed` also buys
  // `Application Opened`/`Backgrounded` on every launch and every backgrounding,
  // which was most of the event stream and none of the funnel. So it is off and
  // the install event is re-emitted by hand below.
  //
  // Two things this does NOT cost, both verified against posthog-android 3.58.3
  // rather than assumed: sessions still work (the lifecycle observer that
  // starts/ends them is registered either way — only the two captures inside it
  // are gated), and GA4 still auto-collects first_open/session_start/screen_view
  // at 100%, which is where open-the-app DAU and retention are read.
  //
  // The cohort check gates setup() itself rather than individual captures: a
  // non-panel install then does zero PostHog native init, network and battery
  // work — which also matters on the budget devices this app targets — and the
  // SDK's own autocapture can't fire if the SDK was never started. Moved below
  // the prefs await because the cohort draw is persisted there.
  //
  // Mirrored in Pakiza — keep both in sync.
  if (AppConfig.posthogEnabled && AnalyticsCohort.resolve(prefs)) {
    final config = PostHogConfig(AppConfig.posthogKey)
      ..host = AppConfig.posthogHost
      ..captureApplicationLifecycleEvents = false
      ..sessionReplay = false
      ..surveys = false
      ..debug = kDebugMode;
    // Fire-and-forget, NOT awaited: setup() does native init and opens the
    // SDK's first network work, and awaiting it here put that on the critical
    // path to the first frame for every panel member. Nothing captures before
    // the first user action anyway (lifecycle autocapture is off above), and
    // this matches the fire-and-forget contract every other PostHog call in the
    // app already uses (PostHogAnalyticsService).
    unawaited(_startPostHog(config));
  }

  // Referral attribution + deferred deep link: read the Play Install Referrer
  // once per install. It carries the referral code for the first sign-in AND,
  // for an ad/share tap that happened before this install existed, the wallpaper
  // to open. Fire-and-forget — off the critical path and a no-op without Play
  // Services.
  //
  // The deep-link half is seeded from BOTH ends on purpose. captureOnce needs an
  // async Play Services round-trip, so on the very first launch after an ad
  // install it can land either side of the feed draining its first catalog.
  // Seeding the already-persisted value here (before any UI exists) covers the
  // race it loses; captureOnce seeds ArulDeepLink itself for the race it wins.
  // The persisted copy is cleared by whoever actually consumes it, so a target
  // is delivered exactly once however the timing falls.
  final referrer = InstallReferrerService(prefs);
  final deferredWallpaper = referrer.pendingWallpaperId;
  if (deferredWallpaper != null) ArulDeepLink.request(deferredWallpaper);
  unawaited(referrer.captureOnce());

  // Eligible Google App Campaigns deliver their post-install App URL through
  // Google Analytics for Firebase rather than Play Install Referrer. Native
  // Android buffers that URL across the Flutter-engine startup race; this feeds
  // it into the SAME persisted one-shot target used above. Fire-and-forget so a
  // network-delivered ad target can never delay the first frame.
  final googleAdsDeferredLinks = GoogleAdsDeferredLinkService(referrer);
  unawaited(googleAdsDeferredLinks.start());

  // google_sign_in v7: initialize the singleton once at startup. Both env files
  // carry a real client id, so this runs in every real build; the guard only
  // matters for define-less / test runs, where sign-in degrades to a graceful
  // failure instead of a crash-loop against Google's servers with a bogus
  // audience.
  if (AppConfig.googleAuthConfigured) {
    BootTrace.mark('GoogleSignIn.initialize start');
    try {
      await GoogleSignIn.instance.initialize(
        serverClientId: AppConfig.googleWebClientId,
      );
    } catch (e) {
      // Non-fatal: authenticate() will surface a localized failure + retry.
      debugPrint('[main] GoogleSignIn.initialize failed: $e');
    }
    BootTrace.mark('GoogleSignIn.initialize done');
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
