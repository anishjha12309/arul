// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The [NotificationService]. Overridden in `main()` with the instance whose
/// `initialize()` was kicked off there — the same shape as
/// `sharedPreferencesProvider`, and for the same reason: the service is created
/// before `runApp` so a notification tap that LAUNCHED the app has a live
/// handler by the time the plugin replays it.

@ProviderFor(notificationService)
final notificationServiceProvider = NotificationServiceProvider._();

/// The [NotificationService]. Overridden in `main()` with the instance whose
/// `initialize()` was kicked off there — the same shape as
/// `sharedPreferencesProvider`, and for the same reason: the service is created
/// before `runApp` so a notification tap that LAUNCHED the app has a live
/// handler by the time the plugin replays it.

final class NotificationServiceProvider
    extends
        $FunctionalProvider<
          NotificationService,
          NotificationService,
          NotificationService
        >
    with $Provider<NotificationService> {
  /// The [NotificationService]. Overridden in `main()` with the instance whose
  /// `initialize()` was kicked off there — the same shape as
  /// `sharedPreferencesProvider`, and for the same reason: the service is created
  /// before `runApp` so a notification tap that LAUNCHED the app has a live
  /// handler by the time the plugin replays it.
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

/// Persisted notification preferences (SharedPreferences-backed).

@ProviderFor(NotificationSettingsNotifier)
final notificationSettingsProvider = NotificationSettingsNotifierProvider._();

/// Persisted notification preferences (SharedPreferences-backed).
final class NotificationSettingsNotifierProvider
    extends
        $NotifierProvider<NotificationSettingsNotifier, NotificationSettings> {
  /// Persisted notification preferences (SharedPreferences-backed).
  NotificationSettingsNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'notificationSettingsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$notificationSettingsNotifierHash();

  @$internal
  @override
  NotificationSettingsNotifier create() => NotificationSettingsNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NotificationSettings value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NotificationSettings>(value),
    );
  }
}

String _$notificationSettingsNotifierHash() =>
    r'62b37dc6d0aa8d2ea9f9f72a19c9e60bc27034ca';

/// Persisted notification preferences (SharedPreferences-backed).

abstract class _$NotificationSettingsNotifier
    extends $Notifier<NotificationSettings> {
  NotificationSettings build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<NotificationSettings, NotificationSettings>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<NotificationSettings, NotificationSettings>,
              NotificationSettings,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Side-effecting bootstrap: re-arms the local schedule whenever settings
/// change, and once on startup.
///
/// Watched from the root widget so it stays alive for the app's lifetime. This
/// is the SINGLE place that drives scheduling — the notifier's mutators only
/// persist state, so there is exactly one path from "settings changed" to
/// "alarms re-armed" and no way for the two to drift.
///
/// The startup run is not optional: the festival reminders are one-shot alarms,
/// so re-arming on launch is what carries the schedule past each festival and
/// into the next.

@ProviderFor(notificationBootstrap)
final notificationBootstrapProvider = NotificationBootstrapProvider._();

/// Side-effecting bootstrap: re-arms the local schedule whenever settings
/// change, and once on startup.
///
/// Watched from the root widget so it stays alive for the app's lifetime. This
/// is the SINGLE place that drives scheduling — the notifier's mutators only
/// persist state, so there is exactly one path from "settings changed" to
/// "alarms re-armed" and no way for the two to drift.
///
/// The startup run is not optional: the festival reminders are one-shot alarms,
/// so re-arming on launch is what carries the schedule past each festival and
/// into the next.

final class NotificationBootstrapProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Side-effecting bootstrap: re-arms the local schedule whenever settings
  /// change, and once on startup.
  ///
  /// Watched from the root widget so it stays alive for the app's lifetime. This
  /// is the SINGLE place that drives scheduling — the notifier's mutators only
  /// persist state, so there is exactly one path from "settings changed" to
  /// "alarms re-armed" and no way for the two to drift.
  ///
  /// The startup run is not optional: the festival reminders are one-shot alarms,
  /// so re-arming on launch is what carries the schedule past each festival and
  /// into the next.
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
    r'85fbfa04a8240eebafd8dd77ee45ae3e182b2507';
