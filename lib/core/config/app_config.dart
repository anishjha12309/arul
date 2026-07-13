/// Build-time config. Values arrive via `--dart-define-from-file=env/dev.json`.
/// No secrets ever live here — the app holds none (CLAUDE.md §9).
abstract final class AppConfig {
  /// PREVIEW DEFAULT (UI phase only): the bucket's public r2.dev URL, so the feed
  /// renders REAL content before the Worker exists. It is throttled and must never
  /// ship — provisioning attaches `arul-cdn.hsrutility.com` and env/prod.json
  /// then overrides this.
  static const cdnBaseUrl = String.fromEnvironment(
    'R2_CDN_BASE_URL',
    defaultValue: 'https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev',
  );

  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static const supportEmail = String.fromEnvironment(
    'SUPPORT_EMAIL',
    defaultValue: 'support@hsrutility.com',
  );

  static const privacyUrl = String.fromEnvironment(
    'PRIVACY_URL',
    defaultValue: 'https://hsrapps.com/arul/privacy-policy/',
  );

  /// True once the Worker is provisioned; until then the app reads the bucket's
  /// import manifest directly and every gated action is a no-op stub.
  static bool get hasBackend => apiBaseUrl.isNotEmpty;
}
