// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'locale_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The phone's own language preference order.
///
/// A provider so tests can hand in a phone; read straight off the [ui.PlatformDispatcher] rather
/// than `WidgetsBinding.instance`, which is not up in a plain `ProviderContainer` test.

@ProviderFor(platformLocales)
final platformLocalesProvider = PlatformLocalesProvider._();

/// The phone's own language preference order.
///
/// A provider so tests can hand in a phone; read straight off the [ui.PlatformDispatcher] rather
/// than `WidgetsBinding.instance`, which is not up in a plain `ProviderContainer` test.

final class PlatformLocalesProvider
    extends
        $FunctionalProvider<List<ui.Locale>, List<ui.Locale>, List<ui.Locale>>
    with $Provider<List<ui.Locale>> {
  /// The phone's own language preference order.
  ///
  /// A provider so tests can hand in a phone; read straight off the [ui.PlatformDispatcher] rather
  /// than `WidgetsBinding.instance`, which is not up in a plain `ProviderContainer` test.
  PlatformLocalesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'platformLocalesProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$platformLocalesHash();

  @$internal
  @override
  $ProviderElement<List<ui.Locale>> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  List<ui.Locale> create(Ref ref) {
    return platformLocales(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<ui.Locale> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<ui.Locale>>(value),
    );
  }
}

String _$platformLocalesHash() => r'9a4174189f347f402d51d167124602ee154ab761';

/// The app locale. Persisted pick first, then the REGION, then the PHONE, then English.
///
/// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
/// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
/// preference follows the phone.
///
/// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
/// said on first launch, so changing the phone's language later would stop moving the app; and
/// Settings would show a language the user never picked as if they had. Only an explicit pick
/// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
/// the link's language wins over a later phone change too). The region answer is stored beside
/// the pick, never as one, for the same reason.

@ProviderFor(LocaleNotifier)
final localeProvider = LocaleNotifierProvider._();

/// The app locale. Persisted pick first, then the REGION, then the PHONE, then English.
///
/// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
/// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
/// preference follows the phone.
///
/// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
/// said on first launch, so changing the phone's language later would stop moving the app; and
/// Settings would show a language the user never picked as if they had. Only an explicit pick
/// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
/// the link's language wins over a later phone change too). The region answer is stored beside
/// the pick, never as one, for the same reason.
final class LocaleNotifierProvider
    extends $NotifierProvider<LocaleNotifier, ui.Locale> {
  /// The app locale. Persisted pick first, then the REGION, then the PHONE, then English.
  ///
  /// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
  /// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
  /// preference follows the phone.
  ///
  /// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
  /// said on first launch, so changing the phone's language later would stop moving the app; and
  /// Settings would show a language the user never picked as if they had. Only an explicit pick
  /// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
  /// the link's language wins over a later phone change too). The region answer is stored beside
  /// the pick, never as one, for the same reason.
  LocaleNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localeNotifierHash();

  @$internal
  @override
  LocaleNotifier create() => LocaleNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ui.Locale value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ui.Locale>(value),
    );
  }
}

String _$localeNotifierHash() => r'0e593b713c9445c47bda81fd28feedd1d406f117';

/// The app locale. Persisted pick first, then the REGION, then the PHONE, then English.
///
/// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
/// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
/// preference follows the phone.
///
/// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
/// said on first launch, so changing the phone's language later would stop moving the app; and
/// Settings would show a language the user never picked as if they had. Only an explicit pick
/// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
/// the link's language wins over a later phone change too). The region answer is stored beside
/// the pick, never as one, for the same reason.

abstract class _$LocaleNotifier extends $Notifier<ui.Locale> {
  ui.Locale build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ui.Locale, ui.Locale>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ui.Locale, ui.Locale>,
              ui.Locale,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Where the language came from, re-read from prefs -> [LocaleNotifier] invalidates it on every write.
/// Never derived from [localeProvider]: a Tamil phone answered `ta` by its region changes the SOURCE
/// only, and an equal locale never notifies.

@ProviderFor(languageOrigin)
final languageOriginProvider = LanguageOriginProvider._();

/// Where the language came from, re-read from prefs -> [LocaleNotifier] invalidates it on every write.
/// Never derived from [localeProvider]: a Tamil phone answered `ta` by its region changes the SOURCE
/// only, and an equal locale never notifies.

final class LanguageOriginProvider
    extends $FunctionalProvider<LanguageOrigin, LanguageOrigin, LanguageOrigin>
    with $Provider<LanguageOrigin> {
  /// Where the language came from, re-read from prefs -> [LocaleNotifier] invalidates it on every write.
  /// Never derived from [localeProvider]: a Tamil phone answered `ta` by its region changes the SOURCE
  /// only, and an equal locale never notifies.
  LanguageOriginProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'languageOriginProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$languageOriginHash();

  @$internal
  @override
  $ProviderElement<LanguageOrigin> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  LanguageOrigin create(Ref ref) {
    return languageOrigin(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LanguageOrigin value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LanguageOrigin>(value),
    );
  }
}

String _$languageOriginHash() => r'46db6b3ebcaacbf0248bc109ad519d2fbd4df5ce';
