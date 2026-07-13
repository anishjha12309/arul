/// `static` is a Dart keyword, so the static-image case cannot be named for it.
enum WallpaperKind { image, live }

/// One feed item.
///
/// Plain immutable class, no codegen: the UI layer must build without a
/// build_runner round. Port-map Phase 4 replaces this with the freezed model
/// that parses the Worker catalog — the FIELDS are already the catalog's, so the
/// widgets above it will not change.
class Wallpaper {
  const Wallpaper({
    required this.id,
    required this.title,
    required this.category,
    required this.categoryLabel,
    required this.kind,
    required this.key,
    this.width,
    this.height,
  });

  final String id;
  final String title;

  /// Browse axis. NEVER filter the feed by [kind] — see CLAUDE.md §5b.
  final String category;
  final String categoryLabel;

  final WallpaperKind kind;

  /// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4`. Public by design
  /// (browse/preview are free); applying it is the premium gate.
  final String key;
  final int? width;
  final int? height;

  String url(String cdnBase) => '$cdnBase/$key';

  /// The 720px still used by the grid, and as the viewer's instant poster.
  ///
  /// Derived, not stored: the thumbnails are generated from the media itself and
  /// live under their OWN `thumbs/` prefix — deliberately not under `wallpapers/`,
  /// which the Worker's hourly orphan sweep owns and would delete from.
  ///
  /// A grid cannot show live items any other way: a decoder per tile is not
  /// affordable on the budget SoCs this app targets. If a thumb is missing the
  /// tile falls back (native first-frame for live, full image for static), so a
  /// newly published wallpaper is never a hole.
  String thumbUrl(String cdnBase) => '$cdnBase/thumbs/$category/$id.jpg';

  /// Parses the bucket's content-prep manifest (`catalog/catalog.json`). The
  /// Worker-built catalog uses the same field meanings under snake_case names,
  /// so Phase 4 swaps this constructor, not its callers.
  factory Wallpaper.fromManifest(Map<String, dynamic> json) {
    final delivered = json['delivered'] as Map<String, dynamic>?;
    final category = (json['category'] as String?) ?? 'other';
    return Wallpaper(
      id: json['id'] as String,
      title:
          (json['subjectName'] as String?) ??
          (json['categoryName'] as String?) ??
          category,
      category: category,
      categoryLabel: (json['categoryName'] as String?) ?? category,
      kind: json['mediaType'] == 'video'
          ? WallpaperKind.live
          : WallpaperKind.image,
      key: json['mediaKey'] as String,
      width: (delivered?['width'] as num?)?.toInt(),
      height: (delivered?['height'] as num?)?.toInt(),
    );
  }
}

/// A browse chip. `all` is chrome (localised); the rest come from the catalog.
class WallpaperCategory {
  const WallpaperCategory(this.slug, this.label);

  final String slug;
  final String label;

  static const allSlug = '__all__';
}
