// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'launch_clip_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The regional poster's own live clip as a local file, once it may play over the poster; null
/// keeps the poster, which is also every failure's answer (launch-surface.md).
///
/// Read from the splash before its sign-in attempt, so Google's surface coming up is never missed.

@ProviderFor(LaunchClip)
final launchClipProvider = LaunchClipProvider._();

/// The regional poster's own live clip as a local file, once it may play over the poster; null
/// keeps the poster, which is also every failure's answer (launch-surface.md).
///
/// Read from the splash before its sign-in attempt, so Google's surface coming up is never missed.
final class LaunchClipProvider extends $NotifierProvider<LaunchClip, String?> {
  /// The regional poster's own live clip as a local file, once it may play over the poster; null
  /// keeps the poster, which is also every failure's answer (launch-surface.md).
  ///
  /// Read from the splash before its sign-in attempt, so Google's surface coming up is never missed.
  LaunchClipProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'launchClipProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$launchClipHash();

  @$internal
  @override
  LaunchClip create() => LaunchClip();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }
}

String _$launchClipHash() => r'bf2ad075cd9be4a1ac7b0c6c7b921d36b76f7a3d';

/// The regional poster's own live clip as a local file, once it may play over the poster; null
/// keeps the poster, which is also every failure's answer (launch-surface.md).
///
/// Read from the splash before its sign-in attempt, so Google's surface coming up is never missed.

abstract class _$LaunchClip extends $Notifier<String?> {
  String? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<String?, String?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<String?, String?>,
              String?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
