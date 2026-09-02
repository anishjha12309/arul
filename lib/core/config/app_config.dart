import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Build-time config. Values arrive via `--dart-define-from-file=env/dev.json`.
/// No secrets ever live here — the app holds none (CLAUDE.md §9).
abstract final class AppConfig {
  /// The media CDN — the custom domain in both env files.
  /// Cloudflare rate-limits the r2.dev origin and Cache Rules/WAF never apply there -> never default to it.
  static const cdnBaseUrl = String.fromEnvironment(
    'R2_CDN_BASE_URL',
    defaultValue: 'https://arul-cdn.hsrutility.com',
  );

  /// Base URL for the Cloudflare Worker API. Empty only in define-less builds — see [hasBackend].
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Web OAuth 2.0 client ID, used as `serverClientId` at `initialize()`.
  /// So the returned idToken's `aud` matches what the Worker verifies.
  static const googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// Android OAuth 2.0 client ID — a RECORD, never read by the sign-in path.
  /// google_sign_in resolves it from package name + the installed binary's signing SHA-1.
  /// So this value cannot change which client a build authorizes through.
  /// Play re-signs the upload -> `env/prod.json` names the PLAY APP SIGNING client.
  /// The upload-keystore client only ever serves APKs signed locally (env.example.json).
  static const googleAndroidClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_CLIENT_ID',
  );

  static const posthogKey = String.fromEnvironment('POSTHOG_KEY');
  static const posthogHost = String.fromEnvironment('POSTHOG_HOST');
  static const metaAppId = String.fromEnvironment('META_APP_ID');

  /// Meta SDK client token — needed alongside [metaAppId]; Meta analytics stay OFF until it is set.
  static const metaClientToken = String.fromEnvironment('META_CLIENT_TOKEN');

  static const supportEmail = String.fromEnvironment(
    'SUPPORT_EMAIL',
    defaultValue: 'support@hsrutility.com',
  );

  /// Privacy policy — Arul's OWN page, never a shared one.
  ///
  /// The old `/privacy/` still resolves so older installs do not 404, but it now describes the WEBSITE.
  /// So it must never be pointed at again (CLAUDE.md §1).
  /// The trailing slash is REQUIRED — Astro serves these as directories and 308s the slash-less form.
  /// Without it the WebView shows a redirect nobody asked for on the way to a policy screen.
  /// The Play listing carries its OWN copy of this URL -> the two must not disagree; update both.
  static const privacyUrl = String.fromEnvironment(
    'PRIVACY_URL',
    defaultValue: 'https://hsrutility.com/arul/privacy-policy/',
  );

  /// Terms & Conditions, beside [privacyUrl] in the Settings footer. Arul's own, same rules as above.
  static const termsUrl = String.fromEnvironment(
    'TERMS_URL',
    defaultValue: 'https://hsrutility.com/arul/terms/',
  );

  /// Refund & Cancellation Policy, the third Settings-footer entry — same rules as the other two.
  static const refundUrl = String.fromEnvironment(
    'REFUND_URL',
    defaultValue: 'https://hsrutility.com/arul/refund-policy/',
  );

  /// Always true in real builds — both env files set API_BASE_URL.
  /// The false branch is for define-less local runs -> gated actions become no-op stubs off the CDN.
  static bool get hasBackend => apiBaseUrl.isNotEmpty;

  /// Whether Google sign-in has a REAL web client id — only env.example.json ships a `TODO…` sentinel.
  /// On the sentinel, or a define-less build, auth degrades: no auto-launch, an error, no bogus `aud`.
  static bool get googleAuthConfigured => isRealValue(googleWebClientId);

  /// Whether Meta App Events initialise and receive the ★ conversion events.
  /// Requires BOTH the App ID and the client token, non-placeholder — mirrors `analyticsServiceProvider`.
  static bool get metaEnabled =>
      isRealValue(metaAppId) && isRealValue(metaClientToken);

  /// Whether PostHog initialises and receives events — the same guard as `main()` and the provider.
  /// So key-less dev builds and `flutter test` send nothing.
  static bool get posthogEnabled => isRealValue(posthogKey);

  /// A dart-define is "real" when non-empty and not a placeholder sentinel (`YOUR_`/`placeholder`/`TODO`).
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

  /// Whether Firebase (Crashlytics + Performance + GA4) initialises and receives events.
  ///
  /// Runs in every real build — debug, profile, release — and is skipped only under `flutter test`.
  /// Gated on the `FIREBASE_ENABLED` define so tests and define-less builds stay inert.
  /// The flag without android/app/google-services.json makes `Firebase.initializeApp()` fail.
  /// That file is git-ignored -> a fresh clone must supply its own before turning the flag on.
  static bool get firebaseEnabled =>
      !isFlutterTest && const bool.fromEnvironment('FIREBASE_ENABLED');

  /// Logs key config in debug. Assert-FREE on purpose — an empty API_BASE_URL is a SUPPORTED state.
  /// Define-less local runs rely on it ([hasBackend] = false stubs).
  static void validate() {
    if (kDebugMode) {
      debugPrint('[AppConfig] apiBaseUrl=$apiBaseUrl (hasBackend=$hasBackend)');
      debugPrint('[AppConfig] cdnBaseUrl=$cdnBaseUrl');
      debugPrint('[AppConfig] googleAuthConfigured=$googleAuthConfigured');
    }
  }
}
