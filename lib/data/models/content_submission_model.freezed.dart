// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'content_submission_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ContentSubmissionModel {

 String get id; String get userId; String get kind; String get fileKey; String? get title; String? get category; ContentSubmissionStatus get status; String? get rejectionReason; String? get reviewedBy; DateTime? get createdAt;
/// Create a copy of ContentSubmissionModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ContentSubmissionModelCopyWith<ContentSubmissionModel> get copyWith => _$ContentSubmissionModelCopyWithImpl<ContentSubmissionModel>(this as ContentSubmissionModel, _$identity);

  /// Serializes this ContentSubmissionModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSubmissionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.fileKey, fileKey) || other.fileKey == fileKey)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.status, status) || other.status == status)&&(identical(other.rejectionReason, rejectionReason) || other.rejectionReason == rejectionReason)&&(identical(other.reviewedBy, reviewedBy) || other.reviewedBy == reviewedBy)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,kind,fileKey,title,category,status,rejectionReason,reviewedBy,createdAt);

@override
String toString() {
  return 'ContentSubmissionModel(id: $id, userId: $userId, kind: $kind, fileKey: $fileKey, title: $title, category: $category, status: $status, rejectionReason: $rejectionReason, reviewedBy: $reviewedBy, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class $ContentSubmissionModelCopyWith<$Res>  {
  factory $ContentSubmissionModelCopyWith(ContentSubmissionModel value, $Res Function(ContentSubmissionModel) _then) = _$ContentSubmissionModelCopyWithImpl;
@useResult
$Res call({
 String id, String userId, String kind, String fileKey, String? title, String? category, ContentSubmissionStatus status, String? rejectionReason, String? reviewedBy, DateTime? createdAt
});




}
/// @nodoc
class _$ContentSubmissionModelCopyWithImpl<$Res>
    implements $ContentSubmissionModelCopyWith<$Res> {
  _$ContentSubmissionModelCopyWithImpl(this._self, this._then);

  final ContentSubmissionModel _self;
  final $Res Function(ContentSubmissionModel) _then;

/// Create a copy of ContentSubmissionModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? userId = null,Object? kind = null,Object? fileKey = null,Object? title = freezed,Object? category = freezed,Object? status = null,Object? rejectionReason = freezed,Object? reviewedBy = freezed,Object? createdAt = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,fileKey: null == fileKey ? _self.fileKey : fileKey // ignore: cast_nullable_to_non_nullable
as String,title: freezed == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String?,category: freezed == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String?,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ContentSubmissionStatus,rejectionReason: freezed == rejectionReason ? _self.rejectionReason : rejectionReason // ignore: cast_nullable_to_non_nullable
as String?,reviewedBy: freezed == reviewedBy ? _self.reviewedBy : reviewedBy // ignore: cast_nullable_to_non_nullable
as String?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [ContentSubmissionModel].
extension ContentSubmissionModelPatterns on ContentSubmissionModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ContentSubmissionModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ContentSubmissionModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ContentSubmissionModel value)  $default,){
final _that = this;
switch (_that) {
case _ContentSubmissionModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ContentSubmissionModel value)?  $default,){
final _that = this;
switch (_that) {
case _ContentSubmissionModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String userId,  String kind,  String fileKey,  String? title,  String? category,  ContentSubmissionStatus status,  String? rejectionReason,  String? reviewedBy,  DateTime? createdAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ContentSubmissionModel() when $default != null:
return $default(_that.id,_that.userId,_that.kind,_that.fileKey,_that.title,_that.category,_that.status,_that.rejectionReason,_that.reviewedBy,_that.createdAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String userId,  String kind,  String fileKey,  String? title,  String? category,  ContentSubmissionStatus status,  String? rejectionReason,  String? reviewedBy,  DateTime? createdAt)  $default,) {final _that = this;
switch (_that) {
case _ContentSubmissionModel():
return $default(_that.id,_that.userId,_that.kind,_that.fileKey,_that.title,_that.category,_that.status,_that.rejectionReason,_that.reviewedBy,_that.createdAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String userId,  String kind,  String fileKey,  String? title,  String? category,  ContentSubmissionStatus status,  String? rejectionReason,  String? reviewedBy,  DateTime? createdAt)?  $default,) {final _that = this;
switch (_that) {
case _ContentSubmissionModel() when $default != null:
return $default(_that.id,_that.userId,_that.kind,_that.fileKey,_that.title,_that.category,_that.status,_that.rejectionReason,_that.reviewedBy,_that.createdAt);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _ContentSubmissionModel implements ContentSubmissionModel {
  const _ContentSubmissionModel({required this.id, required this.userId, required this.kind, required this.fileKey, this.title, this.category, required this.status, this.rejectionReason, this.reviewedBy, this.createdAt});
  factory _ContentSubmissionModel.fromJson(Map<String, dynamic> json) => _$ContentSubmissionModelFromJson(json);

@override final  String id;
@override final  String userId;
@override final  String kind;
@override final  String fileKey;
@override final  String? title;
@override final  String? category;
@override final  ContentSubmissionStatus status;
@override final  String? rejectionReason;
@override final  String? reviewedBy;
@override final  DateTime? createdAt;

/// Create a copy of ContentSubmissionModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ContentSubmissionModelCopyWith<_ContentSubmissionModel> get copyWith => __$ContentSubmissionModelCopyWithImpl<_ContentSubmissionModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ContentSubmissionModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ContentSubmissionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.fileKey, fileKey) || other.fileKey == fileKey)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.status, status) || other.status == status)&&(identical(other.rejectionReason, rejectionReason) || other.rejectionReason == rejectionReason)&&(identical(other.reviewedBy, reviewedBy) || other.reviewedBy == reviewedBy)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,kind,fileKey,title,category,status,rejectionReason,reviewedBy,createdAt);

@override
String toString() {
  return 'ContentSubmissionModel(id: $id, userId: $userId, kind: $kind, fileKey: $fileKey, title: $title, category: $category, status: $status, rejectionReason: $rejectionReason, reviewedBy: $reviewedBy, createdAt: $createdAt)';
}


}

/// @nodoc
abstract mixin class _$ContentSubmissionModelCopyWith<$Res> implements $ContentSubmissionModelCopyWith<$Res> {
  factory _$ContentSubmissionModelCopyWith(_ContentSubmissionModel value, $Res Function(_ContentSubmissionModel) _then) = __$ContentSubmissionModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String userId, String kind, String fileKey, String? title, String? category, ContentSubmissionStatus status, String? rejectionReason, String? reviewedBy, DateTime? createdAt
});




}
/// @nodoc
class __$ContentSubmissionModelCopyWithImpl<$Res>
    implements _$ContentSubmissionModelCopyWith<$Res> {
  __$ContentSubmissionModelCopyWithImpl(this._self, this._then);

  final _ContentSubmissionModel _self;
  final $Res Function(_ContentSubmissionModel) _then;

/// Create a copy of ContentSubmissionModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? userId = null,Object? kind = null,Object? fileKey = null,Object? title = freezed,Object? category = freezed,Object? status = null,Object? rejectionReason = freezed,Object? reviewedBy = freezed,Object? createdAt = freezed,}) {
  return _then(_ContentSubmissionModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,fileKey: null == fileKey ? _self.fileKey : fileKey // ignore: cast_nullable_to_non_nullable
as String,title: freezed == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String?,category: freezed == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as String?,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ContentSubmissionStatus,rejectionReason: freezed == rejectionReason ? _self.rejectionReason : rejectionReason // ignore: cast_nullable_to_non_nullable
as String?,reviewedBy: freezed == reviewedBy ? _self.reviewedBy : reviewedBy // ignore: cast_nullable_to_non_nullable
as String?,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
