import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Build-time config. Values arrive via `--dart-define-from-file=env/dev.json`.
/// No secrets ever live here — the app holds none (CLAUDE.md §9).
abstract final class AppConfig {
  /// PREVIEW DEFAULT (pre-Phase-0): the bucket's public r2.dev URL, so the feed
  /// renders REAL content before the Worker exists. It is throttled and must never
  /// ship — provisioning attaches `arul-cdn.hsrutility.com` and env/prod.json
  /// then overrides this.
  static const cdnBaseUrl = String.fromEnvironment(
    'R2_CDN_BASE_URL',
    defaultValue: 'https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev',
  );

  /// Base URL for the Cloudflare Worker API. EMPTY until Phase 0 provisions
  /// `arul-api.hsrutility.com` — see [hasBackend].
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

  /// True once the Worker is provisioned; until then every gated action is a
  /// no-op stub and the app runs standalone off the public CDN.
  static bool get hasBackend => apiBaseUrl.isNotEmpty;

  /// Whether Google sign-in is configured with a REAL web client id. Until the
  /// Arul Google Cloud project exists, env files carry a `TODO…` placeholder —
  /// auth then degrades gracefully (no auto-launch, sign-in shows an error).
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
  /// Gated on the `FIREBASE_ENABLED` dart-define because Arul's
  /// android/app/google-services.json does not exist yet (the reference is
  /// always-on because its file always exists). Flip `FIREBASE_ENABLED=true` in
  /// env/*.json in the SAME change that adds android/app/google-services.json —
  /// enabling the flag without the file makes `Firebase.initializeApp()` fail.
  static bool get firebaseEnabled =>
      !isFlutterTest && const bool.fromEnvironment('FIREBASE_ENABLED');

  /// Logs key config in debug. Deliberately assert-free: an empty API_BASE_URL
  /// is a SUPPORTED state pre-Phase-0 ([hasBackend] = false stubs).
  static void validate() {
    if (kDebugMode) {
      debugPrint('[AppConfig] apiBaseUrl=$apiBaseUrl (hasBackend=$hasBackend)');
      debugPrint('[AppConfig] cdnBaseUrl=$cdnBaseUrl');
      debugPrint('[AppConfig] googleAuthConfigured=$googleAuthConfigured');
    }
  }
}
