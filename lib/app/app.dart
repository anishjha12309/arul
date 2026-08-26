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
    // A reminder is about ONE deity, so tapping it should land on that deity —
    // not on wherever the feed happened to be left. The payload is the category
    // slug; select it first, then route, so the feed's first build already has
    // the right filter and the user never sees the previous category flash past.
    ref.read(notificationServiceProvider).onOpenCategory = (category) {
      if (!mounted) return;
      ref.read(selectedCategoryProvider.notifier).select(category);
      router.go('/browse');
    };
  }

  @override
  Widget build(BuildContext context) {
    // Drives local-reminder (re)scheduling: re-arms whenever the notification
    // settings change, and once on startup. Watched HERE, from the root, because
    // the festival reminders are one-shot alarms — the launch-time re-arm is
    // what carries the schedule past each festival into the next one, so it must
    // not depend on the user opening any particular screen.
    ref.watch(notificationBootstrapProvider);

    // A link's `lang=` lands on the live locale from here — above the
    // MaterialApp, so it covers the sign-in screen as much as the feed, and for
    // the whole session, so a deferred delivery that arrives seconds in still
    // applies (deep_link_locale_sync.dart).
    return DeepLinkLocaleSync(
      child: MaterialApp.router(
        title: 'Arul',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: ArulTheme.light(),
        darkTheme: ArulTheme.dark(),
        themeMode: ref.watch(themeModeProvider),

        // Switch themes in ONE frame instead of lerping for 200ms.
        //
        // MaterialApp otherwise wraps the app in an AnimatedTheme, and a theme
        // lerp is not a cheap crossfade: every frame interpolates the whole
        // ThemeData — full ColorScheme, all fifteen text styles, every component
        // sub-theme — and rebuilds every `Theme.of(context)` dependant in the
        // tree. Over the feed, with video textures and shimmer already live, that
        // is exactly the stutter people read as jank. Passing noAnimation makes
        // MaterialApp use a plain Theme widget instead (material/app.dart), so the
        // swap costs a single frame and the sheet's own dismiss animation is left
        // to run alone.
        themeAnimationStyle: AnimationStyle.noAnimation,
        locale: ref.watch(localeProvider),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }
}
