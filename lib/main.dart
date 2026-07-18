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
import 'core/config/app_config.dart';
import 'core/providers/shared_preferences_provider.dart';
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

  // PostHog — lean config: manual events only. Session replay OFF and surveys
  // OFF; lifecycle events ON for free DAU/retention. We never install
  // PosthogObserver/PostHogWidget, so there is no element-autocapture. Skipped
  // entirely when no real key is set (placeholder/empty), keeping key-less dev
  // builds offline — mirrors the guard in analyticsServiceProvider.
  if (AppConfig.posthogEnabled) {
    final config = PostHogConfig(AppConfig.posthogKey)
      ..host = AppConfig.posthogHost
      ..captureApplicationLifecycleEvents = true
      ..sessionReplay = false
      ..surveys = false
      ..debug = kDebugMode;
    await Posthog().setup(config);
  }

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
  final prefs = await SharedPreferences.getInstance();

  // Referral attribution: read the Play Install Referrer once per install and
  // stash any referral code for the first sign-in. Fire-and-forget — off the
  // critical path and a no-op without Play Services.
  unawaited(InstallReferrerService(prefs).captureOnce());

  // google_sign_in v7: initialize the singleton once at startup. Skipped while
  // GOOGLE_WEB_CLIENT_ID is the TODO placeholder (no Arul Google Cloud project
  // yet) — sign-in then degrades to a graceful failure instead of a crash-loop
  // against Google's servers with a bogus audience.
  if (AppConfig.googleAuthConfigured) {
    try {
      await GoogleSignIn.instance.initialize(
        serverClientId: AppConfig.googleWebClientId,
      );
    } catch (e) {
      // Non-fatal: authenticate() will surface a localized failure + retry.
      debugPrint('[main] GoogleSignIn.initialize failed: $e');
    }
  }

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const ArulApp(),
    ),
  );
}
