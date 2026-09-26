import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/analytics/analytics_provider.dart';
import '../core/analytics/analytics_service.dart';
import '../core/config/build_info.dart';
import '../core/crash/crash_provider.dart';
import '../core/deeplink/deep_link_locale_sync.dart';
import '../core/experiments/experiments.dart';
import '../core/providers/locale_provider.dart';
import '../features/app_update/providers/app_update_controller.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/notifications/providers/notification_providers.dart';
import '../features/push/data/push_open_handler.dart';
import '../features/push/data/push_tap_router.dart';
import '../features/push/providers/push_providers.dart';
import '../features/settings/providers/theme_mode_provider.dart';
import '../features/wallpapers/providers/catalog_providers.dart';
import 'l10n/app_localizations.dart';
import 'router.dart';
import 'safe_back_button_dispatcher.dart';
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
    // The unfinished-trial reminder goes back to the paywall.
    ref.read(notificationServiceProvider).onOpenTrialReminder = () {
      if (!mounted) return;
      router.go('/premium?source=trial_reminder');
    };

    // A tapped CAMPAIGN notification (docs/push.md). Started here, beside the local handler and
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

    // A session that dies mid-use -> the wall, as a cold start with a dead session already gets.
    // The splash (`/`) routes on its own and the wall needs nothing; every other screen is signed-in
    // UI whose gated calls would all fail. Sign-out and delete land here too, harmlessly.
    ref.listenManual(authStateStreamProvider, (previous, next) {
      final wasSignedIn = previous?.value?.isAuthenticated ?? false;
      if (!wasSignedIn || (next.value?.isAuthenticated ?? true)) return;
      final path = router.routerDelegate.currentConfiguration.uri.path;
      if (path == '/' || path == '/sign-in') return;
      ref.read(authControllerProvider.notifier).sessionEnded();
      router.go('/sign-in');
    });

    _backButton = SafeBackButtonDispatcher(
      rootNavigator: router.routerDelegate.navigatorKey,
      onError: (error, stack) => ref
          .read(crashReporterProvider)
          .recordError(error, stack, reason: 'router back'),
    );

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
    // Where that language came from and what the region said -> the two properties that measure the
    // region default. Its own provider: a region answer matching the phone moves the SOURCE only.
    ref.listenManual(languageOriginProvider, (_, next) {
      final analytics = ref.read(analyticsServiceProvider);
      analytics.register(kLanguageSourceProperty, next.source.key);
      analytics.register(kGeoRegionProperty, next.geoRegion);
    }, fireImmediately: true);
    // The factorial's arms on every event, for GA4 as much as PostHog. Fixed for the process -> once.
    final analytics = ref.read(analyticsServiceProvider);
    ref.read(experimentsProvider).analyticsProperties.forEach(analytics.register);
    // How much phone this is, on every later event. One probe per process, so this fires once;
    // events captured before it lands simply carry no tier rather than a guessed one.
    unawaited(
      DeviceQuality.tier.then((tier) {
        if (!mounted) return;
        ref
            .read(analyticsServiceProvider)
            .register(kDeviceTierProperty, tier.name);
      }),
    );
  }

  PushOpenHandler? _pushOpen;
  PushTapRouter? _pushTaps;
  late final SafeBackButtonDispatcher _backButton;

  @override
  void dispose() {
    _pushOpen?.dispose();
    _pushTaps?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-arms the unfinished-trial reminder once on startup, from its persisted instant.
    ref.watch(notificationBootstrapProvider);

    // Campaign push (docs/push.md), watched at the ROOT for the same reason: neither depends on a
    // user opening a screen. `pushBootstrap` registers this phone once a session exists and re-posts
    // on a language change; `pushChannelName` renames the "Updates from Arul" channel into the
    // user's language (the channel itself is created by NotificationService.initialize at launch).
    ref.watch(pushBootstrapProvider);
    ref.watch(pushChannelNameProvider);

    // Play in-app update (docs/app-update.md) -> at the root, like the bootstraps above.
    ref.watch(appUpdateBootstrapProvider);

    // Above the MaterialApp -> a link's `lang=` covers the sign-in screen as much as the feed.
    // Lives for the whole session -> a deferred delivery arriving seconds in still applies.
    return DeepLinkLocaleSync(
      child: MaterialApp.router(
        title: 'Arul',
        debugShowCheckedModeBanner: false,
        // The router's parts rather than `routerConfig`: that is the only way to hand it a back
        // dispatcher of our own -> see SafeBackButtonDispatcher for the go_router crash it contains.
        routerDelegate: router.routerDelegate,
        routeInformationParser: router.routeInformationParser,
        routeInformationProvider: router.routeInformationProvider,
        backButtonDispatcher: _backButton,
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
