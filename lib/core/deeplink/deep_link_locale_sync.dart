import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/referral/providers/referral_providers.dart';
import '../providers/locale_provider.dart';
import 'deep_link_target.dart';

/// Applies the language a link asked for (`lang=hi`) to the running app.
///
/// Sits at the root, above `MaterialApp`, so it is alive for the whole
/// session: the code can be parked before the first frame (an App Link cold
/// start, the persisted referrer copy seeded in main.dart) or land seconds in
/// (Play referrer round-trip, GA4F, the Meta SDK) — either way it lands on the
/// live locale and every screen re-renders, the sign-in screen included.
///
/// The link's language ALWAYS wins (owner's call, 2026-08-26), including over
/// a language the user picked earlier in Settings. It goes through the same
/// `LocaleNotifier.setLocale` the Settings sheet uses, so it is persisted the
/// same way and Settings shows it as the current choice.
///
/// Applied from a microtask, never synchronously: the pending value is written
/// from go_router's redirect and from async services, and a provider must not
/// be mutated from inside a build.
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
    unawaited(ref.read(localeProvider.notifier).setLocale(locale));
    // The persisted pending copy exists only to survive a process death
    // between capture and this apply; `arul_locale` now carries the value.
    unawaited(ref.read(installReferrerServiceProvider).clearPendingLang());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
