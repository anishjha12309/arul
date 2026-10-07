// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quick_bar_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(quickBarChannel)
final quickBarChannelProvider = QuickBarChannelProvider._();

final class QuickBarChannelProvider
    extends
        $FunctionalProvider<QuickBarChannel, QuickBarChannel, QuickBarChannel>
    with $Provider<QuickBarChannel> {
  QuickBarChannelProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'quickBarChannelProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$quickBarChannelHash();

  @$internal
  @override
  $ProviderElement<QuickBarChannel> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  QuickBarChannel create(Ref ref) {
    return quickBarChannel(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(QuickBarChannel value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<QuickBarChannel>(value),
    );
  }
}

String _$quickBarChannelHash() => r'4d06990597316b0ed9acb64e7257511d4933c38b';

/// The person's choice: null until made. [autoEnable] makes it once, the first time notifications
/// are allowed (Noor's rule); after that only the Settings toggle changes it.

@ProviderFor(QuickBarSetting)
final quickBarSettingProvider = QuickBarSettingProvider._();

/// The person's choice: null until made. [autoEnable] makes it once, the first time notifications
/// are allowed (Noor's rule); after that only the Settings toggle changes it.
final class QuickBarSettingProvider
    extends $NotifierProvider<QuickBarSetting, bool?> {
  /// The person's choice: null until made. [autoEnable] makes it once, the first time notifications
  /// are allowed (Noor's rule); after that only the Settings toggle changes it.
  QuickBarSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'quickBarSettingProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$quickBarSettingHash();

  @$internal
  @override
  QuickBarSetting create() => QuickBarSetting();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool?>(value),
    );
  }
}

String _$quickBarSettingHash() => r'5ce18df973400033a007f728bce9d4e94bfffba0';

/// The person's choice: null until made. [autoEnable] makes it once, the first time notifications
/// are allowed (Noor's rule); after that only the Settings toggle changes it.

abstract class _$QuickBarSetting extends $Notifier<bool?> {
  bool? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool?, bool?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool?, bool?>,
              bool?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// `feature_flags.quick_bar`: only a literal `false` takes the bar down. While the config is
/// loading, or never loads, the verdict [quickBarKillSwitch] persisted from the last one stands.

@ProviderFor(quickBarAllowed)
final quickBarAllowedProvider = QuickBarAllowedProvider._();

/// `feature_flags.quick_bar`: only a literal `false` takes the bar down. While the config is
/// loading, or never loads, the verdict [quickBarKillSwitch] persisted from the last one stands.

final class QuickBarAllowedProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  /// `feature_flags.quick_bar`: only a literal `false` takes the bar down. While the config is
  /// loading, or never loads, the verdict [quickBarKillSwitch] persisted from the last one stands.
  QuickBarAllowedProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'quickBarAllowedProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$quickBarAllowedHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return quickBarAllowed(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$quickBarAllowedHash() => r'052f7d1ff46caf8e9e9b5e29dcca9cd75874b2a6';

/// Persists the kill switch from every landed config, like `experimentKillSwitch`. Listened at the
/// root, so the verdict is saved even on a launch that never opens Settings.

@ProviderFor(quickBarKillSwitch)
final quickBarKillSwitchProvider = QuickBarKillSwitchProvider._();

/// Persists the kill switch from every landed config, like `experimentKillSwitch`. Listened at the
/// root, so the verdict is saved even on a launch that never opens Settings.

final class QuickBarKillSwitchProvider
    extends $FunctionalProvider<void, void, void>
    with $Provider<void> {
  /// Persists the kill switch from every landed config, like `experimentKillSwitch`. Listened at the
  /// root, so the verdict is saved even on a launch that never opens Settings.
  QuickBarKillSwitchProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'quickBarKillSwitchProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$quickBarKillSwitchHash();

  @$internal
  @override
  $ProviderElement<void> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  void create(Ref ref) {
    return quickBarKillSwitch(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$quickBarKillSwitchHash() =>
    r'5197ec65bc7839308697ea890edb7e48fb648bd4';

/// Mirrors the bar onto the phone: the choice, the kill switch, the Status tab and the labels in
/// the app's language. Listened at the root (never watched: the resume below invalidates it, and a
/// watch would rebuild the whole app twice per resume), so it runs on every launch and whenever one
/// of those moves. A resume re-runs it, which is how a permission granted in system settings shows
/// the bar.

@ProviderFor(quickBarSync)
final quickBarSyncProvider = QuickBarSyncProvider._();

/// Mirrors the bar onto the phone: the choice, the kill switch, the Status tab and the labels in
/// the app's language. Listened at the root (never watched: the resume below invalidates it, and a
/// watch would rebuild the whole app twice per resume), so it runs on every launch and whenever one
/// of those moves. A resume re-runs it, which is how a permission granted in system settings shows
/// the bar.

final class QuickBarSyncProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Mirrors the bar onto the phone: the choice, the kill switch, the Status tab and the labels in
  /// the app's language. Listened at the root (never watched: the resume below invalidates it, and a
  /// watch would rebuild the whole app twice per resume), so it runs on every launch and whenever one
  /// of those moves. A resume re-runs it, which is how a permission granted in system settings shows
  /// the bar.
  QuickBarSyncProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'quickBarSyncProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$quickBarSyncHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return quickBarSync(ref);
  }
}

String _$quickBarSyncHash() => r'122ea9a742f4dabd17efa74ef7fc57191ef598bf';
