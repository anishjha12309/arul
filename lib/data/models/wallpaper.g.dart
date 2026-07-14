// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wallpaper.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Wallpaper _$WallpaperFromJson(Map<String, dynamic> json) => _Wallpaper(
  id: json['id'] as String,
  title: json['title'] as String,
  category: json['category'] as String? ?? 'other',
  kind: $enumDecode(
    _$WallpaperKindEnumMap,
    json['type'],
    unknownValue: WallpaperKind.image,
  ),
  key: json['full_key'] as String,
  width: (json['width'] as num?)?.toInt(),
  height: (json['height'] as num?)?.toInt(),
);

Map<String, dynamic> _$WallpaperToJson(_Wallpaper instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'category': instance.category,
      'type': _$WallpaperKindEnumMap[instance.kind]!,
      'full_key': instance.key,
      'width': instance.width,
      'height': instance.height,
    };

const _$WallpaperKindEnumMap = {
  WallpaperKind.image: 'static',
  WallpaperKind.live: 'live',
};
