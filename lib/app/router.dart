import 'package:go_router/go_router.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/notifications/presentation/notification_settings_screen.dart';
import '../features/premium/presentation/manage_subscription_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/referral/presentation/refer_screen.dart';
// RINGTONES-PARKED: import '../features/ringtones/presentation/ringtones_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import '../features/wallpapers/presentation/feed_screen.dart';
// RINGTONES-PARKED: import 'shell/app_shell.dart';

/// Routes.
///
/// Auth flow is unchanged: splash decides (loading → stays here, unauthed →
/// /sign-in, authed → /browse) — imperatively, exactly as before the shell.
///
/// RINGTONES-PARKED (2026-07-29, v1 production release): there is no ringtone
/// audio in the bucket yet, so the tab only ever showed its "coming soon" empty
/// state. Rather than ship a dead tab, the ENTRY POINT is commented out here and
/// everything behind it — `features/ringtones/**`, `shell/app_shell.dart`, the
/// `ringtone*` ARB keys, the worker's ringtone catalog scope — is left intact
/// and still type-checked, so Dart tree-shakes it out of the build instead.
/// With one browse surface left there is nothing for the dock to switch
/// between, so /browse is a plain top-level route for now and the reel reclaims
/// the space the dock held. Restoring is this file only:
/// docs/reference/ringtones-parked/README.md (incl. dock screenshots).
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
    // RINGTONES-PARKED: the feed stands alone until ringtones ship, so it needs
    // no shell. Delete this route and uncomment the block below to un-park.
    GoRoute(path: '/browse', builder: (_, _) => const FeedScreen()),
    // StatefulShellRoute.indexedStack(
    //   builder: (_, _, navigationShell) =>
    //       AppShell(navigationShell: navigationShell),
    //   branches: [
    //     StatefulShellBranch(
    //       routes: [
    //         GoRoute(path: '/browse', builder: (_, _) => const FeedScreen()),
    //       ],
    //     ),
    //     StatefulShellBranch(
    //       routes: [
    //         GoRoute(
    //           path: '/ringtones',
    //           builder: (_, _) => const RingtonesScreen(),
    //         ),
    //       ],
    //     ),
    //   ],
    // ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(
      path: '/settings/notifications',
      builder: (_, _) => const NotificationSettingsScreen(),
    ),
    GoRoute(path: '/refer', builder: (_, _) => const ReferScreen()),
    GoRoute(path: '/upload', builder: (_, _) => const UploadScreen()),
    GoRoute(
      path: '/premium',
      // `source` is the blocked verb that sent the user here (apply / share /
      // ringtone_set / feed / settings). Tracking happens at the GATE, not
      // here: `ensurePremium` fires `${source}_blocked_premium` before it
      // pushes this route. PremiumScreen only displays/attributes it.
      builder: (_, state) => PremiumScreen(
        source: state.uri.queryParameters['source'] ?? 'unknown',
      ),
    ),
    // Settings → Arul Premium. Distinct from /premium (the paywall): this is the
    // account's plan home and the ONLY route that can cancel a subscription.
    GoRoute(
      path: '/premium/manage',
      builder: (_, _) => const ManageSubscriptionScreen(),
    ),
  ],
);
