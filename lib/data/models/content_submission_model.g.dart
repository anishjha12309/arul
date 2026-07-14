// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'content_submission_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ContentSubmissionModel _$ContentSubmissionModelFromJson(
  Map<String, dynamic> json,
) => _ContentSubmissionModel(
  id: json['id'] as String,
  userId: json['user_id'] as String,
  kind: json['kind'] as String,
  fileKey: json['file_key'] as String,
  title: json['title'] as String?,
  category: json['category'] as String?,
  status: $enumDecode(_$ContentSubmissionStatusEnumMap, json['status']),
  rejectionReason: json['rejection_reason'] as String?,
  reviewedBy: json['reviewed_by'] as String?,
  createdAt: json['created_at'] == null
      ? null
      : DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$ContentSubmissionModelToJson(
  _ContentSubmissionModel instance,
) => <String, dynamic>{
  'id': instance.id,
  'user_id': instance.userId,
  'kind': instance.kind,
  'file_key': instance.fileKey,
  'title': instance.title,
  'category': instance.category,
  'status': _$ContentSubmissionStatusEnumMap[instance.status]!,
  'rejection_reason': instance.rejectionReason,
  'reviewed_by': instance.reviewedBy,
  'created_at': instance.createdAt?.toIso8601String(),
};

const _$ContentSubmissionStatusEnumMap = {
  ContentSubmissionStatus.pending: 'pending',
  ContentSubmissionStatus.approved: 'approved',
  ContentSubmissionStatus.rejected: 'rejected',
};
