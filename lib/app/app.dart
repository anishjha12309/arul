import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analytics/analytics_provider.dart';
import '../core/analytics/analytics_service.dart';
import '../core/crash/crash_provider.dart';
import '../core/deeplink/deep_link_locale_sync.dart';
import '../core/providers/locale_provider.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/notifications/providers/notification_providers.dart';
import '../features/push/data/push_open_handler.dart';
import '../features/push/data/push_tap_router.dart';
import '../features/push/providers/push_providers.dart';
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
    // The one reminder that is not about a deity: an unfinished trial goes back to the paywall.
    ref.read(notificationServiceProvider).onOpenTrialReminder = () {
      if (!mounted) return;
      router.go('/premium?source=trial_reminder');
    };

    // A tapped CAMPAIGN notification (docs/push.md). Started here, beside the local handlers and
    // before the router resolves the launch, for the same reason `NotificationService` is built
    // before `runApp`: a tap that LAUNCHED the app must find a live handler, and the cold tap is the
    // one that matters. [PushTapRouter] holds a tap that lands before the splash's auth decision.
    _pushTaps = PushTapRouter(
      router: router,
      onSelectCategory: (slug) =>
          ref.read(selectedCategoryProvider.notifier).select(slug),
    );
    _pushOpen = PushOpenHandler(
      apiClient: ref.read(apiClientProvider),
      analytics: ref.read(analyticsServiceProvider),
      crash: ref.read(crashReporterProvider),
      onOpen: (target) {
        if (!mounted) return;
        _pushTaps?.open(target);
      },
    );
    unawaited(_pushOpen!.start());

    // The UI language on EVERY event, not only on the person at sign-in: pre-login events (install,
    // the sign-in wall) otherwise carry no language, and a `lang=` link applying mid-launch is
    // exactly what the funnel needs to see. Fires now and on each change (link or Settings).
    ref.listenManual(
      localeProvider,
      (_, next) => ref
          .read(analyticsServiceProvider)
          .register(kAppLanguageProperty, next.languageCode),
      fireImmediately: true,
    );
  }

  PushOpenHandler? _pushOpen;
  PushTapRouter? _pushTaps;

  @override
  void dispose() {
    _pushOpen?.dispose();
    _pushTaps?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-arms local reminders on every notification-settings change and once on startup.
    // Festival reminders are one-shot alarms -> only the launch-time re-arm reaches the next one.
    // So it must not depend on the user opening a screen -> watched at the ROOT, not from any screen.
    ref.watch(notificationBootstrapProvider);

    // Campaign push (docs/push.md), watched at the ROOT for the same reason: neither depends on a
    // user opening a screen. `pushBootstrap` registers this phone once a session exists and re-posts
    // on a language change; `pushChannelName` renames the "Updates from Arul" channel into the
    // user's language (the channel itself is created by NotificationService.initialize at launch).
    ref.watch(pushBootstrapProvider);
    ref.watch(pushChannelNameProvider);

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
