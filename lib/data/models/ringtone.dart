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
    @Default(<String>[]) List<String> tags,
    required String audioKey,

    /// Optional cover art R2 key. Null → the screen renders a decorated
    /// fallback tile (gold ♪ on a maroon/darkSurface gradient), never a broken
    /// image.
    String? coverKey,
    String? mime,
    @Default(0) int sortOrder,
    DateTime? createdAt,
  }) = _Ringtone;

  factory Ringtone.fromJson(Map<String, dynamic> json) =>
      _$RingtoneFromJson(json);

  /// Chip/meta label, derived from the slug (capitalised) — mirrors
  /// [Wallpaper.categoryLabel]; the catalog carries no display label.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  /// Public CDN URL for the preview stream.
  String audioUrl(String cdnBase) => '$cdnBase/$audioKey';

  /// Public CDN URL for the cover art, or null when there is none.
  String? coverUrl(String cdnBase) =>
      coverKey == null ? null : '$cdnBase/$coverKey';
}
