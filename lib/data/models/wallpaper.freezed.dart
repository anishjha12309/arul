// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'wallpaper.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Wallpaper {

 String get id; String get title;/// Browse axis (amman·ayyappan·murugan·perumal·sivan·temples — free text;
/// a 7th is a server-side insert). An unknown/missing category must never
/// crash the feed — it falls into All (docs/edge-cases.md).
 String get category;@JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image) WallpaperKind get kind;/// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4`. Public by design
/// (browse/preview are free); applying it is the premium gate.
@JsonKey(name: 'full_key') String get key; int? get width; int? get height;
/// Create a copy of Wallpaper
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WallpaperCopyWith<Wallpaper> get copyWith => _$WallpaperCopyWithImpl<Wallpaper>(this as Wallpaper, _$identity);

  /// Serializes this Wallpaper to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Wallpaper&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.key, key) || other.key == key)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,category,kind,key,width,height);

@override
String toString() {
  return 'Wallpaper(id: $id, title: $title, category: $category, kind: $kind, key: $key, width: $width, height: $height)';
}


}

/// @nodoc
abstract mixin class $WallpaperCopyWith<$Res>  {
  factory $WallpaperCopyWith(Wallpaper value, $Res Function(Wallpaper) _then) = _$WallpaperCopyWithImpl;
@useResult
$Res call({
 String id, String title, String category,@JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image) WallpaperKind kind,@JsonKey(name: 'full_key') String key, int? width, int? height
});




}
/// @nodoc
class _$WallpaperCopyWithImpl<$Res>
    implements $WallpaperCopyWith<$Res> {
  _$WallpaperCopyWithImpl(this._self, this._then);

  final Wallpaper _self;
  final $Res Function(Wallpaper) _then;

/// Create a copy of Wallpaper
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? category = null,Object? kind = null,Object? key = null,Object? width = freezed,Object? height = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as WallpaperKind,key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,width: freezed == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int?,height: freezed == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}

}


/// Adds pattern-matching-related methods to [Wallpaper].
extension WallpaperPatterns on Wallpaper {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Wallpaper value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Wallpaper() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Wallpaper value)  $default,){
final _that = this;
switch (_that) {
case _Wallpaper():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Wallpaper value)?  $default,){
final _that = this;
switch (_that) {
case _Wallpaper() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  String category, @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)  WallpaperKind kind, @JsonKey(name: 'full_key')  String key,  int? width,  int? height)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Wallpaper() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.kind,_that.key,_that.width,_that.height);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  String category, @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)  WallpaperKind kind, @JsonKey(name: 'full_key')  String key,  int? width,  int? height)  $default,) {final _that = this;
switch (_that) {
case _Wallpaper():
return $default(_that.id,_that.title,_that.category,_that.kind,_that.key,_that.width,_that.height);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  String category, @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)  WallpaperKind kind, @JsonKey(name: 'full_key')  String key,  int? width,  int? height)?  $default,) {final _that = this;
switch (_that) {
case _Wallpaper() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.kind,_that.key,_that.width,_that.height);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _Wallpaper extends Wallpaper {
  const _Wallpaper({required this.id, required this.title, this.category = 'other', @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image) required this.kind, @JsonKey(name: 'full_key') required this.key, this.width, this.height}): super._();
  factory _Wallpaper.fromJson(Map<String, dynamic> json) => _$WallpaperFromJson(json);

@override final  String id;
@override final  String title;
/// Browse axis (amman·ayyappan·murugan·perumal·sivan·temples — free text;
/// a 7th is a server-side insert). An unknown/missing category must never
/// crash the feed — it falls into All (docs/edge-cases.md).
@override@JsonKey() final  String category;
@override@JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image) final  WallpaperKind kind;
/// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4`. Public by design
/// (browse/preview are free); applying it is the premium gate.
@override@JsonKey(name: 'full_key') final  String key;
@override final  int? width;
@override final  int? height;

/// Create a copy of Wallpaper
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WallpaperCopyWith<_Wallpaper> get copyWith => __$WallpaperCopyWithImpl<_Wallpaper>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WallpaperToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Wallpaper&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.key, key) || other.key == key)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,category,kind,key,width,height);

@override
String toString() {
  return 'Wallpaper(id: $id, title: $title, category: $category, kind: $kind, key: $key, width: $width, height: $height)';
}


}

/// @nodoc
abstract mixin class _$WallpaperCopyWith<$Res> implements $WallpaperCopyWith<$Res> {
  factory _$WallpaperCopyWith(_Wallpaper value, $Res Function(_Wallpaper) _then) = __$WallpaperCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, String category,@JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image) WallpaperKind kind,@JsonKey(name: 'full_key') String key, int? width, int? height
});




}
/// @nodoc
class __$WallpaperCopyWithImpl<$Res>
    implements _$WallpaperCopyWith<$Res> {
  __$WallpaperCopyWithImpl(this._self, this._then);

  final _Wallpaper _self;
  final $Res Function(_Wallpaper) _then;

/// Create a copy of Wallpaper
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? category = null,Object? kind = null,Object? key = null,Object? width = freezed,Object? height = freezed,}) {
  return _then(_Wallpaper(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as WallpaperKind,key: null == key ? _self.key : key // ignore: cast_nullable_to_non_nullable
as String,width: freezed == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int?,height: freezed == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int?,
  ));
}


}

// dart format on
