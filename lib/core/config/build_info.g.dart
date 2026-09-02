// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'build_info.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Whether this build came from Google Play — the uploaded `.aab`, not a sideloaded APK.
///
/// No BuildConfig signal separates an APK from an AAB (both are `release`) -> the installer package
/// is the runtime proxy -> only a Play install reports `com.android.vending`.
/// FLAG_SECURE already rides the same check -> the native side owns it ([MainActivity.isPlayInstall])
/// -> the two can never disagree.
/// **Fails CLOSED**: an unresolvable installer answers `true` -> every caller hides something that
/// must be absent from the store build.

@ProviderFor(isPlayInstall)
final isPlayInstallProvider = IsPlayInstallProvider._();

/// Whether this build came from Google Play — the uploaded `.aab`, not a sideloaded APK.
///
/// No BuildConfig signal separates an APK from an AAB (both are `release`) -> the installer package
/// is the runtime proxy -> only a Play install reports `com.android.vending`.
/// FLAG_SECURE already rides the same check -> the native side owns it ([MainActivity.isPlayInstall])
/// -> the two can never disagree.
/// **Fails CLOSED**: an unresolvable installer answers `true` -> every caller hides something that
/// must be absent from the store build.

final class IsPlayInstallProvider
    extends $FunctionalProvider<AsyncValue<bool>, bool, FutureOr<bool>>
    with $FutureModifier<bool>, $FutureProvider<bool> {
  /// Whether this build came from Google Play — the uploaded `.aab`, not a sideloaded APK.
  ///
  /// No BuildConfig signal separates an APK from an AAB (both are `release`) -> the installer package
  /// is the runtime proxy -> only a Play install reports `com.android.vending`.
  /// FLAG_SECURE already rides the same check -> the native side owns it ([MainActivity.isPlayInstall])
  /// -> the two can never disagree.
  /// **Fails CLOSED**: an unresolvable installer answers `true` -> every caller hides something that
  /// must be absent from the store build.
  IsPlayInstallProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isPlayInstallProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isPlayInstallHash();

  @$internal
  @override
  $FutureProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<bool> create(Ref ref) {
    return isPlayInstall(ref);
  }
}

String _$isPlayInstallHash() => r'7a83dca757fabdabb474093d7cc7b16240bb894d';

/// Whether the on-device QA affordances (fire a test notification, preview every reminder, inspect
/// what is actually armed) should be reachable.
///
/// True in debug AND in a **sideloaded release APK**, false in the Play build.
/// The APK case is the point: R8 resource shrinking is what strips the notification icons -> a
/// `kDebugMode` gate hid the one screen that could catch it, in exactly the build where it breaks.
/// Real users only ever get the AAB -> they still never see these.
/// A loading or failed answer resolves to false -> the tools appear a frame late on a release APK
/// rather than ever flashing up in the store build.

@ProviderFor(qaToolsEnabled)
final qaToolsEnabledProvider = QaToolsEnabledProvider._();

/// Whether the on-device QA affordances (fire a test notification, preview every reminder, inspect
/// what is actually armed) should be reachable.
///
/// True in debug AND in a **sideloaded release APK**, false in the Play build.
/// The APK case is the point: R8 resource shrinking is what strips the notification icons -> a
/// `kDebugMode` gate hid the one screen that could catch it, in exactly the build where it breaks.
/// Real users only ever get the AAB -> they still never see these.
/// A loading or failed answer resolves to false -> the tools appear a frame late on a release APK
/// rather than ever flashing up in the store build.

final class QaToolsEnabledProvider extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  /// Whether the on-device QA affordances (fire a test notification, preview every reminder, inspect
  /// what is actually armed) should be reachable.
  ///
  /// True in debug AND in a **sideloaded release APK**, false in the Play build.
  /// The APK case is the point: R8 resource shrinking is what strips the notification icons -> a
  /// `kDebugMode` gate hid the one screen that could catch it, in exactly the build where it breaks.
  /// Real users only ever get the AAB -> they still never see these.
  /// A loading or failed answer resolves to false -> the tools appear a frame late on a release APK
  /// rather than ever flashing up in the store build.
  QaToolsEnabledProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'qaToolsEnabledProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$qaToolsEnabledHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return qaToolsEnabled(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$qaToolsEnabledHash() => r'effac7f8fc51a89d752b2dd3d621215320512713';
