import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/uninstall_shortcut_channel.dart';
import '../domain/winback_ledger.dart';
import '../domain/winback_reach.dart';

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
