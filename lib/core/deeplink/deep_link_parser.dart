import '../providers/locale_provider.dart' show supportedAppLocales;
import 'deep_link_target.dart';

/// Host of the verified Android App Link.
///
/// MUST stay identical to three other places, or links silently open a browser with nothing logged:
///   · the `<data android:host>` of the App Links intent-filter in AndroidManifest.xml
///   · the `[[routes]]` custom domain in workers/wrangler.toml
///   · the host serving /.well-known/assetlinks.json (the same Worker)
const String kDeepLinkHost = 'arul.hsrutility.com';

/// Host of Meta's custom-scheme deep link, `fb<APP_ID>://open?…`; the id is baked in from `META_APP_ID`.
/// Android only delivers intents whose scheme matches -> Dart checks the SHAPE, never the number.
const String kMetaLinkHost = 'open';

/// The two URL shapes the ad team pastes, and what every path resolves to (docs/deep-links.md):
///
/// ```text
/// https://arul.hsrutility.com/w/<uuid>?lang=hi                 wallpaper
/// https://arul.hsrutility.com/r/<uuid>?lang=ta                 ringtone
/// fb<APP_ID>://open?wallpaper_id=<uuid>&lang=hi                 wallpaper (Meta)
/// fb<APP_ID>://open?screen=ringtones&ringtone_id=<uuid>&lang=hi ringtone (Meta)
/// ```
///
/// Query keys work on BOTH hosts, the path form only on ours -> either creative style resolves.
/// The Play referrer payload the Worker writes reads the same keys, via [parseReferrerPayload].
final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final RegExp _metaScheme = RegExp(r'^fb[0-9]*$');

/// What one link asked for: a target, a language, or both.
class DeepLinkRequest {
  const DeepLinkRequest({this.target, this.lang});

  final DeepLinkTarget? target;

  /// A code from `supportedAppLocales`, or null when the link carried none.
  final String? lang;

  @override
  String toString() => 'DeepLinkRequest(target: $target, lang: $lang)';
}

/// Lower-cases and validates a wallpaper/ringtone id as a UUID before it may select a row.
/// A bare-value referrer (utm campaigns, Play's test payloads) must resolve to NULL, not a dead lookup.
String? normalizeUuid(String? raw) {
  if (raw == null) return null;
  final v = raw.trim().toLowerCase();
  return _uuid.hasMatch(v) ? v : null;
}

/// Reduces a `lang` value to one of the six shipped codes, or null.
///
/// Ad ops paste these by hand -> tolerate region tags and case (`hi-IN`, `TA`).
/// An unknown code must never leave the app in a locale it has no strings for -> drop, never guess.
String? normalizeLang(String? raw) {
  if (raw == null) return null;
  var v = raw.trim().toLowerCase();
  if (v.isEmpty) return null;
  final cut = v.indexOf(RegExp('[-_]'));
  if (cut > 0) v = v.substring(0, cut);
  for (final locale in supportedAppLocales) {
    if (locale.languageCode == v) return v;
  }
  return null;
}

/// Parse a URI handed to the app — an App Link, Meta's scheme, or a GA4F/Meta deferred link.
/// Null for a URI that is not ours, or that names nothing we can act on.
DeepLinkRequest? parseDeepLinkUri(Uri uri, {required DeepLinkSource source}) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final ours = scheme == 'https' && host == kDeepLinkHost;
  final meta =
      _metaScheme.hasMatch(scheme) && (host == kMetaLinkHost || host.isEmpty);
  if (!ours && !meta) return null;

  DeepLinkTarget? target;
  if (ours) {
    // android.net.Uri.getPathSegments() SKIPS empty segments -> a trailing-slash URL passes natively.
    // So drop them here too, or a link the native side accepted is thrown away in Dart.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length == 2) {
      final id = normalizeUuid(segments[1]);
      if (id != null) {
        target = switch (segments[0]) {
          'w' => WallpaperLinkTarget(id, source: source),
          'r' => RingtoneLinkTarget(id, source: source),
          _ => null,
        };
      }
    }
    // `/r/` names the RINGTONES tab even with no id — a tab campaign, or a `/r/<typo>` landing.
    // `/w/` deliberately does NOT match: it is the shipped LANGUAGE-ONLY shape (owner's call).
    // The feed is where the app opens anyway -> claiming the tab would yank a warm user off Ringtones.
    if (target == null && segments.isNotEmpty && segments[0] == 'r') {
      target = TabLinkTarget(ArulTab.ringtones, source: source);
    }
  }

  Map<String, String> query;
  try {
    query = uri.queryParameters;
  } on FormatException {
    query = const {};
  }
  target ??= _targetFromQuery(query, source);
  final lang = normalizeLang(query['lang']);
  if (target == null && lang == null) return null;
  return DeepLinkRequest(target: target, lang: lang);
}

/// [parseDeepLinkUri] for a raw string; null when it is not even a URI.
DeepLinkRequest? parseDeepLink(String? raw, {required DeepLinkSource source}) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  return parseDeepLinkUri(uri, source: source);
}

/// Parse the Play Install Referrer payload the Worker's `/w/:id` and `/r/:id` redirects hand Play.
/// Android replays it to the app on the first launch after the install.
///
/// An ad click carries `w=` with no `ref=`; a Refer & Earn share carries `ref=` with no target.
/// So either half missing must not discard the other -> the target is parsed independently.
DeepLinkRequest? parseReferrerPayload(
  String? raw, {
  DeepLinkSource source = DeepLinkSource.installReferrer,
}) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  Map<String, String> query;
  try {
    query = Uri.splitQueryString(s);
  } catch (_) {
    return null;
  }
  final target = _targetFromQuery(query, source);
  final lang = normalizeLang(query['lang']);
  if (target == null && lang == null) return null;
  return DeepLinkRequest(target: target, lang: lang);
}

/// An id implies its tab -> `wallpaper_id`/`w` beats `ringtone_id`/`r` beats a bare `screen=`.
/// So `screen=ringtones&ringtone_id=…` resolves to the ringtone, and the tab comes with it.
DeepLinkTarget? _targetFromQuery(
  Map<String, String> query,
  DeepLinkSource source,
) {
  final wallpaper = normalizeUuid(query['wallpaper_id'] ?? query['w']);
  if (wallpaper != null) return WallpaperLinkTarget(wallpaper, source: source);
  final ringtone = normalizeUuid(query['ringtone_id'] ?? query['r']);
  if (ringtone != null) return RingtoneLinkTarget(ringtone, source: source);
  return switch (query['screen']?.trim().toLowerCase()) {
    'wallpaper' ||
    'wallpapers' => TabLinkTarget(ArulTab.wallpapers, source: source),
    'ringtone' ||
    'ringtones' => TabLinkTarget(ArulTab.ringtones, source: source),
    _ => null,
  };
}
