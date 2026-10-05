import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/locale_provider.dart';
import 'deep_link_target.dart';
import 'install_referrer_service.dart';

/// Applies the language a link asked for (`lang=hi`) to the running app.
/// The pending value is written from go_router's redirect and async services, never inside a build.
/// So it is applied from a MICROTASK, never synchronously.
class DeepLinkLocaleSync extends ConsumerStatefulWidget {
  const DeepLinkLocaleSync({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DeepLinkLocaleSync> createState() => _DeepLinkLocaleSyncState();
}

class _DeepLinkLocaleSyncState extends ConsumerState<DeepLinkLocaleSync> {
  @override
  void initState() {
    super.initState();
    ArulDeepLink.changes.addListener(_schedule);
    _schedule();
  }

  @override
  void dispose() {
    ArulDeepLink.changes.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() => scheduleMicrotask(_apply);

  void _apply() {
    if (!mounted) return;
    final code = ArulDeepLink.consumeLocale();
    if (code == null) return;
    final locale = supportedAppLocales.cast<Locale?>().firstWhere(
      (l) => l!.languageCode == code,
      orElse: () => null,
    );
    if (locale == null) return;
    unawaited(
      ref
          .read(localeProvider.notifier)
          .setLocale(locale, source: LanguageSource.link),
    );
    // The persisted copy only survives a process death between capture and apply -> `arul_locale` has it.
    unawaited(ref.read(installReferrerServiceProvider).clearPendingLang());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
