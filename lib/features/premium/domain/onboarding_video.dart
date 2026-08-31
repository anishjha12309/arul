import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../data/models/app_config_model.dart';

/// A resolved onboarding clip: which language won and where its bytes are.
@immutable
class OnboardingVideoSource {
  const OnboardingVideoSource({required this.lang, required this.url});

  /// The language actually being shown — NOT necessarily the one asked for.
  /// A link for a language with no cut yet (`hi`, until its dub lands) resolves
  /// to `en`, and analytics reports what was really played.
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
/// The remote list is authoritative; this is only the offline / first-launch
/// answer. `hi` is deliberately absent — the app ships six locales but only
/// five cuts have been produced, and a Hindi link must fall back to English
/// rather than request a key that 404s.
const _defaultLangs = <String>['en', 'ta', 'te', 'kn', 'ml'];

/// Resolves the clip for [languageCode], or null when onboarding video is off.
///
/// Reads `feature_flags.onboarding_video` so the whole feature — the kill
/// switch, the cache-busting version, and the set of languages that exist —
/// moves without an app release. Shipping the Hindi dub is then an upload plus
/// a CMS edit, which is the entire reason the MP4s are not bundled.
OnboardingVideoSource? resolveOnboardingVideo(
  AppConfigModel? config,
  String languageCode,
) {
  final flag = config?.featureFlags['onboarding_video'];
  final map = flag is Map ? flag : const {};

  // Absent config must not gate the feature off: a cold start reaches the
  // paywall before /config has landed on a slow connection, and a blank screen
  // where the brand block used to be would be worse than either outcome.
  if (map['enabled'] == false) return null;
  if (AppConfig.cdnBaseUrl.isEmpty) return null;

  final langs = switch (map['langs']) {
    final List<dynamic> l when l.isNotEmpty => l.whereType<String>().toList(),
    _ => _defaultLangs,
  };
  // The ladder: the language the link asked for, then English, then nothing at
  // all — the caller puts the brand lockup back. Never a broken box.
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
