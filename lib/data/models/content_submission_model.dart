import 'package:freezed_annotation/freezed_annotation.dart';

part 'content_submission_model.freezed.dart';
part 'content_submission_model.g.dart';

enum ContentSubmissionStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('approved')
  approved,
  @JsonValue('rejected')
  rejected,
}

/// A user content submission awaiting moderation (Neon `content_submissions`).
@freezed
abstract class ContentSubmissionModel with _$ContentSubmissionModel {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ContentSubmissionModel({
    required String id,
    required String userId,
    required String kind,
    required String fileKey,
    String? title,
    String? category,
    required ContentSubmissionStatus status,
    String? rejectionReason,
    String? reviewedBy,
    DateTime? createdAt,
  }) = _ContentSubmissionModel;

  factory ContentSubmissionModel.fromJson(Map<String, dynamic> json) =>
      _$ContentSubmissionModelFromJson(json);
}
