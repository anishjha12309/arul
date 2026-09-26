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
import 'core/analytics/analytics_service.dart';
import 'core/analytics/posthog_analytics_service.dart';
import 'core/deeplink/deep_link_target.dart';
import 'core/experiments/experiments.dart';
import 'core/deeplink/deferred_link_service.dart';
import 'core/api/api_client.dart';
import 'core/auth/google_sign_in_init.dart';
import 'core/config/app_config.dart';
import 'core/connectivity/connectivity_provider.dart';
import 'core/connectivity/data_saver.dart';
import 'core/config/build_info.dart';
import 'core/crash/non_crash_errors.dart';
import 'core/perf/boot_trace.dart';
import 'core/providers/geo_language_service.dart';
import 'core/providers/locale_provider.dart';
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
    LaunchLinkProbe.start();
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
      // Whether there is a network at all, known before the splash decides to hold the sign-in sheet.
      LaunchLinkProbe.start();
      await Firebase.initializeApp();
      BootTrace.mark('firebase core initialized');
      // The three collection toggles are re-affirmations: Crashlytics, Performance and Analytics all
      // collect BY DEFAULT and their native SDKs start from the manifest before Dart runs (the app-start
      // trace and first_open are native). Awaiting them here put three Binder round trips ahead of the
      // first frame for nothing -> they run after the first frame (see `_affirmCollection`).
      // GA4 is PostHog's mirror AND the Google Ads conversion source -> link the Firebase project ↔
      // the Ads account in the console; no code. Events go through `GoogleAnalyticsService` behind the
      // `AnalyticsService` seam.

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
/// `app_language`, `language_source` and `geo_region` are primed BEFORE setup, synchronously, read
/// straight from prefs because Riverpod does not exist yet -> every capture carries the language the
/// app opened in, including the sheet-first `login_attempt` that fires between native setup and the
/// register round trip (`PostHogAnalyticsService.track`).
Future<void> _startPostHog(
  PostHogConfig config,
  SharedPreferences prefs,
) async {
  final phone = WidgetsBinding.instance.platformDispatcher.locales;
  final experiments = Experiments.read(prefs);
  final lang = resolveAppLocale(
    prefs.getString(appLocalePrefsKey),
    prefs.getString(geoLangPrefsKey),
    phone,
    useGeo: experiments.geoLanguageApplies,
  ).languageCode;
  final origin = resolveLanguageOrigin(prefs, phone);
  PostHogAnalyticsService.prime({
    kAppLanguageProperty: lang,
    kLanguageSourceProperty: origin.source.key,
    kGeoRegionProperty: origin.geoRegion,
    ...experiments.analyticsProperties,
    // Only when the probe has ALREADY answered — priming an unresolved `mid` would stamp a guess
    // on the pre-login events. `app.dart` registers the real rung the moment it lands, and
    // `register` overwrites a primed key, so the two can never disagree.
    if (DeviceQuality.isResolved)
      kDeviceTierProperty: DeviceQuality.resolved.name,
  });
  await Posthog().setup(config);
  await PostHogAnalyticsService.started();
  if (!AnalyticsCohort.isFreshInstall) return;
  await Posthog().capture(eventName: ArulEvents.applicationInstalled);
}

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

  // Then re-ceiling it by device tier, WITHOUT awaiting: the probe is one channel hop but it sits
  // on the cold-start path the sign-in funnel is measured on, and the 32 MB default above is the
  // safe answer for every phone in the meantime. The tier lands inside the splash, long before the
  // feed decodes anything at scale.
  //   low  — 24 MB: a 2–3 GB phone is where a thrashing cache turns into an OOM kill.
  //   mid  — 32 MB: unchanged, the measured line (48 MB peaked at 525 MB PSS on an mt6878).
  //   high — 40 MB: ~5 wallpapers of headroom on an 8 GB phone, still under that measured 48.
  unawaited(
    DeviceQuality.tier.then((tier) {
      final (bytes, count) = switch (tier) {
        DeviceTier.low => (24 << 20, 30),
        DeviceTier.mid => (32 << 20, 40),
        DeviceTier.high => (40 << 20, 48),
      };
      PaintingBinding.instance.imageCache
        ..maximumSizeBytes = bytes
        ..maximumSize = count;
    }),
  );

  // Asked before the splash warms the feed, which is the first reader.
  unawaited(DataSaver.refresh());

  // Wallpaper-apply persists its restore flags on the path to a native call that can recreate the
  // Activity, with no room there to await a handle -> resolve prefs before `runApp`.
  BootTrace.mark('SharedPreferences start');
  final prefs = await SharedPreferences.getInstance();
  BootTrace.mark('SharedPreferences done');

  await PlayInstall.resolved;
  debugPrint(
    '[Analytics] PostHog sink: ${PlayInstall.isPlay ? "on (Play install)" : "OFF (sideloaded)"}',
  );

  // Called UNCONDITIONALLY, never as the last term of an `&&`. `resolve` returns cohort membership
  // but its other job is to set `AnalyticsCohort.isFreshInstall`, which the splash reads to skip the
  // first secure-storage read (`api_auth_service` authSeed) — a decision about STARTUP, not about
  // analytics. Short-circuited behind `isPlay`, that flag stayed false on every non-Play install and
  // the splash paid the keystore master-key setup before it could ask Google for an account: 2937ms
  // vs 643ms to `signIn: google surface opening`, measured on a vivo 1916 / Android 9 fresh install.
  // Play installs always ran it and are unaffected; what this restores is that a SIDELOAD — the only
  // build we can ever put on a test phone — measures the same startup path real users get.
  final inCohort = AnalyticsCohort.resolve(prefs);
  // The sign-in factorial's two coins, dealt once off the same first-launch marker.
  Experiments.drawIfFreshInstall(
    prefs,
    freshInstall: AnalyticsCohort.isFreshInstall,
    qaArms: PlayInstall.isPlay
        ? ''
        : const String.fromEnvironment('QA_EXP_ARMS'),
  );
  // A fresh install's first process arms the one `GET /geo` the splash fires -> an update never does.
  GeoLanguageService.markIfFreshInstall(
    prefs,
    freshInstall: AnalyticsCohort.isFreshInstall,
  );
  if (AppConfig.posthogEnabled && PlayInstall.isPlay && inCohort) {
    final config = PostHogConfig(AppConfig.posthogKey)
      ..host = AppConfig.posthogHost
      ..captureApplicationLifecycleEvents = false
      ..sessionReplay = false
      ..surveys = false
      // Send every event the moment it is captured. The default batches 20 events or 30 s, and a
      // person who opens the app, meets the Google sheet and leaves inside that window takes the
      // install AND the sign-in outcome with them -> 6 in 100 installs read as "install, then
      // nothing", and some never registered at all. The journey is a handful of events per person,
      // so one request each costs nothing that matters.
      ..flushAt = 1
      ..debug = kDebugMode;
    unawaited(_startPostHog(config, prefs));
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
    unawaited(_affirmCollection());
  });
}

/// Re-affirms the collection defaults AFTER the first frame, off the sign-in's critical path.
///
/// Every SDK here already collects by default and starts natively from the manifest, so nothing is
/// lost by the wait: crashes before this point are still caught by the native SDK, the app-start
/// trace and `first_open` are native, and the Meta SDK auto-logs the install and launch itself
/// (`activateApp()` only re-affirms the launch event; the ★ conversions go through
/// `MetaAnalyticsService`). What the wait buys is four Binder round trips out of the window between
/// process start and Google's account sheet, on exactly the phones where that window is longest.
/// Key-less dev builds and `flutter test` have no platform channel -> the same gates as before.
Future<void> _affirmCollection() async {
  if (AppConfig.firebaseEnabled) {
    await Future.wait([
      FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true),
      FirebasePerformance.instance.setPerformanceCollectionEnabled(true),
      FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true),
    ]).catchError((Object _) => <void>[]);
  }
  if (AppConfig.metaEnabled) {
    await FacebookAppEvents().activateApp().catchError((Object _) {});
  }
}
