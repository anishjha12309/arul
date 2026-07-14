// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'referral_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ReferralModel {

 String get id; String get referrerId; String get referredUserId; ReferralStatus get status; int get rewardDays; DateTime? get createdAt;/// Friend's display label from the Worker (`/me/referrals`): their name, or a
/// masked email fallback, or null. Never the raw email (privacy).
 String? get referredName;
/// Create a copy of ReferralModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ReferralModelCopyWith<ReferralModel> get copyWith => _$ReferralModelCopyWithImpl<ReferralModel>(this as ReferralModel, _$identity);

  /// Serializes this ReferralModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReferralModel&&(identical(other.id, id) || other.id == id)&&(identical(other.referrerId, referrerId) || other.referrerId == referrerId)&&(identical(other.referredUserId, referredUserId) || other.referredUserId == referredUserId)&&(identical(other.status, status) || other.status == status)&&(identical(other.rewardDays, rewardDays) || other.rewardDays == rewardDays)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.referredName, referredName) || other.referredName == referredName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,referrerId,referredUserId,status,rewardDays,createdAt,referredName);

@override
String toString() {
  return 'ReferralModel(id: $id, referrerId: $referrerId, referredUserId: $referredUserId, status: $status, rewardDays: $rewardDays, createdAt: $createdAt, referredName: $referredName)';
}


}

/// @nodoc
abstract mixin class $ReferralModelCopyWith<$Res>  {
  factory $ReferralModelCopyWith(ReferralModel value, $Res Function(ReferralModel) _then) = _$ReferralModelCopyWithImpl;
@useResult
$Res call({
 String id, String referrerId, String referredUserId, ReferralStatus status, int rewardDays, DateTime? createdAt, String? referredName
});




}
/// @nodoc
class _$ReferralModelCopyWithImpl<$Res>
    implements $ReferralModelCopyWith<$Res> {
  _$ReferralModelCopyWithImpl(this._self, this._then);

  final ReferralModel _self;
  final $Res Function(ReferralModel) _then;

/// Create a copy of ReferralModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? referrerId = null,Object? referredUserId = null,Object? status = null,Object? rewardDays = null,Object? createdAt = freezed,Object? referredName = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,referrerId: null == referrerId ? _self.referrerId : referrerId // ignore: cast_nullable_to_non_nullable
as String,referredUserId: null == referredUserId ? _self.referredUserId : referredUserId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ReferralStatus,rewardDays: null == rewardDays ? _self.rewardDays : rewardDays // ignore: cast_nullable_to_non_nullable
as int,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,referredName: freezed == referredName ? _self.referredName : referredName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ReferralModel].
extension ReferralModelPatterns on ReferralModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ReferralModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ReferralModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ReferralModel value)  $default,){
final _that = this;
switch (_that) {
case _ReferralModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ReferralModel value)?  $default,){
final _that = this;
switch (_that) {
case _ReferralModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String referrerId,  String referredUserId,  ReferralStatus status,  int rewardDays,  DateTime? createdAt,  String? referredName)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ReferralModel() when $default != null:
return $default(_that.id,_that.referrerId,_that.referredUserId,_that.status,_that.rewardDays,_that.createdAt,_that.referredName);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String referrerId,  String referredUserId,  ReferralStatus status,  int rewardDays,  DateTime? createdAt,  String? referredName)  $default,) {final _that = this;
switch (_that) {
case _ReferralModel():
return $default(_that.id,_that.referrerId,_that.referredUserId,_that.status,_that.rewardDays,_that.createdAt,_that.referredName);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String referrerId,  String referredUserId,  ReferralStatus status,  int rewardDays,  DateTime? createdAt,  String? referredName)?  $default,) {final _that = this;
switch (_that) {
case _ReferralModel() when $default != null:
return $default(_that.id,_that.referrerId,_that.referredUserId,_that.status,_that.rewardDays,_that.createdAt,_that.referredName);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _ReferralModel implements ReferralModel {
  const _ReferralModel({required this.id, required this.referrerId, required this.referredUserId, required this.status, required this.rewardDays, this.createdAt, this.referredName});
  factory _ReferralModel.fromJson(Map<String, dynamic> json) => _$ReferralModelFromJson(json);

@override final  String id;
@override final  String referrerId;
@override final  String referredUserId;
@override final  ReferralStatus status;
@override final  int rewardDays;
@override final  DateTime? createdAt;
/// Friend's display label from the Worker (`/me/referrals`): their name, or a
/// masked email fallback, or null. Never the raw email (privacy).
@override final  String? referredName;

/// Create a copy of ReferralModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ReferralModelCopyWith<_ReferralModel> get copyWith => __$ReferralModelCopyWithImpl<_ReferralModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ReferralModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ReferralModel&&(identical(other.id, id) || other.id == id)&&(identical(other.referrerId, referrerId) || other.referrerId == referrerId)&&(identical(other.referredUserId, referredUserId) || other.referredUserId == referredUserId)&&(identical(other.status, status) || other.status == status)&&(identical(other.rewardDays, rewardDays) || other.rewardDays == rewardDays)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.referredName, referredName) || other.referredName == referredName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,referrerId,referredUserId,status,rewardDays,createdAt,referredName);

@override
String toString() {
  return 'ReferralModel(id: $id, referrerId: $referrerId, referredUserId: $referredUserId, status: $status, rewardDays: $rewardDays, createdAt: $createdAt, referredName: $referredName)';
}


}

/// @nodoc
abstract mixin class _$ReferralModelCopyWith<$Res> implements $ReferralModelCopyWith<$Res> {
  factory _$ReferralModelCopyWith(_ReferralModel value, $Res Function(_ReferralModel) _then) = __$ReferralModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String referrerId, String referredUserId, ReferralStatus status, int rewardDays, DateTime? createdAt, String? referredName
});




}
/// @nodoc
class __$ReferralModelCopyWithImpl<$Res>
    implements _$ReferralModelCopyWith<$Res> {
  __$ReferralModelCopyWithImpl(this._self, this._then);

  final _ReferralModel _self;
  final $Res Function(_ReferralModel) _then;

/// Create a copy of ReferralModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? referrerId = null,Object? referredUserId = null,Object? status = null,Object? rewardDays = null,Object? createdAt = freezed,Object? referredName = freezed,}) {
  return _then(_ReferralModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,referrerId: null == referrerId ? _self.referrerId : referrerId // ignore: cast_nullable_to_non_nullable
as String,referredUserId: null == referredUserId ? _self.referredUserId : referredUserId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ReferralStatus,rewardDays: null == rewardDays ? _self.rewardDays : rewardDays // ignore: cast_nullable_to_non_nullable
as int,createdAt: freezed == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime?,referredName: freezed == referredName ? _self.referredName : referredName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
