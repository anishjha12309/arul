// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trial_nudge_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Whether the "finish setting up your free trial" row should show.
///
/// keepAlive: a dismissal hides the row for the rest of the process, never for good — the marker
/// outlives it, so the next cold start asks again until the trial is finished or the marker ages
/// out. The provider is the only writer of [TrialNudge]'s keys, so the row, the reminder and the
/// prefs can never disagree about whether an unfinished trial exists.

@ProviderFor(TrialNudgeNotifier)
final trialNudgeProvider = TrialNudgeNotifierProvider._();

/// Whether the "finish setting up your free trial" row should show.
///
/// keepAlive: a dismissal hides the row for the rest of the process, never for good — the marker
/// outlives it, so the next cold start asks again until the trial is finished or the marker ages
/// out. The provider is the only writer of [TrialNudge]'s keys, so the row, the reminder and the
/// prefs can never disagree about whether an unfinished trial exists.
final class TrialNudgeNotifierProvider
    extends $NotifierProvider<TrialNudgeNotifier, bool> {
  /// Whether the "finish setting up your free trial" row should show.
  ///
  /// keepAlive: a dismissal hides the row for the rest of the process, never for good — the marker
  /// outlives it, so the next cold start asks again until the trial is finished or the marker ages
  /// out. The provider is the only writer of [TrialNudge]'s keys, so the row, the reminder and the
  /// prefs can never disagree about whether an unfinished trial exists.
  TrialNudgeNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'trialNudgeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$trialNudgeNotifierHash();

  @$internal
  @override
  TrialNudgeNotifier create() => TrialNudgeNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$trialNudgeNotifierHash() =>
    r'2bdb1647220261f6473adf90396dc88cfb6eec36';

/// Whether the "finish setting up your free trial" row should show.
///
/// keepAlive: a dismissal hides the row for the rest of the process, never for good — the marker
/// outlives it, so the next cold start asks again until the trial is finished or the marker ages
/// out. The provider is the only writer of [TrialNudge]'s keys, so the row, the reminder and the
/// prefs can never disagree about whether an unfinished trial exists.

abstract class _$TrialNudgeNotifier extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
