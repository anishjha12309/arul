import 'package:freezed_annotation/freezed_annotation.dart';

part 'wallpaper.freezed.dart';
part 'wallpaper.g.dart';

/// DB column `type`: 'static' or 'live'.
/// `static` is a Dart keyword -> the image case is named `image` and mapped via @JsonValue.
/// A RENDERING hint only — never a browse or filter axis (CLAUDE.md §5b).
enum WallpaperKind {
  @JsonValue('static')
  image,
  @JsonValue('live')
  live,
}

/// One feed item, from the Worker-built `catalog/wallpapers/all_{page}.json` (snake_case fields).
///
/// The field surface is what the finished widgets consume — keep it stable.
@freezed
abstract class Wallpaper with _$Wallpaper {
  const Wallpaper._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Wallpaper({
    required String id,
    required String title,

    /// Browse axis — amman·ayyappan·murugan·perumal·sivan·temples; free text, a 7th is an insert.
    /// An unknown or missing category must never crash the feed -> it falls into All.
    @Default('other') String category,

    @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)
    required WallpaperKind kind,

    /// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4` — PUBLIC by design; browse is free.
    /// Applying it is the premium gate.
    @JsonKey(name: 'full_key') required String key,
    int? width,
    int? height,

    /// How many times a premium user APPLIED this — what orders the All chip (`feedOrder()`).
    ///
    /// Counted server-side in `/media/signed-url`, NEVER analytics — PostHog is sampled, GA4 polled.
    /// That route sees 100% of real applies. Shares do not count.
    /// Absent from an older cached catalog it parses as 0 -> that feed degrades to newest-first.
    @Default(0) int applyCount,

    /// Tier 1 of [feedOrder], ahead of [applyCount]. Ascending — the smallest rank leads the feed.
    ///
    /// build-catalog numbers EVERY row from its ORDER BY -> a current catalog page is never null here.
    /// Not a pin and not authored anywhere -> it is a position, so never write or sort it server-side.
    /// An older cached catalog built before this field parses as null -> that feed falls back to popularity.
    int? feedRank,
  }) = _Wallpaper;

  factory Wallpaper.fromJson(Map<String, dynamic> json) =>
      _$WallpaperFromJson(json);

  /// Chip/meta label, the capitalised slug — the catalog carries no display label.
  /// Categories are single ASCII words by convention.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  String url(String cdnBase) => '$cdnBase/$key';

  /// The 720px still used by the grid, and as the viewer's instant poster.
  ///
  /// Thumbnails live under their OWN `thumbs/` prefix, deliberately not the sweep's `wallpapers/`.
  /// At `thumbs/<category>/<stem>.jpg`, where the stem is [key]'s basename without its extension.
  /// The catalog `id` is a DB UUID with NO relation to the thumb name -> derive from the KEY, not id.
  String thumbUrl(String cdnBase) {
    final name = key.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot == -1 ? name : name.substring(0, dot);
    return '$cdnBase/thumbs/$category/$stem.jpg';
  }

  /// The image every surface should ASK FOR first — tile, viewer poster, splash warm.
  ///
  /// **Only LIVE items have a `thumbs/` object** — the import writes `thumb_key` for video only.
  /// A static asking for [thumbUrl] spends a guaranteed 404 before falling back to the same JPG.
  /// So a static goes STRAIGHT to [url] -> no extra bytes, one less request per static card.
  /// Tile and viewer poster share a decode width -> keep every caller here, or the item decodes twice.
  /// Live is untouched — the poster-under-texture contract depends on it.
  String posterUrl(String cdnBase) =>
      kind == WallpaperKind.live ? thumbUrl(cdnBase) : url(cdnBase);
}

/// A browse chip. `all` is chrome (localised); the rest come from the catalog.
class WallpaperCategory {
  const WallpaperCategory(this.slug, this.label);

  final String slug;
  final String label;

  static const allSlug = '__all__';
}

/// Slug the browse rows pin to the FIRST chip after All, in BOTH tabs (owner's instruction).
/// Chip-row order ONLY — it never touches `feed_rank` or the order of items inside a chip.
const String sivanCategorySlug = 'sivan';

/// Chip order for a browse row: [sivanCategorySlug] first, then alphabetical by label.
/// The ringtone row layers `others`-last on top — see `compareRingtoneCategories`.
/// Both rows are the ONE browse axis (CLAUDE.md §5b) and must not drift into two orders.
/// This is the FALLBACK now: an operator order out of the CMS wins -> [orderedByCms].
int compareBrowseCategories(WallpaperCategory a, WallpaperCategory b) {
  final aSivan = a.slug == sivanCategorySlug;
  final bSivan = b.slug == sivanCategorySlug;
  if (aSivan != bSivan) return aSivan ? -1 : 1;
  return a.label.compareTo(b.label);
}

/// Apply the operator's hand-set chip order from `app_config.category_order`.
///
/// [order] is a list of slugs for ONE scope, straight off the catalog. It is the whole
/// decision where it applies: a listed slug sits exactly where the operator dropped it,
/// which is why dragging `others` off the end of the ringtone row moves it (owner's call)
/// rather than being quietly overridden by [compareRingtoneCategories].
///
/// It is deliberately NOT required to be complete. Anything unlisted keeps [fallback] and
/// sorts AFTER everything listed, so a category published after the last drag still shows
/// up — in its built-in slot — instead of vanishing or landing at a random index.
/// An empty [order] is the ordinary case and leaves [fallback] in sole charge.
List<WallpaperCategory> orderedByCms(
  List<WallpaperCategory> categories,
  List<String> order,
  int Function(WallpaperCategory, WallpaperCategory) fallback,
) {
  if (order.isEmpty) return categories..sort(fallback);
  final rank = <String, int>{for (var i = 0; i < order.length; i++) order[i]: i};
  return categories
    ..sort((a, b) {
      final ra = rank[a.slug];
      final rb = rank[b.slug];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return -1;
      if (rb != null) return 1;
      return fallback(a, b);
    });
}

/// One scope's slug list out of `app_config.category_order`, defensively.
///
/// The catalog is JSON off a CDN -> every level can be the wrong shape or absent, and a
/// throw here would take the whole chip row down. Anything unexpected reads as "no order".
List<String> categoryOrderFor(Map<String, dynamic>? categoryOrder, String scope) {
  final raw = categoryOrder?[scope];
  if (raw is! List) return const <String>[];
  return raw.whereType<String>().where((s) => s.isNotEmpty).toList(growable: false);
}
