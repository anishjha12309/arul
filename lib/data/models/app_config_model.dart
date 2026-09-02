import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_config_model.freezed.dart';
part 'app_config_model.g.dart';

/// Data model for the `app_config` Neon table (singleton row).
/// Distinct from `core/config/app_config.dart` which holds env-var constants.
@freezed
abstract class AppConfigModel with _$AppConfigModel {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory AppConfigModel({
    required Map<String, dynamic> prices,
    String? supportEmail,
    required Map<String, dynamic> policyUrls,
    required Map<String, dynamic> featureFlags,
    String? minSupportedVersion,

    /// Hand-set browse-chip order per scope: `{'wallpapers': [...], 'ringtones': [...]}`.
    ///
    /// Written by the unified CMS (drag a row on its Categories page) and emitted by
    /// `build-catalog` into `catalog/app_config.json`. It decides ORDER ONLY — a chip
    /// still exists because a published row carries the slug, so this list can never
    /// add a category the catalog lacks nor remove one it has.
    ///
    /// **Defaults to empty, and empty means "use the built-in rule"** -> a build that
    /// predates the field, a CMS nobody has dragged, and an unreachable config all land
    /// on the same safe path: [compareBrowseCategories] / [compareRingtoneCategories].
    @Default(<String, dynamic>{}) Map<String, dynamic> categoryOrder,
  }) = _AppConfigModel;

  factory AppConfigModel.fromJson(Map<String, dynamic> json) =>
      _$AppConfigModelFromJson(json);
}
