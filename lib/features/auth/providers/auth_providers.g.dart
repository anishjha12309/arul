// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(apiClient)
final apiClientProvider = ApiClientProvider._();

final class ApiClientProvider
    extends $FunctionalProvider<ApiClient, ApiClient, ApiClient>
    with $Provider<ApiClient> {
  ApiClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'apiClientProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$apiClientHash();

  @$internal
  @override
  $ProviderElement<ApiClient> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  ApiClient create(Ref ref) {
    return apiClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ApiClient value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ApiClient>(value),
    );
  }
}

String _$apiClientHash() => r'90c807f03b90249684265cc91739139c2c89eeb9';

@ProviderFor(authService)
final authServiceProvider = AuthServiceProvider._();

final class AuthServiceProvider
    extends $FunctionalProvider<AuthService, AuthService, AuthService>
    with $Provider<AuthService> {
  AuthServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'authServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$authServiceHash();

  @$internal
  @override
  $ProviderElement<AuthService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AuthService create(Ref ref) {
    return authService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AuthService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AuthService>(value),
    );
  }
}

String _$authServiceHash() => r'130fb39ff5de01ec0c15b8f68f1e8570472ce56b';

/// Emits the latest [AuthUserState]. Starts as [AsyncLoading] until the stored-
/// token check in [ApiAuthService] fires its initial event (almost immediate).

@ProviderFor(authStateStream)
final authStateStreamProvider = AuthStateStreamProvider._();

/// Emits the latest [AuthUserState]. Starts as [AsyncLoading] until the stored-
/// token check in [ApiAuthService] fires its initial event (almost immediate).

final class AuthStateStreamProvider
    extends
        $FunctionalProvider<
          AsyncValue<AuthUserState>,
          AuthUserState,
          Stream<AuthUserState>
        >
    with $FutureModifier<AuthUserState>, $StreamProvider<AuthUserState> {
  /// Emits the latest [AuthUserState]. Starts as [AsyncLoading] until the stored-
  /// token check in [ApiAuthService] fires its initial event (almost immediate).
  AuthStateStreamProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'authStateStreamProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$authStateStreamHash();

  @$internal
  @override
  $StreamProviderElement<AuthUserState> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<AuthUserState> create(Ref ref) {
    return authStateStream(ref);
  }
}

String _$authStateStreamHash() => r'ca44de00d044b9aba236b0d9bc0ef976331e6b13';

/// Exposes sign-in / sign-out actions. Consumers read state from
/// [authStateStreamProvider] and call methods on this notifier.

@ProviderFor(AuthController)
final authControllerProvider = AuthControllerProvider._();

/// Exposes sign-in / sign-out actions. Consumers read state from
/// [authStateStreamProvider] and call methods on this notifier.
final class AuthControllerProvider
    extends $AsyncNotifierProvider<AuthController, void> {
  /// Exposes sign-in / sign-out actions. Consumers read state from
  /// [authStateStreamProvider] and call methods on this notifier.
  AuthControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'authControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$authControllerHash();

  @$internal
  @override
  AuthController create() => AuthController();
}

String _$authControllerHash() => r'9bdadd0fda1cf890ba2dde29cbf3e9ed8cf5edcb';

/// Exposes sign-in / sign-out actions. Consumers read state from
/// [authStateStreamProvider] and call methods on this notifier.

abstract class _$AuthController extends $AsyncNotifier<void> {
  FutureOr<void> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<void>, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<void>, void>,
              AsyncValue<void>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
