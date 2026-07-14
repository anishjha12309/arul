import 'dart:async';

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
/// FIREBASE-REENABLE: the reference wraps everything below in a
/// `runZonedGuarded` that initialises Firebase (Crashlytics + Performance +
/// GA4) and routes Flutter/platform errors to Crashlytics, guarded by
/// `AppConfig.firebaseEnabled`. Restore that wrapper (see the reference
/// `main.dart`) once android/app/google-services.json exists.
Future<void> main() async {
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
