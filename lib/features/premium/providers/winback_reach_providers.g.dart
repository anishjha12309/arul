// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'winback_reach_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(winbackLedger)
final winbackLedgerProvider = WinbackLedgerProvider._();

final class WinbackLedgerProvider
    extends $FunctionalProvider<WinbackLedger, WinbackLedger, WinbackLedger>
    with $Provider<WinbackLedger> {
  WinbackLedgerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'winbackLedgerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$winbackLedgerHash();

  @$internal
  @override
  $ProviderElement<WinbackLedger> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  WinbackLedger create(Ref ref) {
    return winbackLedger(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WinbackLedger value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WinbackLedger>(value),
    );
  }
}

String _$winbackLedgerHash() => r'6cd95c915c9a05d1ff7c81803ab1937494811d81';

@ProviderFor(winbackReachFlags)
final winbackReachFlagsProvider = WinbackReachFlagsProvider._();

final class WinbackReachFlagsProvider
    extends
        $FunctionalProvider<
          WinbackReachFlags,
          WinbackReachFlags,
          WinbackReachFlags
        >
    with $Provider<WinbackReachFlags> {
  WinbackReachFlagsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'winbackReachFlagsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$winbackReachFlagsHash();

  @$internal
  @override
  $ProviderElement<WinbackReachFlags> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  WinbackReachFlags create(Ref ref) {
    return winbackReachFlags(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WinbackReachFlags value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WinbackReachFlags>(value),
    );
  }
}

String _$winbackReachFlagsHash() => r'32cbf18d56c71da407aff4adaece97eb1dc101d5';

@ProviderFor(uninstallShortcutChannel)
final uninstallShortcutChannelProvider = UninstallShortcutChannelProvider._();

final class UninstallShortcutChannelProvider
    extends
        $FunctionalProvider<
          UninstallShortcutChannel,
          UninstallShortcutChannel,
          UninstallShortcutChannel
        >
    with $Provider<UninstallShortcutChannel> {
  UninstallShortcutChannelProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'uninstallShortcutChannelProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$uninstallShortcutChannelHash();

  @$internal
  @override
  $ProviderElement<UninstallShortcutChannel> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  UninstallShortcutChannel create(Ref ref) {
    return uninstallShortcutChannel(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(UninstallShortcutChannel value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<UninstallShortcutChannel>(value),
    );
  }
}

String _$uninstallShortcutChannelHash() =>
    r'e2d8062794afef9fe83ce236742272ea534fe317';

/// Mirrors the "Uninstall" shortcut onto the phone: published while `/me` says premium ran out on
/// someone offered ₹99 and its switch is on, removed otherwise (sign-out included), labelled in the
/// app's language. Listened at the root; a resume re-runs it, since a restored phone loses dynamic
/// shortcuts.

@ProviderFor(uninstallShortcutSync)
final uninstallShortcutSyncProvider = UninstallShortcutSyncProvider._();

/// Mirrors the "Uninstall" shortcut onto the phone: published while `/me` says premium ran out on
/// someone offered ₹99 and its switch is on, removed otherwise (sign-out included), labelled in the
/// app's language. Listened at the root; a resume re-runs it, since a restored phone loses dynamic
/// shortcuts.

final class UninstallShortcutSyncProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Mirrors the "Uninstall" shortcut onto the phone: published while `/me` says premium ran out on
  /// someone offered ₹99 and its switch is on, removed otherwise (sign-out included), labelled in the
  /// app's language. Listened at the root; a resume re-runs it, since a restored phone loses dynamic
  /// shortcuts.
  UninstallShortcutSyncProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'uninstallShortcutSyncProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$uninstallShortcutSyncHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return uninstallShortcutSync(ref);
  }
}

String _$uninstallShortcutSyncHash() =>
    r'd1d6402394051fb02d1073c96fc400ffc0052d76';

@ProviderFor(winbackDailyController)
final winbackDailyControllerProvider = WinbackDailyControllerProvider._();

final class WinbackDailyControllerProvider
    extends
        $FunctionalProvider<
          WinbackDailyController,
          WinbackDailyController,
          WinbackDailyController
        >
    with $Provider<WinbackDailyController> {
  WinbackDailyControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'winbackDailyControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$winbackDailyControllerHash();

  @$internal
  @override
  $ProviderElement<WinbackDailyController> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  WinbackDailyController create(Ref ref) {
    return winbackDailyController(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WinbackDailyController value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WinbackDailyController>(value),
    );
  }
}

String _$winbackDailyControllerHash() =>
    r'8c0916385915046be7eb8ad5a764f0b3e71bc0af';
