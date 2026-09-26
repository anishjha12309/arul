// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'launch_art_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The launch art for this process. The regional arm with `/geo` still unanswered starts AWAITING
/// and the splash [LaunchArtNotifier.settle]s it once, when the answer lands or the cap passes —
/// the art never changes after that, so a late answer can never swap the poster under the wall.

@ProviderFor(LaunchArtNotifier)
final launchArtProvider = LaunchArtNotifierProvider._();

/// The launch art for this process. The regional arm with `/geo` still unanswered starts AWAITING
/// and the splash [LaunchArtNotifier.settle]s it once, when the answer lands or the cap passes —
/// the art never changes after that, so a late answer can never swap the poster under the wall.
final class LaunchArtNotifierProvider
    extends $NotifierProvider<LaunchArtNotifier, LaunchArt> {
  /// The launch art for this process. The regional arm with `/geo` still unanswered starts AWAITING
  /// and the splash [LaunchArtNotifier.settle]s it once, when the answer lands or the cap passes —
  /// the art never changes after that, so a late answer can never swap the poster under the wall.
  LaunchArtNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'launchArtProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$launchArtNotifierHash();

  @$internal
  @override
  LaunchArtNotifier create() => LaunchArtNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LaunchArt value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LaunchArt>(value),
    );
  }
}

String _$launchArtNotifierHash() => r'9b3cf8f0ce5ad6f3d538e2bfec6a5d469c80aa19';

/// The launch art for this process. The regional arm with `/geo` still unanswered starts AWAITING
/// and the splash [LaunchArtNotifier.settle]s it once, when the answer lands or the cap passes —
/// the art never changes after that, so a late answer can never swap the poster under the wall.

abstract class _$LaunchArtNotifier extends $Notifier<LaunchArt> {
  LaunchArt build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<LaunchArt, LaunchArt>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LaunchArt, LaunchArt>,
              LaunchArt,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
