import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/deeplink/deep_link_parser.dart';
import '../core/deeplink/deep_link_target.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/legal/presentation/policy_screen.dart';
import '../features/notifications/presentation/notification_settings_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/referral/presentation/refer_screen.dart';
import '../features/ringtones/presentation/ringtones_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import 'widgets/english_only.dart';
import '../features/wallpapers/presentation/feed_screen.dart';
import 'shell/app_shell.dart';
import 'theme/theme.dart';

/// Routes.
///
/// Splash decides imperatively: loading stays -> unauthed goes /sign-in -> authed goes /browse.
/// Wallpapers · Ringtones · Settings are always-alive dock BRANCHES -> Settings is never a push.
/// Their sub-screens (notifications, premium, refer, upload) stay top-level pushes OVER the shell.
/// Transitions come from the theme -> a custom pageBuilder here opts the route out of predictive back.
final router = GoRouter(
  initialLocation: '/',
  // Incoming links — the installed half of every ad/share URL (docs/deep-links.md).
  // Android hands Flutter the intent's FULL URI -> scheme, host and query arrive exactly as sent.
  // Shapes: App Link `https://arul.hsrutility.com/{w,r}/<id>?lang=` and `fb<APP_ID>://open?...`.
  // Meta's form has no path -> normalises to `/` -> redirect top-level, or it runs on every nav.
  // Tabs are reachable only via the splash's auth decision -> park the target, return `/`, not /browse.
  // An ad link with a typo must land on the app, not an error page -> every foreign scheme ends at `/`.
  // The PhonePe `arul://` return parses to nothing and resolves to `/` -> keep it that way.
  // Internal navigations (`/browse`, `/premium?…`) carry no scheme -> stay a cheap null for them.
  redirect: (_, state) {
    if (state.uri.scheme.isEmpty) return null;
    final request = parseDeepLinkUri(state.uri, source: DeepLinkSource.appLink);
    if (request != null) {
      final target = request.target;
      if (target != null) ArulDeepLink.requestTarget(target);
      final lang = request.lang;
      if (lang != null) ArulDeepLink.requestLocale(lang);
    }
    return '/';
  },
  routes: [
    GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
    GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
    // Declared so an App Link path can never surface as "no routes for location" — the redirect ran first.
    GoRoute(path: '/w/:id', redirect: (_, _) => '/'),
    GoRoute(path: '/r/:id', redirect: (_, _) => '/'),
    StatefulShellRoute(
      // Not .indexedStack -> branches go through ArulBranchCrossfade -> a tab switch dissolves, never cuts.
      navigatorContainerBuilder: (_, navigationShell, children) =>
          ArulBranchCrossfade(
            currentIndex: navigationShell.currentIndex,
            children: children,
          ),
      builder: (_, _, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/browse', builder: (_, _) => const FeedScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/ringtones',
              builder: (_, _) => const RingtonesScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/settings/notifications',
      // Whole-screen English (EnglishOnly doc): `remindersTitle` is demoted.
      builder: (_, _) => const EnglishOnly(child: NotificationSettingsScreen()),
    ),
    GoRoute(path: '/refer', builder: (_, _) => const ReferScreen()),
    // Whole-screen English (EnglishOnly doc): four upload keys are demoted.
    GoRoute(
      path: '/upload',
      builder: (_, _) => const EnglishOnly(child: UploadScreen()),
    ),
    // Privacy / Terms, read in-app.
    // Pushed OVER the shell -> opens the same from the Settings branch and from /sign-in, outside it.
    // Push it with `PolicyDoc.route`, never a literal path.
    GoRoute(
      path: '/policy/:doc',
      builder: (_, state) =>
          PolicyScreen(doc: PolicyDoc.fromSlug(state.pathParameters['doc'])),
    ),
    GoRoute(
      path: '/premium',
      // THE premium route — paywall AND plan home in one screen, rendering the real subscription state.
      // `source` is the blocked verb that sent the user here: apply/share/ringtone_set/feed/settings.
      // `ensurePremium` fires `${source}_blocked_premium` at the GATE before pushing -> never track here.
      // Sheets and dialogs inherit theme from the SCREEN's context, above anything its build wraps.
      // A Theme inside the screen left the UPI picker sheet dark -> pin LIGHT at the ROUTE level.
      builder: (_, state) => Theme(
        data: ArulTheme.light(),
        child: PremiumScreen(
          source: state.uri.queryParameters['source'] ?? 'unknown',
        ),
      ),
    ),
  ],
);
