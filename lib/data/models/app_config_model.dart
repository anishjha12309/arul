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
  }) = _AppConfigModel;

  factory AppConfigModel.fromJson(Map<String, dynamic> json) =>
      _$AppConfigModelFromJson(json);
}
