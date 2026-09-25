// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'come_back_reminder.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Started from the splash, before the splash's own sign-in attempt can bring Google's surface up.

@ProviderFor(comeBackReminder)
final comeBackReminderProvider = ComeBackReminderProvider._();

/// Started from the splash, before the splash's own sign-in attempt can bring Google's surface up.

final class ComeBackReminderProvider
    extends
        $FunctionalProvider<
          ComeBackReminder,
          ComeBackReminder,
          ComeBackReminder
        >
    with $Provider<ComeBackReminder> {
  /// Started from the splash, before the splash's own sign-in attempt can bring Google's surface up.
  ComeBackReminderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'comeBackReminderProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$comeBackReminderHash();

  @$internal
  @override
  $ProviderElement<ComeBackReminder> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  ComeBackReminder create(Ref ref) {
    return comeBackReminder(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ComeBackReminder value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ComeBackReminder>(value),
    );
  }
}

String _$comeBackReminderHash() => r'8e0d5056d59bd314ea801b11d3aa65b1bee9d068';
