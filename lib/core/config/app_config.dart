import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Build-time config. Values arrive via `--dart-define-from-file=env/dev.json`.
/// No secrets ever live here — the app holds none (CLAUDE.md §9).
abstract final class AppConfig {
  /// The media CDN — the custom domain in both env files. Never the bucket's
  /// r2.dev origin: Cloudflare rate-limits it and Cache Rules/WAF do not apply
  /// there (CLAUDE.md §2), so the default matches the env files rather than
  /// keeping a throttled fallback alive.
  static const cdnBaseUrl = String.fromEnvironment(
    'R2_CDN_BASE_URL',
    defaultValue: 'https://arul-cdn.hsrutility.com',
  );

  /// Base URL for the Cloudflare Worker API (`arul-api.hsrutility.com` in both
  /// env files). Empty only in define-less builds — see [hasBackend].
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

  /// Privacy policy — Arul's OWN page, not a shared one.
  ///
  /// Until 2026-08-20 both apps pointed at hsrutility.com/privacy/, one document
  /// titled "Privacy Policy — Pakiza & Arul". The site now gives each app a
  /// self-contained sub-site, and these point into Arul's. The shared page still
  /// resolves — it redirects to the website's own policy — so an older installed
  /// build does not 404, but it no longer describes this app and must not be
  /// pointed at again.
  ///
  /// The trailing slash is required. Astro serves these as directories and 308s
  /// the slash-less form; without it the WebView shows a redirect it did not ask
  /// for on the way to a policy screen.
  ///
  /// NOTE: the Play listing carries its own privacy-policy URL — changing this
  /// constant does NOT change that, and the two must not disagree. Update the
  /// listing in the same pass.
  static const privacyUrl = String.fromEnvironment(
    'PRIVACY_URL',
    defaultValue: 'https://hsrutility.com/arul/privacy-policy/',
  );

  /// Terms & Conditions, linked from the Settings footer beside [privacyUrl].
  /// Arul's own, published at the same time and under the same rules as above.
  static const termsUrl = String.fromEnvironment(
    'TERMS_URL',
    defaultValue: 'https://hsrutility.com/arul/terms/',
  );

  /// Refund & Cancellation Policy, the third entry in the Settings footer.
  /// Read in-app by `PolicyScreen` exactly like the other two, and subject to the
  /// same trailing-slash rule.
  static const refundUrl = String.fromEnvironment(
    'REFUND_URL',
    defaultValue: 'https://hsrutility.com/arul/refund-policy/',
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
