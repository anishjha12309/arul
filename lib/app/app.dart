import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/deeplink/deep_link_locale_sync.dart';
import '../core/providers/locale_provider.dart';
import '../features/notifications/providers/notification_providers.dart';
import '../features/settings/providers/theme_mode_provider.dart';
import '../features/wallpapers/providers/catalog_providers.dart';
import 'l10n/app_localizations.dart';
import 'router.dart';
import 'theme/theme.dart';

class ArulApp extends ConsumerStatefulWidget {
  const ArulApp({super.key});

  @override
  ConsumerState<ArulApp> createState() => _ArulAppState();
}

class _ArulAppState extends ConsumerState<ArulApp> {
  @override
  void initState() {
    super.initState();
    // A reminder is about ONE deity -> its tap lands on that deity, never on wherever the feed was left.
    // Select the category BEFORE routing -> the feed's first build already filters -> no flash of the old one.
    ref.read(notificationServiceProvider).onOpenCategory = (category) {
      if (!mounted) return;
      ref.read(selectedCategoryProvider.notifier).select(category);
      router.go('/browse');
    };
  }

  @override
  Widget build(BuildContext context) {
    // Re-arms local reminders on every notification-settings change and once on startup.
    // Festival reminders are one-shot alarms -> only the launch-time re-arm reaches the next one.
    // So it must not depend on the user opening a screen -> watched at the ROOT, not from any screen.
    ref.watch(notificationBootstrapProvider);

    // Above the MaterialApp -> a link's `lang=` covers the sign-in screen as much as the feed.
    // Lives for the whole session -> a deferred delivery arriving seconds in still applies.
    return DeepLinkLocaleSync(
      child: MaterialApp.router(
        title: 'Arul',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: ArulTheme.light(),
        darkTheme: ArulTheme.dark(),
        themeMode: ref.watch(themeModeProvider),

        // MaterialApp otherwise wraps the app in an AnimatedTheme -> themes lerp for 200ms.
        // The lerp re-interpolates a whole ThemeData and every `Theme.of` dependant, per frame.
        // Over live video textures that is the stutter read as jank -> noAnimation, a plain Theme.
        // One-frame swap -> the sheet's own dismiss animation is left to run alone.
        themeAnimationStyle: AnimationStyle.noAnimation,
        locale: ref.watch(localeProvider),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }
}
