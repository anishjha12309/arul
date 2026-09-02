import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../data/models/app_config_model.dart';

/// A resolved onboarding clip: which language won and where its bytes are.
@immutable
class OnboardingVideoSource {
  const OnboardingVideoSource({required this.lang, required this.url});

  /// The language actually shown — NOT necessarily the one asked for: a link for a language with no
  /// cut yet (`hi`, until its dub lands) resolves to `en`, and analytics reports what really played.
  final String lang;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is OnboardingVideoSource && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Which cuts exist on the CDN when `app_config` has nothing to say.
///
/// The remote list is authoritative -> this is only the offline / first-launch answer.
/// Six locales ship but five cuts exist -> `hi` is deliberately absent, so a Hindi link falls back to
/// English instead of requesting a key that 404s.
const _defaultLangs = <String>['en', 'ta', 'te', 'kn', 'ml'];

/// Resolves the clip for [languageCode], or null when onboarding video is off.
///
/// `feature_flags.onboarding_video` holds the kill switch, the cache-busting version and the set of
/// languages that exist -> a re-cut or the Hindi dub is an upload plus a CMS edit, never a release ->
/// the MP4s live on the CDN and are NEVER bundled (Play cannot language-split `flutter_assets`).
/// Shown on the TRIAL variant of `/premium` only — its script says "start your 1-day trial".
OnboardingVideoSource? resolveOnboardingVideo(
  AppConfigModel? config,
  String languageCode,
) {
  final flag = config?.featureFlags['onboarding_video'];
  final map = flag is Map ? flag : const {};

  // A cold start reaches the paywall before /config lands on a slow link -> only an explicit
  // `enabled: false` gates the feature off, never an absent config.
  if (map['enabled'] == false) return null;
  if (AppConfig.cdnBaseUrl.isEmpty) return null;

  final langs = switch (map['langs']) {
    final List<dynamic> l when l.isNotEmpty => l.whereType<String>().toList(),
    _ => _defaultLangs,
  };
  // Ladder: the language the link asked for -> `en` -> null, where the caller puts the brand lockup
  // back. Never a broken box.
  final lang = langs.contains(languageCode)
      ? languageCode
      : (langs.contains('en') ? 'en' : null);
  if (lang == null) return null;

  final version = map['version'];
  // `?v=` rather than a purge — the same cache discipline the catalog uses.
  final query = version == null ? '' : '?v=$version';
  return OnboardingVideoSource(
    lang: lang,
    url: '${AppConfig.cdnBaseUrl}/onboarding/$lang.mp4$query',
  );
}
