import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/launch/launch_moment.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/uninstall_shortcut_channel.dart';
import '../domain/winback_daily_controller.dart';
import '../domain/winback_ledger.dart';
import '../domain/winback_reach.dart';
import 'entitlement_provider.dart';

part 'winback_reach_providers.g.dart';

@Riverpod(keepAlive: true)
WinbackLedger winbackLedger(Ref ref) =>
    WinbackLedger(ref.watch(sharedPreferencesProvider));

@Riverpod(keepAlive: true)
WinbackReachFlags winbackReachFlags(Ref ref) =>
    WinbackReachFlags.from(ref.watch(appConfigProvider).asData?.value);

@Riverpod(keepAlive: true)
UninstallShortcutChannel uninstallShortcutChannel(Ref ref) =>
    const UninstallShortcutChannel();

/// Mirrors the "Uninstall" shortcut onto the phone: published while `/me` says premium ran out on
/// someone offered ₹99 and its switch is on, removed otherwise (sign-out included), labelled in the
/// app's language. Listened at the root; a resume re-runs it, since a restored phone loses dynamic
/// shortcuts.
@Riverpod(keepAlive: true)
Future<void> uninstallShortcutSync(Ref ref) async {
  final lifecycle = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(lifecycle.dispose);

  final me = ref.watch(entitlementDetailProvider);
  final config = ref.watch(appConfigProvider);
  final locale = ref.watch(localeProvider);
  // No verdict: leave the phone as it is, so an offline launch never retires a valid shortcut nor
  // publishes one the CMS switched off.
  if (!me.hasValue || me.hasError || !config.hasValue || config.hasError) {
    return;
  }
  final publish =
      WinbackReachFlags.from(config.value).uninstallShortcut &&
      winbackReachable(me.value);
  // No BuildContext: the labels must not depend on one, exactly like the Quick Access bar's.
  final l10n = await AppLocalizations.delegate.load(locale);
  if (!ref.mounted) return;
  await ref
      .read(uninstallShortcutChannelProvider)
      .sync(
        publish: publish,
        shortLabel: l10n.uninstallShortcutShort,
        longLabel: l10n.uninstallShortcutLong,
      );
}

@Riverpod(keepAlive: true)
WinbackDailyController winbackDailyController(Ref ref) =>
    WinbackDailyController(
      ledger: ref.watch(winbackLedgerProvider),
      moment: ref.watch(launchMomentProvider),
      entitlement: () async {
        // Listened while it waits: a `/me` re-read that nothing listens to never rebuilds.
        final listening = ref.listen(entitlementDetailProvider, (_, _) {});
        try {
          return await ref.read(entitlementDetailProvider.future);
        } finally {
          listening.close();
        }
      },
      flags: () => ref.read(winbackReachFlagsProvider),
    );
