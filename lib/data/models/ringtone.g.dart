// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ringtone.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Ringtone _$RingtoneFromJson(Map<String, dynamic> json) => _Ringtone(
  id: json['id'] as String,
  title: json['title'] as String,
  category: json['category'] as String? ?? 'other',
  tags:
      (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const <String>[],
  audioKey: json['audio_key'] as String,
  coverKey: json['cover_key'] as String?,
  mime: json['mime'] as String?,
  sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
  createdAt: json['created_at'] == null
      ? null
      : DateTime.parse(json['created_at'] as String),
);

Map<String, dynamic> _$RingtoneToJson(_Ringtone instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'category': instance.category,
  'tags': instance.tags,
  'audio_key': instance.audioKey,
  'cover_key': instance.coverKey,
  'mime': instance.mime,
  'sort_order': instance.sortOrder,
  'created_at': instance.createdAt?.toIso8601String(),
};
