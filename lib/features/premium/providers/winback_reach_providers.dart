import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/launch/launch_moment.dart';
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
