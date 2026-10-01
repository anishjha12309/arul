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

 String get id; String get userId; SubscriptionStatus get status; String? get plan; String? get phonepeSubscriptionId; String? get merchantSubscriptionId;/// The SETUP order id (`DKS_…`) — what the purchase notifier sends as `trial_started`'s
/// `order_id`.
///
/// `TrialConversionCatchUp` keys on it -> a trial granted with the app closed still fires
/// `trial_started`, exactly once per order.
/// Null on Workers that predate the field -> the catch-up reads that as nothing to reconcile.
 String? get merchantOrderId; DateTime? get trialEnd; DateTime? get currentPeriodEnd; DateTime? get updatedAt;/// What the mandate charges a month, in paise. A Worker that predates the field sold ₹199 only.
 int get pricePaise;/// Whether cancelling first offers the ₹99 switch — the Worker's verdict, never re-derived here.
 bool get cancelOfferEligible;/// Whether a returning user's paid checkout first offers ₹99 — the Worker's verdict as well.
 bool get winbackOfferEligible;/// True only while a ₹99 switch off a live plan is pending (a ₹99 winback also reads 9900).
 bool get offerSwitch;
/// Create a copy of SubscriptionModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubscriptionModelCopyWith<SubscriptionModel> get copyWith => _$SubscriptionModelCopyWithImpl<SubscriptionModel>(this as SubscriptionModel, _$identity);

  /// Serializes this SubscriptionModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SubscriptionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.status, status) || other.status == status)&&(identical(other.plan, plan) || other.plan == plan)&&(identical(other.phonepeSubscriptionId, phonepeSubscriptionId) || other.phonepeSubscriptionId == phonepeSubscriptionId)&&(identical(other.merchantSubscriptionId, merchantSubscriptionId) || other.merchantSubscriptionId == merchantSubscriptionId)&&(identical(other.merchantOrderId, merchantOrderId) || other.merchantOrderId == merchantOrderId)&&(identical(other.trialEnd, trialEnd) || other.trialEnd == trialEnd)&&(identical(other.currentPeriodEnd, currentPeriodEnd) || other.currentPeriodEnd == currentPeriodEnd)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.pricePaise, pricePaise) || other.pricePaise == pricePaise)&&(identical(other.cancelOfferEligible, cancelOfferEligible) || other.cancelOfferEligible == cancelOfferEligible)&&(identical(other.winbackOfferEligible, winbackOfferEligible) || other.winbackOfferEligible == winbackOfferEligible)&&(identical(other.offerSwitch, offerSwitch) || other.offerSwitch == offerSwitch));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,status,plan,phonepeSubscriptionId,merchantSubscriptionId,merchantOrderId,trialEnd,currentPeriodEnd,updatedAt,pricePaise,cancelOfferEligible,winbackOfferEligible,offerSwitch);

@override
String toString() {
  return 'SubscriptionModel(id: $id, userId: $userId, status: $status, plan: $plan, phonepeSubscriptionId: $phonepeSubscriptionId, merchantSubscriptionId: $merchantSubscriptionId, merchantOrderId: $merchantOrderId, trialEnd: $trialEnd, currentPeriodEnd: $currentPeriodEnd, updatedAt: $updatedAt, pricePaise: $pricePaise, cancelOfferEligible: $cancelOfferEligible, winbackOfferEligible: $winbackOfferEligible, offerSwitch: $offerSwitch)';
}


}

/// @nodoc
abstract mixin class $SubscriptionModelCopyWith<$Res>  {
  factory $SubscriptionModelCopyWith(SubscriptionModel value, $Res Function(SubscriptionModel) _then) = _$SubscriptionModelCopyWithImpl;
@useResult
$Res call({
 String id, String userId, SubscriptionStatus status, String? plan, String? phonepeSubscriptionId, String? merchantSubscriptionId, String? merchantOrderId, DateTime? trialEnd, DateTime? currentPeriodEnd, DateTime? updatedAt, int pricePaise, bool cancelOfferEligible, bool winbackOfferEligible, bool offerSwitch
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
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? userId = null,Object? status = null,Object? plan = freezed,Object? phonepeSubscriptionId = freezed,Object? merchantSubscriptionId = freezed,Object? merchantOrderId = freezed,Object? trialEnd = freezed,Object? currentPeriodEnd = freezed,Object? updatedAt = freezed,Object? pricePaise = null,Object? cancelOfferEligible = null,Object? winbackOfferEligible = null,Object? offerSwitch = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SubscriptionStatus,plan: freezed == plan ? _self.plan : plan // ignore: cast_nullable_to_non_nullable
as String?,phonepeSubscriptionId: freezed == phonepeSubscriptionId ? _self.phonepeSubscriptionId : phonepeSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantSubscriptionId: freezed == merchantSubscriptionId ? _self.merchantSubscriptionId : merchantSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantOrderId: freezed == merchantOrderId ? _self.merchantOrderId : merchantOrderId // ignore: cast_nullable_to_non_nullable
as String?,trialEnd: freezed == trialEnd ? _self.trialEnd : trialEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,currentPeriodEnd: freezed == currentPeriodEnd ? _self.currentPeriodEnd : currentPeriodEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,pricePaise: null == pricePaise ? _self.pricePaise : pricePaise // ignore: cast_nullable_to_non_nullable
as int,cancelOfferEligible: null == cancelOfferEligible ? _self.cancelOfferEligible : cancelOfferEligible // ignore: cast_nullable_to_non_nullable
as bool,winbackOfferEligible: null == winbackOfferEligible ? _self.winbackOfferEligible : winbackOfferEligible // ignore: cast_nullable_to_non_nullable
as bool,offerSwitch: null == offerSwitch ? _self.offerSwitch : offerSwitch // ignore: cast_nullable_to_non_nullable
as bool,
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  String? merchantOrderId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt,  int pricePaise,  bool cancelOfferEligible,  bool winbackOfferEligible,  bool offerSwitch)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.merchantOrderId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt,_that.pricePaise,_that.cancelOfferEligible,_that.winbackOfferEligible,_that.offerSwitch);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  String? merchantOrderId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt,  int pricePaise,  bool cancelOfferEligible,  bool winbackOfferEligible,  bool offerSwitch)  $default,) {final _that = this;
switch (_that) {
case _SubscriptionModel():
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.merchantOrderId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt,_that.pricePaise,_that.cancelOfferEligible,_that.winbackOfferEligible,_that.offerSwitch);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String userId,  SubscriptionStatus status,  String? plan,  String? phonepeSubscriptionId,  String? merchantSubscriptionId,  String? merchantOrderId,  DateTime? trialEnd,  DateTime? currentPeriodEnd,  DateTime? updatedAt,  int pricePaise,  bool cancelOfferEligible,  bool winbackOfferEligible,  bool offerSwitch)?  $default,) {final _that = this;
switch (_that) {
case _SubscriptionModel() when $default != null:
return $default(_that.id,_that.userId,_that.status,_that.plan,_that.phonepeSubscriptionId,_that.merchantSubscriptionId,_that.merchantOrderId,_that.trialEnd,_that.currentPeriodEnd,_that.updatedAt,_that.pricePaise,_that.cancelOfferEligible,_that.winbackOfferEligible,_that.offerSwitch);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _SubscriptionModel implements SubscriptionModel {
  const _SubscriptionModel({required this.id, required this.userId, required this.status, this.plan, this.phonepeSubscriptionId, this.merchantSubscriptionId, this.merchantOrderId, this.trialEnd, this.currentPeriodEnd, this.updatedAt, this.pricePaise = 19900, this.cancelOfferEligible = false, this.winbackOfferEligible = false, this.offerSwitch = false});
  factory _SubscriptionModel.fromJson(Map<String, dynamic> json) => _$SubscriptionModelFromJson(json);

@override final  String id;
@override final  String userId;
@override final  SubscriptionStatus status;
@override final  String? plan;
@override final  String? phonepeSubscriptionId;
@override final  String? merchantSubscriptionId;
/// The SETUP order id (`DKS_…`) — what the purchase notifier sends as `trial_started`'s
/// `order_id`.
///
/// `TrialConversionCatchUp` keys on it -> a trial granted with the app closed still fires
/// `trial_started`, exactly once per order.
/// Null on Workers that predate the field -> the catch-up reads that as nothing to reconcile.
@override final  String? merchantOrderId;
@override final  DateTime? trialEnd;
@override final  DateTime? currentPeriodEnd;
@override final  DateTime? updatedAt;
/// What the mandate charges a month, in paise. A Worker that predates the field sold ₹199 only.
@override@JsonKey() final  int pricePaise;
/// Whether cancelling first offers the ₹99 switch — the Worker's verdict, never re-derived here.
@override@JsonKey() final  bool cancelOfferEligible;
/// Whether a returning user's paid checkout first offers ₹99 — the Worker's verdict as well.
@override@JsonKey() final  bool winbackOfferEligible;
/// True only while a ₹99 switch off a live plan is pending (a ₹99 winback also reads 9900).
@override@JsonKey() final  bool offerSwitch;

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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SubscriptionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.status, status) || other.status == status)&&(identical(other.plan, plan) || other.plan == plan)&&(identical(other.phonepeSubscriptionId, phonepeSubscriptionId) || other.phonepeSubscriptionId == phonepeSubscriptionId)&&(identical(other.merchantSubscriptionId, merchantSubscriptionId) || other.merchantSubscriptionId == merchantSubscriptionId)&&(identical(other.merchantOrderId, merchantOrderId) || other.merchantOrderId == merchantOrderId)&&(identical(other.trialEnd, trialEnd) || other.trialEnd == trialEnd)&&(identical(other.currentPeriodEnd, currentPeriodEnd) || other.currentPeriodEnd == currentPeriodEnd)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.pricePaise, pricePaise) || other.pricePaise == pricePaise)&&(identical(other.cancelOfferEligible, cancelOfferEligible) || other.cancelOfferEligible == cancelOfferEligible)&&(identical(other.winbackOfferEligible, winbackOfferEligible) || other.winbackOfferEligible == winbackOfferEligible)&&(identical(other.offerSwitch, offerSwitch) || other.offerSwitch == offerSwitch));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,userId,status,plan,phonepeSubscriptionId,merchantSubscriptionId,merchantOrderId,trialEnd,currentPeriodEnd,updatedAt,pricePaise,cancelOfferEligible,winbackOfferEligible,offerSwitch);

@override
String toString() {
  return 'SubscriptionModel(id: $id, userId: $userId, status: $status, plan: $plan, phonepeSubscriptionId: $phonepeSubscriptionId, merchantSubscriptionId: $merchantSubscriptionId, merchantOrderId: $merchantOrderId, trialEnd: $trialEnd, currentPeriodEnd: $currentPeriodEnd, updatedAt: $updatedAt, pricePaise: $pricePaise, cancelOfferEligible: $cancelOfferEligible, winbackOfferEligible: $winbackOfferEligible, offerSwitch: $offerSwitch)';
}


}

/// @nodoc
abstract mixin class _$SubscriptionModelCopyWith<$Res> implements $SubscriptionModelCopyWith<$Res> {
  factory _$SubscriptionModelCopyWith(_SubscriptionModel value, $Res Function(_SubscriptionModel) _then) = __$SubscriptionModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String userId, SubscriptionStatus status, String? plan, String? phonepeSubscriptionId, String? merchantSubscriptionId, String? merchantOrderId, DateTime? trialEnd, DateTime? currentPeriodEnd, DateTime? updatedAt, int pricePaise, bool cancelOfferEligible, bool winbackOfferEligible, bool offerSwitch
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
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? userId = null,Object? status = null,Object? plan = freezed,Object? phonepeSubscriptionId = freezed,Object? merchantSubscriptionId = freezed,Object? merchantOrderId = freezed,Object? trialEnd = freezed,Object? currentPeriodEnd = freezed,Object? updatedAt = freezed,Object? pricePaise = null,Object? cancelOfferEligible = null,Object? winbackOfferEligible = null,Object? offerSwitch = null,}) {
  return _then(_SubscriptionModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SubscriptionStatus,plan: freezed == plan ? _self.plan : plan // ignore: cast_nullable_to_non_nullable
as String?,phonepeSubscriptionId: freezed == phonepeSubscriptionId ? _self.phonepeSubscriptionId : phonepeSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantSubscriptionId: freezed == merchantSubscriptionId ? _self.merchantSubscriptionId : merchantSubscriptionId // ignore: cast_nullable_to_non_nullable
as String?,merchantOrderId: freezed == merchantOrderId ? _self.merchantOrderId : merchantOrderId // ignore: cast_nullable_to_non_nullable
as String?,trialEnd: freezed == trialEnd ? _self.trialEnd : trialEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,currentPeriodEnd: freezed == currentPeriodEnd ? _self.currentPeriodEnd : currentPeriodEnd // ignore: cast_nullable_to_non_nullable
as DateTime?,updatedAt: freezed == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,pricePaise: null == pricePaise ? _self.pricePaise : pricePaise // ignore: cast_nullable_to_non_nullable
as int,cancelOfferEligible: null == cancelOfferEligible ? _self.cancelOfferEligible : cancelOfferEligible // ignore: cast_nullable_to_non_nullable
as bool,winbackOfferEligible: null == winbackOfferEligible ? _self.winbackOfferEligible : winbackOfferEligible // ignore: cast_nullable_to_non_nullable
as bool,offerSwitch: null == offerSwitch ? _self.offerSwitch : offerSwitch // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
