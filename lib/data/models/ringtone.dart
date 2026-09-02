import 'package:freezed_annotation/freezed_annotation.dart';

part 'ringtone.freezed.dart';
part 'ringtone.g.dart';

/// One ringtone catalog entry, from the Worker-built `catalog/ringtones/all_{page}.json`.
///
/// `audioKey` is the PUBLIC R2 key — preview streams free, the same soft gate as wallpaper browse.
/// SETTING it as the device tone is the premium gate, live-checked by `/media/signed-url` (§5).
@freezed
abstract class Ringtone with _$Ringtone {
  const Ringtone._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Ringtone({
    required String id,
    required String title,

    /// Browse axis, same contract as [Wallpaper.category] — free text.
    /// An unknown or missing category must never crash the list -> it falls into All.
    @Default('other') String category,

    /// Which god the track is to — finer than [category], and DISPLAY ONLY: row subtitle and art.
    /// NEVER a browse axis — no chip filters on it, nothing orders by it (CLAUDE.md §5b).
    /// One category spans several gods — `perumal` holds Venkateswara, Krishna, Rama, Narasimha.
    /// So category-level art would put Lakshmi's figure on a Chamundeshwari chant.
    /// Nullable, and null is ORDINARY -> `deityAsset()` resolves to the category's art, no subtitle.
    String? deity,
    @Default(<String>[]) List<String> tags,
    required String audioKey,

    /// Optional cover art R2 key. Null -> a decorated fallback tile, never a broken image.
    String? coverKey,
    String? mime,
    @Default(0) int sortOrder,
    DateTime? createdAt,

    /// How many times a premium user SET this — tier 2 of the order, mirroring [Wallpaper.applyCount].
    /// Counted server-side in `/media/signed-url`; a ringtone has no share path, so every grant is a set.
    @Default(0) int setCount,

    /// Tier 1, ahead of [setCount] — the same semantics and null contract as [Wallpaper.feedRank].
    /// Both tabs order through the one `orderedByUse`.
    int? feedRank,
  }) = _Ringtone;

  factory Ringtone.fromJson(Map<String, dynamic> json) =>
      _$RingtoneFromJson(json);

  /// Chip/meta label, the capitalised slug — the catalog carries no display label.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  /// The row's subtitle, or null when the track carries no deity.
  ///
  /// The capitalised slug, like [categoryLabel] — every slug is one Latin word that capitalises right.
  /// NOT localized: this is server-authored content, not UI chrome (CLAUDE.md §6).
  String? get deityLabel {
    final d = deity;
    if (d == null || d.isEmpty) return null;
    return d[0].toUpperCase() + d.substring(1);
  }

  /// Public CDN URL for the preview stream.
  String audioUrl(String cdnBase) => '$cdnBase/$audioKey';

  /// Public CDN URL for the cover art, or null when there is none.
  String? coverUrl(String cdnBase) =>
      coverKey == null ? null : '$cdnBase/$coverKey';
}
