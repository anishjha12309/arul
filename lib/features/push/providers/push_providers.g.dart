// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'push_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The campaign-push registry writer. One per app, kept alive for the whole process.

@ProviderFor(pushRegistration)
final pushRegistrationProvider = PushRegistrationProvider._();

/// The campaign-push registry writer. One per app, kept alive for the whole process.

final class PushRegistrationProvider
    extends
        $FunctionalProvider<
          PushRegistration,
          PushRegistration,
          PushRegistration
        >
    with $Provider<PushRegistration> {
  /// The campaign-push registry writer. One per app, kept alive for the whole process.
  PushRegistrationProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pushRegistrationProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pushRegistrationHash();

  @$internal
  @override
  $ProviderElement<PushRegistration> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  PushRegistration create(Ref ref) {
    return pushRegistration(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PushRegistration value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PushRegistration>(value),
    );
  }
}

String _$pushRegistrationHash() => r'05fcc157463fa54353f50bf56b1bff3db0caf78c';

/// The one-time `POST_NOTIFICATIONS` prompt.

@ProviderFor(pushPermission)
final pushPermissionProvider = PushPermissionProvider._();

/// The one-time `POST_NOTIFICATIONS` prompt.

final class PushPermissionProvider
    extends $FunctionalProvider<PushPermission, PushPermission, PushPermission>
    with $Provider<PushPermission> {
  /// The one-time `POST_NOTIFICATIONS` prompt.
  PushPermissionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pushPermissionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pushPermissionHash();

  @$internal
  @override
  $ProviderElement<PushPermission> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  PushPermission create(Ref ref) {
    return pushPermission(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PushPermission value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PushPermission>(value),
    );
  }
}

String _$pushPermissionHash() => r'd19546f87878ae9def7d4444092d96a4b2668024';

/// Keeps the campaign channel's NAME in the user's language.
///
/// Watched at the root so it runs on the first frame of every launch and again on every language
/// change. The channel itself is created by `NotificationService.initialize()` with an English name,
/// so it exists from the very first launch whatever happens here — this only renames it.
/// `AppLocalizations.delegate.load` resolves the string without a BuildContext, which matters:
/// nothing in the notification stack may depend on one (a boot receiver drives it with no UI alive).

@ProviderFor(pushChannelName)
final pushChannelNameProvider = PushChannelNameProvider._();

/// Keeps the campaign channel's NAME in the user's language.
///
/// Watched at the root so it runs on the first frame of every launch and again on every language
/// change. The channel itself is created by `NotificationService.initialize()` with an English name,
/// so it exists from the very first launch whatever happens here — this only renames it.
/// `AppLocalizations.delegate.load` resolves the string without a BuildContext, which matters:
/// nothing in the notification stack may depend on one (a boot receiver drives it with no UI alive).

final class PushChannelNameProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Keeps the campaign channel's NAME in the user's language.
  ///
  /// Watched at the root so it runs on the first frame of every launch and again on every language
  /// change. The channel itself is created by `NotificationService.initialize()` with an English name,
  /// so it exists from the very first launch whatever happens here — this only renames it.
  /// `AppLocalizations.delegate.load` resolves the string without a BuildContext, which matters:
  /// nothing in the notification stack may depend on one (a boot receiver drives it with no UI alive).
  PushChannelNameProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pushChannelNameProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pushChannelNameHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return pushChannelName(ref);
  }
}

String _$pushChannelNameHash() => r'2831d3546f2b8770e9b452b809413d2e775bfb81';

/// Registers this phone, once per launch, and re-registers when the language or the token moves.
///
/// Deliberately NOT tied to a screen: it watches the auth stream, so it fires on a cold start that
/// already had a session AND right after a fresh sign-in, which are the two moments a row can appear
/// or change hands. Never awaited by anything on screen — a registration that fails costs this phone
/// the next campaign and nothing else.

@ProviderFor(pushBootstrap)
final pushBootstrapProvider = PushBootstrapProvider._();

/// Registers this phone, once per launch, and re-registers when the language or the token moves.
///
/// Deliberately NOT tied to a screen: it watches the auth stream, so it fires on a cold start that
/// already had a session AND right after a fresh sign-in, which are the two moments a row can appear
/// or change hands. Never awaited by anything on screen — a registration that fails costs this phone
/// the next campaign and nothing else.

final class PushBootstrapProvider extends $FunctionalProvider<void, void, void>
    with $Provider<void> {
  /// Registers this phone, once per launch, and re-registers when the language or the token moves.
  ///
  /// Deliberately NOT tied to a screen: it watches the auth stream, so it fires on a cold start that
  /// already had a session AND right after a fresh sign-in, which are the two moments a row can appear
  /// or change hands. Never awaited by anything on screen — a registration that fails costs this phone
  /// the next campaign and nothing else.
  PushBootstrapProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pushBootstrapProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pushBootstrapHash();

  @$internal
  @override
  $ProviderElement<void> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  void create(Ref ref) {
    return pushBootstrap(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$pushBootstrapHash() => r'a945cdc064f0304e85f1cfc7f1ed6a9f997f7250';
