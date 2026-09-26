// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The [NotificationService], overridden in `main()` with the instance initialised there.
///
/// Created before `runApp` -> a notification tap that LAUNCHED the app has a live handler on replay.

@ProviderFor(notificationService)
final notificationServiceProvider = NotificationServiceProvider._();

/// The [NotificationService], overridden in `main()` with the instance initialised there.
///
/// Created before `runApp` -> a notification tap that LAUNCHED the app has a live handler on replay.

final class NotificationServiceProvider
    extends
        $FunctionalProvider<
          NotificationService,
          NotificationService,
          NotificationService
        >
    with $Provider<NotificationService> {
  /// The [NotificationService], overridden in `main()` with the instance initialised there.
  ///
  /// Created before `runApp` -> a notification tap that LAUNCHED the app has a live handler on replay.
  NotificationServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'notificationServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$notificationServiceHash();

  @$internal
  @override
  $ProviderElement<NotificationService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  NotificationService create(Ref ref) {
    return notificationService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NotificationService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NotificationService>(value),
    );
  }
}

String _$notificationServiceHash() =>
    r'87ba170a1c4adc9f37de5e37dc0e13f817a0ca30';

/// Re-arms the unfinished-trial reminder once per launch, watched from the ROOT widget.
///
/// Re-armed at its PERSISTED instant, never a fresh six hours: recomputing from now would push the
/// reminder further out on every launch, so the people who open the app most would never see it.
/// Its only gate is the OS permission — `scheduleTrialReminder` refuses without it, and NOTHING here
/// ever asks for it.

@ProviderFor(notificationBootstrap)
final notificationBootstrapProvider = NotificationBootstrapProvider._();

/// Re-arms the unfinished-trial reminder once per launch, watched from the ROOT widget.
///
/// Re-armed at its PERSISTED instant, never a fresh six hours: recomputing from now would push the
/// reminder further out on every launch, so the people who open the app most would never see it.
/// Its only gate is the OS permission — `scheduleTrialReminder` refuses without it, and NOTHING here
/// ever asks for it.

final class NotificationBootstrapProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Re-arms the unfinished-trial reminder once per launch, watched from the ROOT widget.
  ///
  /// Re-armed at its PERSISTED instant, never a fresh six hours: recomputing from now would push the
  /// reminder further out on every launch, so the people who open the app most would never see it.
  /// Its only gate is the OS permission — `scheduleTrialReminder` refuses without it, and NOTHING here
  /// ever asks for it.
  NotificationBootstrapProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'notificationBootstrapProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$notificationBootstrapHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return notificationBootstrap(ref);
  }
}

String _$notificationBootstrapHash() =>
    r'b49df922b52c34bc8fe6413d753e26be7886e6ce';
