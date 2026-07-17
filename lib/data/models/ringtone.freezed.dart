// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ringtone.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Ringtone {

 String get id; String get title;/// Browse axis, same contract as [Wallpaper.category] — free text; an
/// unknown/missing category must never crash the list, it falls into All.
 String get category; List<String> get tags; String get audioKey;/// Optional cover art R2 key. Null → the screen renders a decorated
/// fallback tile (gold ♪ on a maroon/darkSurface gradient), never a broken
/// image.
 String? get coverKey; String? get mime; int get sortOrder; DateTime? get createdAt;
/// Create a copy of Ringtone
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RingtoneCopyWith<Ringtone> get copyWith => _$RingtoneCopyWithImpl<Ringtone>(this as Ringtone, _$identity);

  /// Serializes this Ringtone to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Ringtone&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&const DeepCollectionEquality().equals(other.tags, tags)&&(identical(other.audioKey, audioKey) || other.audioKey == audioKey)&&(identical(other.coverKey, coverKey) || other.coverKey == coverKey)&&(identical(other.mime, mime) || other.mime == mime)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,category,const DeepCollectionEquality().hash(tags),audioKey,coverKey,mime,sortOrder,createdAt);

@override
String toString() {
  return 'Ringtone(id: $id, title: $title, category: $category, tags: $tags, audioKey: $audioKey, coverKey: $coverKey, mime: $mime, sortOrder: $sortOrder, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $RingtoneCopyWith<$Res>  {
  factory $RingtoneCopyWith(Ringtone value, $Res Function(Ringtone) _then) = _$RingtoneCopyWithImpl;
@useResult
$Res call({
 String id, String title, String category, List<String> tags, String audioKey, String? coverKey, String? mime, int sortOrder, DateTime? createdAt
});




}
/// @nodoc
class _$RingtoneCopyWithImpl<$Res>
    implements $RingtoneCopyWith<$Res> {
  _$RingtoneCopyWithImpl(this._self, this._then);

  final Ringtone _self;
  final $Res Function(Ringtone) _then;

/// Create a copy of Ringtone
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? category = null,Object? tags = null,Object? audioKey = null,Object? coverKey = freezed,Object? mime = freezed,Object? sortOrder = null,Object? createdAt = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String,tags: null == tags ? _self.tags : tags // ignore: cast_nullable_to_non_nullable
as List<String>,audioKey: null == audioKey ? _self.audioKey : audioKey // ignore: cast_nullable_to_non_nullable
as String,coverKey: freezed == coverKey ? _self.coverKey : coverKey // ignore: cast_nullable_to_non_nullable
as String?,mime: freezed == mime ? _self.mime : mime // ignore: cast_nullable_to_non_nullable
as String?,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [Ringtone].
extension RingtonePatterns on Ringtone {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Ringtone value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Ringtone() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Ringtone value)  $default,){
final _that = this;
switch (_that) {
case _Ringtone():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Ringtone value)?  $default,){
final _that = this;
switch (_that) {
case _Ringtone() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  String category,  List<String> tags,  String audioKey,  String? coverKey,  String? mime,  int sortOrder,  DateTime? createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Ringtone() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.tags,_that.audioKey,_that.coverKey,_that.mime,_that.sortOrder,_that.createdAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  String category,  List<String> tags,  String audioKey,  String? coverKey,  String? mime,  int sortOrder,  DateTime? createdAt)  $default,) {final _that = this;
switch (_that) {
case _Ringtone():
return $default(_that.id,_that.title,_that.category,_that.tags,_that.audioKey,_that.coverKey,_that.mime,_that.sortOrder,_that.createdAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  String category,  List<String> tags,  String audioKey,  String? coverKey,  String? mime,  int sortOrder,  DateTime? createdAt)?  $default,) {final _that = this;
switch (_that) {
case _Ringtone() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.tags,_that.audioKey,_that.coverKey,_that.mime,_that.sortOrder,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _Ringtone extends Ringtone {
  const _Ringtone({required this.id, required this.title, this.category = 'other', final  List<String> tags = const <String>[], required this.audioKey, this.coverKey, this.mime, this.sortOrder = 0, this.createdAt}): _tags = tags,super._();
  factory _Ringtone.fromJson(Map<String, dynamic> json) => _$RingtoneFromJson(json);

@override final  String id;
@override final  String title;
/// Browse axis, same contract as [Wallpaper.category] — free text; an
/// unknown/missing category must never crash the list, it falls into All.
@override@JsonKey() final  String category;
 final  List<String> _tags;
@override@JsonKey() List<String> get tags {
  if (_tags is EqualUnmodifiableListView) return _tags;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tags);
}

@override final  String audioKey;
/// Optional cover art R2 key. Null → the screen renders a decorated
/// fallback tile (gold ♪ on a maroon/darkSurface gradient), never a broken
/// image.
@override final  String? coverKey;
@override final  String? mime;
@override@JsonKey() final  int sortOrder;
@override final  DateTime? createdAt;

/// Create a copy of Ringtone
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RingtoneCopyWith<_Ringtone> get copyWith => __$RingtoneCopyWithImpl<_Ringtone>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RingtoneToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Ringtone&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&const DeepCollectionEquality().equals(other._tags, _tags)&&(identical(other.audioKey, audioKey) || other.audioKey == audioKey)&&(identical(other.coverKey, coverKey) || other.coverKey == coverKey)&&(identical(other.mime, mime) || other.mime == mime)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,category,const DeepCollectionEquality().hash(_tags),audioKey,coverKey,mime,sortOrder,createdAt);

@override
String toString() {
  return 'Ringtone(id: $id, title: $title, category: $category, tags: $tags, audioKey: $audioKey, coverKey: $coverKey, mime: $mime, sortOrder: $sortOrder, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$RingtoneCopyWith<$Res> implements $RingtoneCopyWith<$Res> {
  factory _$RingtoneCopyWith(_Ringtone value, $Res Function(_Ringtone) _then) = __$RingtoneCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, String category, List<String> tags, String audioKey, String? coverKey, String? mime, int sortOrder, DateTime? createdAt
});




}
/// @nodoc
class __$RingtoneCopyWithImpl<$Res>
    implements _$RingtoneCopyWith<$Res> {
  __$RingtoneCopyWithImpl(this._self, this._then);

  final _Ringtone _self;
  final $Res Function(_Ringtone) _then;

/// Create a copy of Ringtone
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? category = null,Object? tags = null,Object? audioKey = null,Object? coverKey = freezed,Object? mime = freezed,Object? sortOrder = null,Object? createdAt = freezed,}) {
  return _then(_Ringtone(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String,tags: null == tags ? _self._tags : tags // ignore: cast_nullable_to_non_nullable
as List<String>,audioKey: null == audioKey ? _self.audioKey : audioKey // ignore: cast_nullable_to_non_nullable
as String,coverKey: freezed == coverKey ? _self.coverKey : coverKey // ignore: cast_nullable_to_non_nullable
as String?,mime: freezed == mime ? _self.mime : mime // ignore: cast_nullable_to_non_nullable
as String?,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
