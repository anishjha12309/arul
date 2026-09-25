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

    /// Debut date — the same contract and the same null case as [Wallpaper.publishedAt].
    /// NOT [createdAt], which is import time; the two differ by however long a batch sat unpublished.
    DateTime? publishedAt,

    /// Last CMS Renew — tier 1 of New, the same contract and null case as [Wallpaper.renewedAt].
    DateTime? renewedAt,
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

  String audioUrl(String cdnBase) => '$cdnBase/$audioKey';

  String? coverUrl(String cdnBase) =>
      coverKey == null ? null : '$cdnBase/$coverKey';
}
