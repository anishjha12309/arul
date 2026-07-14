import 'package:freezed_annotation/freezed_annotation.dart';

part 'wallpaper.freezed.dart';
part 'wallpaper.g.dart';

/// DB column `type`: 'static' or 'live'. `static` is a Dart keyword, so the
/// static-image case is named `image` and mapped via @JsonValue. A RENDERING
/// hint only — never a browse/filter axis (CLAUDE.md §5b).
enum WallpaperKind {
  @JsonValue('static')
  image,
  @JsonValue('live')
  live,
}

/// One feed item, parsed from the Worker-built catalog JSON
/// (`catalog/wallpapers/all_{page}.json`, snake_case fields — Arul's
/// build-catalog additionally emits `category`).
///
/// The field surface (id/title/category/categoryLabel/kind/key/width/height +
/// url/thumbUrl) is what the finished widgets consume — keep it stable.
@freezed
abstract class Wallpaper with _$Wallpaper {
  const Wallpaper._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Wallpaper({
    required String id,
    required String title,

    /// Browse axis (amman·ayyappan·murugan·perumal·sivan·temples — free text;
    /// a 7th is a server-side insert). An unknown/missing category must never
    /// crash the feed — it falls into All (docs/edge-cases.md).
    @Default('other') String category,

    @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)
    required WallpaperKind kind,

    /// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4`. Public by design
    /// (browse/preview are free); applying it is the premium gate.
    @JsonKey(name: 'full_key') required String key,
    int? width,
    int? height,
  }) = _Wallpaper;

  factory Wallpaper.fromJson(Map<String, dynamic> json) =>
      _$WallpaperFromJson(json);

  /// Chip/meta label, derived from the slug (capitalised). The catalog does not
  /// carry a display label; categories are single ASCII words by convention.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  String url(String cdnBase) => '$cdnBase/$key';

  /// The 720px still used by the grid, and as the viewer's instant poster.
  ///
  /// Derived, not stored: thumbnails live under their OWN `thumbs/` prefix
  /// (deliberately not under `wallpapers/`, which the hourly orphan sweep owns)
  /// at `thumbs/<category>/<file-stem>.jpg`, where the stem is the basename of
  /// [key] without its extension. The catalog `id` is a DB UUID and has NO
  /// relation to the thumb name — always derive from the key, never from id.
  String thumbUrl(String cdnBase) {
    final name = key.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot == -1 ? name : name.substring(0, dot);
    return '$cdnBase/thumbs/$category/$stem.jpg';
  }
}

/// A browse chip. `all` is chrome (localised); the rest come from the catalog.
class WallpaperCategory {
  const WallpaperCategory(this.slug, this.label);

  final String slug;
  final String label;

  static const allSlug = '__all__';
}
