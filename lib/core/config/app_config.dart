import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Build-time config. Values arrive via `--dart-define-from-file=env/dev.json`.
/// No secrets ever live here — the app holds none (CLAUDE.md §9).
abstract final class AppConfig {
  /// The bucket's public r2.dev origin — CURRENTLY the CDN for BOTH dev and
  /// prod (env/*.json ship this exact URL, and v1.0.0+20 released on it). A
  /// deliberate interim: r2.dev is throttled, and the move to a unified custom
  /// CDN domain (`arul-cdn.hsrutility.com`) is still pending.
  static const cdnBaseUrl = String.fromEnvironment(
    'R2_CDN_BASE_URL',
    defaultValue: 'https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev',
  );

  /// Base URL for the Cloudflare Worker API. Set in BOTH env files to the
  /// worker's workers.dev origin; the custom `arul-api.hsrutility.com` domain
  /// is still pending. Empty only in define-less builds — see [hasBackend].
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Web OAuth 2.0 client ID from the NEW Arul Google Cloud project.
  /// Used as `serverClientId` in GoogleSignIn.instance.initialize() so the
  /// returned idToken's `aud` matches what the Worker verifies.
  static const googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// Android OAuth 2.0 client ID (SHA-1 fingerprint registered in GCP).
  static const googleAndroidClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_CLIENT_ID',
  );

  static const posthogKey = String.fromEnvironment('POSTHOG_KEY');
  static const posthogHost = String.fromEnvironment('POSTHOG_HOST');
  static const metaAppId = String.fromEnvironment('META_APP_ID');

  /// Meta (Facebook) SDK client token — required alongside [metaAppId] to
  /// initialise App Events. Meta analytics stay OFF until this is set.
  static const metaClientToken = String.fromEnvironment('META_CLIENT_TOKEN');

  static const supportEmail = String.fromEnvironment(
    'SUPPORT_EMAIL',
    defaultValue: 'support@hsrutility.com',
  );

  static const privacyUrl = String.fromEnvironment(
    'PRIVACY_URL',
    defaultValue: 'https://hsrapps.com/arul/privacy-policy/',
  );

  /// Always true in real builds — the Worker has been live since 2026-07-14 and
  /// both env files set API_BASE_URL. The false branch is a legacy safety net
  /// for define-less local runs, where gated actions degrade to no-op stubs and
  /// the app runs standalone off the public CDN.
  static bool get hasBackend => apiBaseUrl.isNotEmpty;

  /// Whether Google sign-in is configured with a REAL web client id. The Arul
  /// Google Cloud project exists and both env files carry real ids — only
  /// env.example.json still ships the `TODO…` sentinel. On that sentinel (or in
  /// a define-less build) auth degrades gracefully: no auto-launch, and sign-in
  /// shows an error instead of failing against a bogus audience.
  static bool get googleAuthConfigured => isRealValue(googleWebClientId);

  /// Whether Meta App Events should initialise + receive the ★ conversion
  /// events. Requires BOTH the App ID and the client token to be present and
  /// non-placeholder — mirrors the guard in `analyticsServiceProvider`.
  static bool get metaEnabled =>
      isRealValue(metaAppId) && isRealValue(metaClientToken);

  /// Whether PostHog should initialise + receive events. Same key guard in
  /// `main()` and `analyticsServiceProvider`, so key-less dev builds and
  /// `flutter test` send nothing.
  static bool get posthogEnabled => isRealValue(posthogKey);

  /// A dart-define is "real" when it's non-empty and not one of our env-file
  /// placeholder sentinels (`YOUR_…` / `placeholder…` / `TODO…` / `phc_TODO`).
  static bool isRealValue(String v) =>
      v.isNotEmpty &&
      !v.startsWith('YOUR_') &&
      !v.startsWith('placeholder') &&
      !v.startsWith('TODO') &&
      !v.endsWith('TODO');

  /// True when running under `flutter test` (the runner sets this env var).
  static final bool isFlutterTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// Whether Firebase (Crashlytics + Performance + GA4) initialises and receives
  /// events. Firebase runs in every real build (debug/profile/release) and is
  /// skipped only under `flutter test` (no platform channel).
  ///
  /// Gated on the `FIREBASE_ENABLED` dart-define (an Arul delta — the reference
  /// is always-on) so `flutter test` and define-less builds stay inert: enabling
  /// the flag without android/app/google-services.json makes
  /// `Firebase.initializeApp()` fail. Both env files already set it to `true`,
  /// and the file is present locally — but it is git-ignored, so a fresh clone
  /// must supply its own before the flag can be turned on.
  static bool get firebaseEnabled =>
      !isFlutterTest && const bool.fromEnvironment('FIREBASE_ENABLED');

  /// Logs key config in debug. Deliberately assert-free: every real build sets
  /// API_BASE_URL, but an empty one stays a SUPPORTED state for define-less
  /// local runs ([hasBackend] = false stubs).
  static void validate() {
    if (kDebugMode) {
      debugPrint('[AppConfig] apiBaseUrl=$apiBaseUrl (hasBackend=$hasBackend)');
      debugPrint('[AppConfig] cdnBaseUrl=$cdnBaseUrl');
      debugPrint('[AppConfig] googleAuthConfigured=$googleAuthConfigured');
    }
  }
}
