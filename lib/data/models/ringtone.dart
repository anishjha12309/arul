import 'package:freezed_annotation/freezed_annotation.dart';

part 'ringtone.freezed.dart';
part 'ringtone.g.dart';

/// One ringtone catalog entry, parsed from the Worker-built catalog JSON
/// (`catalog/ringtones/all_{page}.json`, snake_case fields).
///
/// `audioKey` is the public R2 object key — streamed free for preview (soft
/// gate, same as wallpaper browse); SETTING it as the device tone is the
/// premium gate, enforced by the Worker's `/media/signed-url` live entitlement
/// check (CLAUDE.md §5).
@freezed
abstract class Ringtone with _$Ringtone {
  const Ringtone._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Ringtone({
    required String id,
    required String title,

    /// Browse axis, same contract as [Wallpaper.category] — free text; an
    /// unknown/missing category must never crash the list, it falls into All.
    @Default('other') String category,

    /// Which god the track is to, finer-grained than [category] and DISPLAY
    /// ONLY — the row's subtitle and its artwork. Never a browse axis: no chip
    /// filters on it and nothing orders by it (CLAUDE.md §5b keeps that job on
    /// `category`). It exists because one category spans several gods —
    /// `perumal` alone holds Venkateswara, Krishna, Rama and Narasimha — so
    /// category-level art would put Lakshmi's figure on a Chamundeshwari chant.
    ///
    /// Nullable, and a null is ordinary rather than exceptional: a row authored
    /// before the field existed, or in the CMS without it, resolves through
    /// `deityAsset()` to its category's art and shows no subtitle.
    String? deity,
    @Default(<String>[]) List<String> tags,
    required String audioKey,

    /// Optional cover art R2 key. Null → the screen renders a decorated
    /// fallback tile (gold ♪ on a maroon/darkSurface gradient), never a broken
    /// image.
    String? coverKey,
    String? mime,
    @Default(0) int sortOrder,
    DateTime? createdAt,

    /// How many times a premium user has SET this as their ringtone — tier 2 of
    /// the list's order, mirroring [Wallpaper.applyCount]. Counted server-side
    /// in `/media/signed-url`; a ringtone has no share path, so every grant is a
    /// set.
    @Default(0) int setCount,

    /// The admin's pin — tier 1, ahead of [setCount]. Same column, same
    /// semantics and the same null-means-unpinned contract as
    /// [Wallpaper.feedRank]; both tabs order through the one `orderedByUse`.
    int? feedRank,
  }) = _Ringtone;

  factory Ringtone.fromJson(Map<String, dynamic> json) =>
      _$RingtoneFromJson(json);

  /// Chip/meta label, derived from the slug (capitalised) — mirrors
  /// [Wallpaper.categoryLabel]; the catalog carries no display label.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  /// The row's subtitle, or null when the track carries no deity.
  ///
  /// Derived by capitalising the slug, exactly like [categoryLabel] — the
  /// catalog ships no display label, and every slug in the set is a single
  /// Latin-transliterated word that capitalises correctly. NOT localized: this
  /// is server-authored content, not UI chrome (CLAUDE.md §6), and a deity's
  /// name is a proper noun the six locales all render in their own script only
  /// if the catalog ever carries them that way.
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
