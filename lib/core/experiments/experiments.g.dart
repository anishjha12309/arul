// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'experiments.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Read once per process: the arm never changes mid-run, and a kill switch waits for the next launch.

@ProviderFor(experiments)
final experimentsProvider = ExperimentsProvider._();

/// Read once per process: the arm never changes mid-run, and a kill switch waits for the next launch.

final class ExperimentsProvider
    extends $FunctionalProvider<Experiments, Experiments, Experiments>
    with $Provider<Experiments> {
  /// Read once per process: the arm never changes mid-run, and a kill switch waits for the next launch.
  ExperimentsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'experimentsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$experimentsHash();

  @$internal
  @override
  $ProviderElement<Experiments> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  Experiments create(Ref ref) {
    return experiments(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Experiments value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Experiments>(value),
    );
  }
}

String _$experimentsHash() => r'2642e10f57f80bab0126e15129041eb3bd14170c';

/// Writes the kill switch whenever a config lands. Started from the splash; keepAlive so a config
/// that arrives after the splash has routed is still recorded.

@ProviderFor(experimentKillSwitch)
final experimentKillSwitchProvider = ExperimentKillSwitchProvider._();

/// Writes the kill switch whenever a config lands. Started from the splash; keepAlive so a config
/// that arrives after the splash has routed is still recorded.

final class ExperimentKillSwitchProvider
    extends $FunctionalProvider<void, void, void>
    with $Provider<void> {
  /// Writes the kill switch whenever a config lands. Started from the splash; keepAlive so a config
  /// that arrives after the splash has routed is still recorded.
  ExperimentKillSwitchProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'experimentKillSwitchProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$experimentKillSwitchHash();

  @$internal
  @override
  $ProviderElement<void> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  void create(Ref ref) {
    return experimentKillSwitch(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$experimentKillSwitchHash() =>
    r'bac93d3a2e1d16a0e3ecd58f0a9633668ef09f75';
