// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'subscription_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SubscriptionModel {

 String get id; String get userId; SubscriptionStatus get status; String? get plan; String? get phonepeSubscriptionId; String? get merchantSubscriptionId; DateTime? get trialEnd; DateTime? get currentPeriodEnd; DateTime? get updatedAt;
/// Create a copy of SubscriptionModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubscriptionModelCopyWith<SubscriptionModel> get copyWith => _$SubscriptionModelCopyWithImpl<SubscriptionModel>(this as SubscriptionModel, _$identity);

  /// Serializes this SubscriptionModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SubscriptionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.status, status) || other.status == status)&&(identical(other.plan, plan) || other.plan == plan)&&(identical(other.phonepeSubscriptionId, phonepeSubscriptionId) || other.phonepeSubscriptionId == phonepeSubscriptionId)&&(identical(other.merchantSubscriptionId, merchantSubscriptionId) || other.merchantSubscriptionId == merchantSubscriptionId)&&(identical(other.trialEnd, trialEnd) || other.trialEnd == trialEnd)&&(identical(other.currentPeriodEnd, currentPeriodEnd) || other.currentPeriodEnd == currentPeriodEnd)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,status,plan,phonepeSubscriptionId,merchantSubscriptionId,trialEnd,currentPeriodEnd,updatedAt);

@override
String toString() {
  return 'SubscriptionModel(id: $id, userId: $userId, status: $status, plan: $plan, phonepeSubscriptionId: $phonepeSubscriptionId, merchantSubscriptionId: $merchantSubscriptionId, trialEnd: $trialEnd, currentPeriodEnd: $currentPeriodEnd, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class $SubscriptionModelCopyWith<$Res>  {
  factory $SubscriptionModelCopyWith(SubscriptionModel value, $Res Function(SubscriptionModel) _then) = _$SubscriptionModelCopyWithImpl;
@useResult
$Res call({
 String id, String userId, SubscriptionStatus status, String? plan, String? phonepeSubscriptionId, String? merchantSubscriptionId, DateTime? trialEnd, DateTime? currentPeriodEnd, DateTime? updatedAt
});




}
/// @nodoc
class _$SubscriptionModelCopyWithImpl<$Res>
    implements $SubscriptionModelCopyWith<$Res> {
  _$SubscriptionModelCopyWithImpl(this._self, this._then);

  final SubscriptionModel _self;
  final $Res Function(SubscriptionModel) _then;

/// Create a copy of SubscriptionModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? userId = null,Object? status = null,Object? plan = freezed,Object? phonepeSubscriptionId = freezed,Object? merchantSubscriptionId = freezed,Object? trialEnd = freezed,Object? currentPeriodEnd = freezed,Object? updatedAt = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SubscriptionStatus,plan: freezed == plan ? _self.plan : plan // ignore: cast_nullable_to_non_nullable
as String?,phonepeSubscriptionId: freezed == phonepeSubscriptionId ? _self.phonepeSubscriptionId : phonepeSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantSubscriptionId: freezed == merchantSubscriptionId ? _self.merchantSubscriptionId : merchantSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,trialEnd: freezed == trialEnd ? _self.trialEnd : trialEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,currentPeriodEnd: freezed == currentPeriodEnd ? _self.currentPeriodEnd : currentPeriodEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [SubscriptionModel].
extension SubscriptionModelPatterns on SubscriptionModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SubscriptionModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SubscriptionModel value)  $default,){
final _that = this;
switch (_that) {
case _SubscriptionModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SubscriptionModel value)?  $default,){
final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt)  $default,) {final _that = this;
switch (_that) {
case _SubscriptionModel():
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt)?  $default,) {final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _SubscriptionModel implements SubscriptionModel {
  const _SubscriptionModel({required this.id, required this.userId, required this.status, this.plan, this.phonepeSubscriptionId, this.merchantSubscriptionId, this.trialEnd, this.currentPeriodEnd, this.updatedAt});
  factory _SubscriptionModel.fromJson(Map<String, dynamic> json) => _$SubscriptionModelFromJson(json);

@override final  String id;
@override final  String userId;
@override final  SubscriptionStatus status;
@override final  String? plan;
@override final  String? phonepeSubscriptionId;
@override final  String? merchantSubscriptionId;
@override final  DateTime? trialEnd;
@override final  DateTime? currentPeriodEnd;
@override final  DateTime? updatedAt;

/// Create a copy of SubscriptionModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubscriptionModelCopyWith<_SubscriptionModel> get copyWith => __$SubscriptionModelCopyWithImpl<_SubscriptionModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SubscriptionModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SubscriptionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.status, status) || other.status == status)&&(identical(other.plan, plan) || other.plan == plan)&&(identical(other.phonepeSubscriptionId, phonepeSubscriptionId) || other.phonepeSubscriptionId == phonepeSubscriptionId)&&(identical(other.merchantSubscriptionId, merchantSubscriptionId) || other.merchantSubscriptionId == merchantSubscriptionId)&&(identical(other.trialEnd, trialEnd) || other.trialEnd == trialEnd)&&(identical(other.currentPeriodEnd, currentPeriodEnd) || other.currentPeriodEnd == currentPeriodEnd)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,status,plan,phonepeSubscriptionId,merchantSubscriptionId,trialEnd,currentPeriodEnd,updatedAt);

@override
String toString() {
  return 'SubscriptionModel(id: $id, userId: $userId, status: $status, plan: $plan, phonepeSubscriptionId: $phonepeSubscriptionId, merchantSubscriptionId: $merchantSubscriptionId, trialEnd: $trialEnd, currentPeriodEnd: $currentPeriodEnd, updatedAt: $updatedAt)';
}


}

/// @nodoc
abstract mixin class _$SubscriptionModelCopyWith<$Res> implements $SubscriptionModelCopyWith<$Res> {
  factory _$SubscriptionModelCopyWith(_SubscriptionModel value, $Res Function(_SubscriptionModel) _then) = __$SubscriptionModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String userId, SubscriptionStatus status, String? plan, String? phonepeSubscriptionId, String? merchantSubscriptionId, DateTime? trialEnd, DateTime? currentPeriodEnd, DateTime? updatedAt
});




}
/// @nodoc
class __$SubscriptionModelCopyWithImpl<$Res>
    implements _$SubscriptionModelCopyWith<$Res> {
  __$SubscriptionModelCopyWithImpl(this._self, this._then);

  final _SubscriptionModel _self;
  final $Res Function(_SubscriptionModel) _then;

/// Create a copy of SubscriptionModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? userId = null,Object? status = null,Object? plan = freezed,Object? phonepeSubscriptionId = freezed,Object? merchantSubscriptionId = freezed,Object? trialEnd = freezed,Object? currentPeriodEnd = freezed,Object? updatedAt = freezed,}) {
  return _then(_SubscriptionModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SubscriptionStatus,plan: freezed == plan ? _self.plan : plan // ignore: cast_nullable_to_non_nullable
as String?,phonepeSubscriptionId: freezed == phonepeSubscriptionId ? _self.phonepeSubscriptionId : phonepeSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantSubscriptionId: freezed == merchantSubscriptionId ? _self.merchantSubscriptionId : merchantSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,trialEnd: freezed == trialEnd ? _self.trialEnd : trialEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,currentPeriodEnd: freezed == currentPeriodEnd ? _self.currentPeriodEnd : currentPeriodEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
