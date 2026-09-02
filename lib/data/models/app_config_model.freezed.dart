// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'app_config_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AppConfigModel {

 Map<String, dynamic> get prices; String? get supportEmail; Map<String, dynamic> get policyUrls; Map<String, dynamic> get featureFlags; String? get minSupportedVersion;/// Hand-set browse-chip order per scope: `{'wallpapers': [...], 'ringtones': [...]}`.
///
/// Written by the unified CMS (drag a row on its Categories page) and emitted by
/// `build-catalog` into `catalog/app_config.json`. It decides ORDER ONLY — a chip
/// still exists because a published row carries the slug, so this list can never
/// add a category the catalog lacks nor remove one it has.
///
/// **Defaults to empty, and empty means "use the built-in rule"** -> a build that
/// predates the field, a CMS nobody has dragged, and an unreachable config all land
/// on the same safe path: [compareBrowseCategories] / [compareRingtoneCategories].
 Map<String, dynamic> get categoryOrder;
/// Create a copy of AppConfigModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppConfigModelCopyWith<AppConfigModel> get copyWith => _$AppConfigModelCopyWithImpl<AppConfigModel>(this as AppConfigModel, _$identity);

  /// Serializes this AppConfigModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppConfigModel&&const DeepCollectionEquality().equals(other.prices, prices)&&(identical(other.supportEmail, supportEmail) || other.supportEmail == supportEmail)&&const DeepCollectionEquality().equals(other.policyUrls, policyUrls)&&const DeepCollectionEquality().equals(other.featureFlags, featureFlags)&&(identical(other.minSupportedVersion, minSupportedVersion) || other.minSupportedVersion == minSupportedVersion)&&const DeepCollectionEquality().equals(other.categoryOrder, categoryOrder));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(prices),supportEmail,const DeepCollectionEquality().hash(policyUrls),const DeepCollectionEquality().hash(featureFlags),minSupportedVersion,const DeepCollectionEquality().hash(categoryOrder));

@override
String toString() {
  return 'AppConfigModel(prices: $prices, supportEmail: $supportEmail, policyUrls: $policyUrls, featureFlags: $featureFlags, minSupportedVersion: $minSupportedVersion, categoryOrder: $categoryOrder)';
}


}

/// @nodoc
abstract mixin class $AppConfigModelCopyWith<$Res>  {
  factory $AppConfigModelCopyWith(AppConfigModel value, $Res Function(AppConfigModel) _then) = _$AppConfigModelCopyWithImpl;
@useResult
$Res call({
 Map<String, dynamic> prices, String? supportEmail, Map<String, dynamic> policyUrls, Map<String, dynamic> featureFlags, String? minSupportedVersion, Map<String, dynamic> categoryOrder
});




}
/// @nodoc
class _$AppConfigModelCopyWithImpl<$Res>
    implements $AppConfigModelCopyWith<$Res> {
  _$AppConfigModelCopyWithImpl(this._self, this._then);

  final AppConfigModel _self;
  final $Res Function(AppConfigModel) _then;

/// Create a copy of AppConfigModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? prices = null,Object? supportEmail = freezed,Object? policyUrls = null,Object? featureFlags = null,Object? minSupportedVersion = freezed,Object? categoryOrder = null,}) {
  return _then(_self.copyWith(
prices: null == prices ? _self.prices : prices // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,supportEmail: freezed == supportEmail ? _self.supportEmail : supportEmail // ignore: cast_nullable_to_non_nullable
as String?,policyUrls: null == policyUrls ? _self.policyUrls : policyUrls // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,featureFlags: null == featureFlags ? _self.featureFlags : featureFlags // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,minSupportedVersion: freezed == minSupportedVersion ? _self.minSupportedVersion : minSupportedVersion // ignore: cast_nullable_to_non_nullable
as String?,categoryOrder: null == categoryOrder ? _self.categoryOrder : categoryOrder // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,
  ));
}

}


/// Adds pattern-matching-related methods to [AppConfigModel].
extension AppConfigModelPatterns on AppConfigModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppConfigModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppConfigModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppConfigModel value)  $default,){
final _that = this;
switch (_that) {
case _AppConfigModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppConfigModel value)?  $default,){
final _that = this;
switch (_that) {
case _AppConfigModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( Map<String, dynamic> prices,  String? supportEmail,  Map<String, dynamic> policyUrls,  Map<String, dynamic> featureFlags,  String? minSupportedVersion,  Map<String, dynamic> categoryOrder)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppConfigModel() when $default != null:
return $default(_that.prices,_that.supportEmail,_that.policyUrls,_that.featureFlags,_that.minSupportedVersion,_that.categoryOrder);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( Map<String, dynamic> prices,  String? supportEmail,  Map<String, dynamic> policyUrls,  Map<String, dynamic> featureFlags,  String? minSupportedVersion,  Map<String, dynamic> categoryOrder)  $default,) {final _that = this;
switch (_that) {
case _AppConfigModel():
return $default(_that.prices,_that.supportEmail,_that.policyUrls,_that.featureFlags,_that.minSupportedVersion,_that.categoryOrder);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( Map<String, dynamic> prices,  String? supportEmail,  Map<String, dynamic> policyUrls,  Map<String, dynamic> featureFlags,  String? minSupportedVersion,  Map<String, dynamic> categoryOrder)?  $default,) {final _that = this;
switch (_that) {
case _AppConfigModel() when $default != null:
return $default(_that.prices,_that.supportEmail,_that.policyUrls,_that.featureFlags,_that.minSupportedVersion,_that.categoryOrder);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(fieldRename: FieldRename.snake)
class _AppConfigModel implements AppConfigModel {
  const _AppConfigModel({required final  Map<String, dynamic> prices, this.supportEmail, required final  Map<String, dynamic> policyUrls, required final  Map<String, dynamic> featureFlags, this.minSupportedVersion, final  Map<String, dynamic> categoryOrder = const <String, dynamic>{}}): _prices = prices,_policyUrls = policyUrls,_featureFlags = featureFlags,_categoryOrder = categoryOrder;
  factory _AppConfigModel.fromJson(Map<String, dynamic> json) => _$AppConfigModelFromJson(json);

 final  Map<String, dynamic> _prices;
@override Map<String, dynamic> get prices {
  if (_prices is EqualUnmodifiableMapView) return _prices;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_prices);
}

@override final  String? supportEmail;
 final  Map<String, dynamic> _policyUrls;
@override Map<String, dynamic> get policyUrls {
  if (_policyUrls is EqualUnmodifiableMapView) return _policyUrls;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_policyUrls);
}

 final  Map<String, dynamic> _featureFlags;
@override Map<String, dynamic> get featureFlags {
  if (_featureFlags is EqualUnmodifiableMapView) return _featureFlags;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_featureFlags);
}

@override final  String? minSupportedVersion;
/// Hand-set browse-chip order per scope: `{'wallpapers': [...], 'ringtones': [...]}`.
///
/// Written by the unified CMS (drag a row on its Categories page) and emitted by
/// `build-catalog` into `catalog/app_config.json`. It decides ORDER ONLY — a chip
/// still exists because a published row carries the slug, so this list can never
/// add a category the catalog lacks nor remove one it has.
///
/// **Defaults to empty, and empty means "use the built-in rule"** -> a build that
/// predates the field, a CMS nobody has dragged, and an unreachable config all land
/// on the same safe path: [compareBrowseCategories] / [compareRingtoneCategories].
 final  Map<String, dynamic> _categoryOrder;
/// Hand-set browse-chip order per scope: `{'wallpapers': [...], 'ringtones': [...]}`.
///
/// Written by the unified CMS (drag a row on its Categories page) and emitted by
/// `build-catalog` into `catalog/app_config.json`. It decides ORDER ONLY — a chip
/// still exists because a published row carries the slug, so this list can never
/// add a category the catalog lacks nor remove one it has.
///
/// **Defaults to empty, and empty means "use the built-in rule"** -> a build that
/// predates the field, a CMS nobody has dragged, and an unreachable config all land
/// on the same safe path: [compareBrowseCategories] / [compareRingtoneCategories].
@override@JsonKey() Map<String, dynamic> get categoryOrder {
  if (_categoryOrder is EqualUnmodifiableMapView) return _categoryOrder;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_categoryOrder);
}


/// Create a copy of AppConfigModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppConfigModelCopyWith<_AppConfigModel> get copyWith => __$AppConfigModelCopyWithImpl<_AppConfigModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AppConfigModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppConfigModel&&const DeepCollectionEquality().equals(other._prices, _prices)&&(identical(other.supportEmail, supportEmail) || other.supportEmail == supportEmail)&&const DeepCollectionEquality().equals(other._policyUrls, _policyUrls)&&const DeepCollectionEquality().equals(other._featureFlags, _featureFlags)&&(identical(other.minSupportedVersion, minSupportedVersion) || other.minSupportedVersion == minSupportedVersion)&&const DeepCollectionEquality().equals(other._categoryOrder, _categoryOrder));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_prices),supportEmail,const DeepCollectionEquality().hash(_policyUrls),const DeepCollectionEquality().hash(_featureFlags),minSupportedVersion,const DeepCollectionEquality().hash(_categoryOrder));

@override
String toString() {
  return 'AppConfigModel(prices: $prices, supportEmail: $supportEmail, policyUrls: $policyUrls, featureFlags: $featureFlags, minSupportedVersion: $minSupportedVersion, categoryOrder: $categoryOrder)';
}


}

/// @nodoc
abstract mixin class _$AppConfigModelCopyWith<$Res> implements $AppConfigModelCopyWith<$Res> {
  factory _$AppConfigModelCopyWith(_AppConfigModel value, $Res Function(_AppConfigModel) _then) = __$AppConfigModelCopyWithImpl;
@override @useResult
$Res call({
 Map<String, dynamic> prices, String? supportEmail, Map<String, dynamic> policyUrls, Map<String, dynamic> featureFlags, String? minSupportedVersion, Map<String, dynamic> categoryOrder
});




}
/// @nodoc
class __$AppConfigModelCopyWithImpl<$Res>
    implements _$AppConfigModelCopyWith<$Res> {
  __$AppConfigModelCopyWithImpl(this._self, this._then);

  final _AppConfigModel _self;
  final $Res Function(_AppConfigModel) _then;

/// Create a copy of AppConfigModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? prices = null,Object? supportEmail = freezed,Object? policyUrls = null,Object? featureFlags = null,Object? minSupportedVersion = freezed,Object? categoryOrder = null,}) {
  return _then(_AppConfigModel(
prices: null == prices ? _self._prices : prices // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,supportEmail: freezed == supportEmail ? _self.supportEmail : supportEmail // ignore: cast_nullable_to_non_nullable
as String?,policyUrls: null == policyUrls ? _self._policyUrls : policyUrls // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,featureFlags: null == featureFlags ? _self._featureFlags : featureFlags // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,minSupportedVersion: freezed == minSupportedVersion ? _self.minSupportedVersion : minSupportedVersion // ignore: cast_nullable_to_non_nullable
as String?,categoryOrder: null == categoryOrder ? _self._categoryOrder : categoryOrder // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,
  ));
}


}

// dart format on
