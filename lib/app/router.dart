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
  // Incoming links — the installed half of every ad/share URL
  // (docs/deep-links.md). Android hands Flutter the intent's FULL URI (scheme,
  // host, query — verified against the engine's embedding), so this sees
  //   https://arul.hsrutility.com/w/<id>?lang=hi          (App Link)
  //   https://arul.hsrutility.com/r/<id>?lang=ta          (App Link)
  //   fb<APP_ID>://open?wallpaper_id=<id>&lang=hi          (Meta's scheme)
  // exactly as sent. A top-level redirect rather than per-route ones because
  // Meta's form has NO path: go_router normalises it to `/`, and a route-level
  // redirect on `/` would then run for every ordinary navigation too.
  //
  // Whatever it parses is parked in ArulDeepLink and the location becomes `/`:
  // the target lives on a tab, and the tabs can only be reached through the
  // splash's auth decision, so short-circuiting to /browse here would show the
  // shell to a signed-out user. Every foreign-scheme URI ends at `/`, valid or
  // not — an ad link with a typo must land on the app, never on an error page.
  // The PhonePe `arul://` return has no scheme we parse and resolved to `/`
  // before this existed; it still does.
  //
  // Internal navigations (`/browse`, `/premium?…`) carry no scheme and pass
  // straight through — this must stay a cheap null for them.
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
    // The App Link paths, declared so they can never surface as "no routes for
    // location": the top-level redirect above has already parked the target
    // and rewritten the location to `/` by the time these would match.
    GoRoute(path: '/w/:id', redirect: (_, _) => '/'),
    GoRoute(path: '/r/:id', redirect: (_, _) => '/'),
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
