import 'package:go_router/go_router.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/notifications/presentation/notification_settings_screen.dart';
import '../features/premium/presentation/manage_subscription_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/referral/presentation/refer_screen.dart';
import '../features/ringtones/presentation/ringtones_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import '../features/wallpapers/presentation/feed_screen.dart';
import 'shell/app_shell.dart';

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
