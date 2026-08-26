import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
/// Splash decides imperatively: loading → stays here, unauthed → /sign-in,
/// authed → /browse.
///
/// The three-tab shell is the app's shape: Wallpapers · Ringtones · Settings,
/// each an always-alive branch behind the floating dock. Settings lives IN the
/// dock — never a route pushed over the feed — while its sub-screens
/// (notifications, premium, refer, upload) stay top-level pushes OVER the shell.
///
/// Page transitions come from the theme, not from custom pageBuilders, so every
/// push inherits `PredictiveBackPageTransitionsBuilder` — hand-rolling a
/// transition here would silently opt the route out of the predictive-back
/// gesture.
final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
    GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
    // Wallpaper deep link — the App Link half of `arul.hsrutility.com/w/<id>`
    // (docs/share.md). Renders NOTHING and always redirects to `/`: the target
    // is the feed, and the feed can only be reached through the splash's auth
    // decision, so short-circuiting to /browse here would show the shell to a
    // signed-out user. The id is parked in ArulDeepLink and consumed by the feed
    // once the catalog lands — the same place the deferred install-referrer path
    // delivers it, so both links open the same way.
    GoRoute(
      path: '/w/:id',
      redirect: (_, state) {
        ArulDeepLink.request(state.pathParameters['id'] ?? '');
        return '/';
      },
    ),
    StatefulShellRoute(
      // Not .indexedStack: the branches go through ArulBranchCrossfade so a tab
      // switch dissolves instead of cutting.
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
    // Privacy / Terms, read in-app. A top-level push OVER the shell like every
    // other sub-screen, so it works the same whether it was opened from the
    // Settings branch or from /sign-in, which sits outside the shell entirely.
    // Push it with `PolicyDoc.route` rather than a literal path.
    GoRoute(
      path: '/policy/:doc',
      builder: (_, state) =>
          PolicyScreen(doc: PolicyDoc.fromSlug(state.pathParameters['doc'])),
    ),
    GoRoute(
      path: '/premium',
      // THE premium route — paywall AND plan home in one screen; it renders
      // whatever the user's real subscription state calls for (the old
      // /premium/manage two-hop was folded in on 2026-08-11).
      // `source` is the blocked verb that sent the user here (apply / share /
      // ringtone_set / feed / settings). Tracking happens at the GATE, not
      // here: `ensurePremium` fires `${source}_blocked_premium` before it
      // pushes this route. PremiumScreen only displays/attributes it.
      // Pinned LIGHT at the ROUTE level, not inside the screen: sheets and
      // dialogs capture inherited themes from the screen's own context, which
      // sits ABOVE anything the screen's build wraps — a Theme inside the
      // screen left the UPI picker sheet dark over the light page.
      builder: (_, state) => Theme(
        data: ArulTheme.light(),
        child: PremiumScreen(
          source: state.uri.queryParameters['source'] ?? 'unknown',
        ),
      ),
    ),
  ],
);
