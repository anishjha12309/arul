import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/quick_bar_channel.dart';

part 'quick_bar_providers.g.dart';

@Riverpod(keepAlive: true)
QuickBarChannel quickBarChannel(Ref ref) => const QuickBarChannel();

/// The person's choice: null until made. [autoEnable] makes it once, the first time notifications
/// are allowed (Noor's rule); after that only the Settings toggle changes it.
@Riverpod(keepAlive: true)
class QuickBarSetting extends _$QuickBarSetting {
  static const prefKey = 'arul_quick_bar_on';

  Future<void>? _autoEnabling;

  @override
  bool? build() => ref.watch(sharedPreferencesProvider).getBool(prefKey);

  Future<void> set(bool on, {required String via}) async {
    await ref.read(sharedPreferencesProvider).setBool(prefKey, on);
    if (!ref.mounted) return;
    state = on;
    ref
        .read(analyticsServiceProvider)
        .track('quick_bar_toggled', properties: {'enabled': on, 'via': via});
  }

  /// Turns the bar on if nobody has decided yet and the phone would show it. A denial leaves the
  /// choice open, so a later grant in system settings still brings the bar on the next resume.
  ///
  /// One run at a time: the permission dialog closing is also a resume, so the feed's call and the
  /// resume hook arrive together and would each report `quick_bar_toggled`.
  Future<void> autoEnable() =>
      _autoEnabling ??= _autoEnable().whenComplete(() => _autoEnabling = null);

  Future<void> _autoEnable() async {
    if (state != null) return;
    // A first launch's kill switch may still be in flight: deciding before it lands would flash the
    // bar and spend the choice. An unreachable config falls back to the persisted verdict.
    try {
      await ref.read(appConfigProvider.future);
    } catch (_) {}
    if (!ref.mounted || state != null || !ref.read(quickBarAllowedProvider)) {
      return;
    }
    final status = await ref.read(quickBarChannelProvider).status();
    if (!ref.mounted || state != null || status?.visible != true) return;
    await set(true, via: 'auto');
  }
}

/// `feature_flags.quick_bar`: only a literal `false` takes the bar down. While the config is
/// loading, or never loads, the verdict [quickBarKillSwitch] persisted from the last one stands.
@Riverpod(keepAlive: true)
bool quickBarAllowed(Ref ref) {
  final flags = ref.watch(appConfigProvider).asData?.value?.featureFlags;
  if (flags != null) return flags[_flag] != false;
  return ref.watch(sharedPreferencesProvider).getBool(_killedKey) != true;
}

/// Persists the kill switch from every landed config, like `experimentKillSwitch`. Listened at the
/// root, so the verdict is saved even on a launch that never opens Settings.
@Riverpod(keepAlive: true)
void quickBarKillSwitch(Ref ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  ref.listen(appConfigProvider, (_, next) {
    final flags = next.asData?.value?.featureFlags;
    if (flags != null) {
      unawaited(prefs.setBool(_killedKey, flags[_flag] == false));
    }
  }, fireImmediately: true);
}

const _flag = 'quick_bar';
const _killedKey = 'arul_quick_bar_killed';

/// Mirrors the bar onto the phone: the choice, the kill switch and the labels in
/// the app's language. Listened at the root (never watched: the resume below invalidates it, and a
/// watch would rebuild the whole app twice per resume), so it runs on every launch and whenever one
/// of those moves. A resume re-runs it, which is how a permission granted in system settings shows
/// the bar.
@Riverpod(keepAlive: true)
Future<void> quickBarSync(Ref ref) async {
  final lifecycle = AppLifecycleListener(
    onResume: () {
      if (ref.read(authServiceProvider).currentState.isAuthenticated) {
        unawaited(ref.read(quickBarSettingProvider.notifier).autoEnable());
      }
      ref.invalidateSelf();
    },
  );
  ref.onDispose(lifecycle.dispose);

  final on =
      ref.watch(quickBarSettingProvider) == true &&
      ref.watch(quickBarAllowedProvider);
  final locale = ref.watch(localeProvider);
  // No BuildContext: the labels must not depend on one, exactly like the channel names.
  final l10n = await AppLocalizations.delegate.load(locale);
  if (!ref.mounted) return;
  await ref
      .read(quickBarChannelProvider)
      .sync(
        on: on,
        labels: QuickBarLabels(
          channelName: l10n.settingsQuickBar,
          wallpapers: l10n.quickBarWallpaper,
          ringtones: l10n.quickBarRingtone,
          status: l10n.statusTitle,
        ),
      );
}
