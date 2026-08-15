import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  BootTrace.mark('main() entry');
  if (!AppConfig.firebaseEnabled) {
    await _startApp();
    return;
  }

  // Run the whole app inside a guarded zone so uncaught async errors are
  // reported, and route Flutter framework + platform errors to Crashlytics as
  // fatal.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await Firebase.initializeApp();
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
      await FirebasePerformance.instance.setPerformanceCollectionEnabled(true);
      // GA4 analytics — the product-analytics mirror of PostHog AND the
      // conversion source for Google Ads (link the Firebase project ↔ Google
      // Ads account in the console; no code). Events are sent via
      // GoogleAnalyticsService behind the AnalyticsService seam. Enabling here
      // (not per-event) also turns on auto-collected first_open/screen_view.
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
      BootTrace.mark('firebase init done');

      FlutterError.onError =
          FirebaseCrashlytics.instance.recordFlutterFatalError;
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

/// Configures the app (system UI, image cache, PostHog, Meta, Google Sign-In,
/// referral capture) and runs it inside a Riverpod scope. Shared by the
/// Firebase and non-Firebase entry paths above.
Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.validate();

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
  // room there to await a prefs handle.
  // Encrypted-storage channel + keystore init, started here so the stored-
  // session check — which gates how early sign-in can launch — is not paying
  // for it. Fire-and-forget; see ApiClient.warmSecureStorage.
  unawaited(ApiClient.warmSecureStorage());

  BootTrace.mark('SharedPreferences start');
  final prefs = await SharedPreferences.getInstance();
  BootTrace.mark('SharedPreferences done');

  // PostHog — lean config: manual events only, and only for the ~5% analytics
  // panel (AnalyticsCohort). Session replay OFF and surveys OFF, and we never
  // install PosthogObserver/PostHogWidget, so there is no element-autocapture.
  //
  // captureApplicationLifecycleEvents is ON (2026-08-13). It emits
  // `Application Opened`/`Backgrounded`/`Installed`/`Updated` from inside the
  // native SDK — these never pass through AnalyticsService, so they cannot be
  // filtered by AllowlistedAnalyticsService and the ONLY control over them is
  // this flag. It was off while PostHog was a cost-trimmed 5% panel; with the
  // panel at 100% these are what make sessions, DAU and retention resolvable
  // inside PostHog rather than only in GA4, and every funnel here is read
  // against them. Re-check at ~30k MAU: at a few sessions a day per user they
  // are the largest single source of billed volume in the app.
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
      ..captureApplicationLifecycleEvents = true
      ..sessionReplay = false
      ..surveys = false
      ..debug = kDebugMode;
    // Fire-and-forget, NOT awaited: setup() does native init and opens the
    // SDK's first network work, and awaiting it here put that on the critical
    // path to the first frame for every panel member. Nothing captures before
    // the first user action anyway (lifecycle autocapture is off above), and
    // this matches the fire-and-forget contract every other PostHog call in the
    // app already uses (PostHogAnalyticsService).
    unawaited(Posthog().setup(config));
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
