import '../providers/locale_provider.dart' show supportedAppLocales;
import 'deep_link_target.dart';

/// Host of the verified Android App Link.
///
/// MUST stay identical to three other places or deep links silently fall back to
/// opening a browser, with nothing logged anywhere:
///   · the `<data android:host>` of the App Links intent-filter in AndroidManifest.xml
///   · the `[[routes]]` custom domain in workers/wrangler.toml
///   · the host serving /.well-known/assetlinks.json (the same Worker)
const String kDeepLinkHost = 'arul.hsrutility.com';

/// Host of Meta's custom-scheme deep link: `fb<APP_ID>://open?…`. The scheme's
/// app id is baked into the manifest from `META_APP_ID`; Android only delivers
/// intents whose scheme matches, so Dart checks the shape, not the number.
const String kMetaLinkHost = 'open';

/// The two URL shapes the ad team pastes, and what every delivery path resolves
/// to (docs/deep-links.md):
///
/// ```text
/// https://arul.hsrutility.com/w/<uuid>?lang=hi                 wallpaper
/// https://arul.hsrutility.com/r/<uuid>?lang=ta                 ringtone
/// fb<APP_ID>://open?wallpaper_id=<uuid>&lang=hi                 wallpaper (Meta)
/// fb<APP_ID>://open?screen=ringtones&ringtone_id=<uuid>&lang=hi ringtone (Meta)
/// ```
///
/// The query keys are accepted on BOTH hosts and the path form on ours, so a
/// creative built in either style resolves; the Play referrer payload the
/// Worker writes (`ref=…&w=<uuid>&lang=hi` / `r=<uuid>`) reads the same keys
/// through [parseReferrerPayload].
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

/// Lower-cases and validates a wallpaper/ringtone id. Every id that reaches
/// the app from outside is validated as a UUID before it is allowed to select
/// a row: a bare-value referrer (utm campaigns, Play's own test payloads) must
/// resolve to null, not to a lookup that will never match.
String? normalizeUuid(String? raw) {
  if (raw == null) return null;
  final v = raw.trim().toLowerCase();
  return _uuid.hasMatch(v) ? v : null;
}

/// Reduces a `lang` value to one of the six shipped codes, or null.
///
/// Tolerates region tags and case (`hi-IN`, `TA`) because ad ops paste these
/// by hand; anything outside the shipped set is dropped rather than guessed —
/// an unknown code must never leave the app in a locale it has no strings for.
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

/// Parse a URI handed to the app — an App Link, Meta's scheme, or a deferred
/// link fetched by GA4F / the Meta SDK. Returns null for a URI that is not
/// ours, or that names nothing we can act on.
DeepLinkRequest? parseDeepLinkUri(Uri uri, {required DeepLinkSource source}) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final ours = scheme == 'https' && host == kDeepLinkHost;
  final meta =
      _metaScheme.hasMatch(scheme) && (host == kMetaLinkHost || host.isEmpty);
  if (!ours && !meta) return null;

  DeepLinkTarget? target;
  if (ours) {
    // Empty segments dropped so this accepts exactly what android.net.Uri's
    // getPathSegments() does — it skips them, so a campaign App URL with a
    // trailing slash passes the native check and must not be thrown away here.
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

/// Parse the Play Install Referrer payload the Worker's `/w/:id` and `/r/:id`
/// redirects hand Play (`ref=<code>&w=<uuid>&lang=hi`), which Android replays
/// to the app on the first launch after the install.
///
/// Independent of the referral code on purpose: an ad click carries `w=` with
/// no `ref=`, and a plain Refer & Earn share carries `ref=` with no target.
/// Either half missing must not discard the other.
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

/// `wallpaper_id`/`w` beats `ringtone_id`/`r` beats a bare `screen=`: an id
/// implies its tab, so a creative that says `screen=ringtones&ringtone_id=…`
/// resolves to the ringtone and the tab comes with it.
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
