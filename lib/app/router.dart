import 'package:go_router/go_router.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
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
/// Auth flow is unchanged: splash decides (loading → stays here, unauthed →
/// /sign-in, authed → /browse) — imperatively, exactly as before the shell.
///
/// /browse and /ringtones live inside a [StatefulShellRoute.indexedStack] —
/// the two bottom-bar tabs, both kept alive across switches (the shell pauses
/// whichever media system just hid; see [AppShell]). Everything else
/// (/settings, /refer, /upload, /premium…) stays a full-screen push OUTSIDE
/// the shell, so those screens cover the bottom bar.
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
    StatefulShellRoute.indexedStack(
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
      ],
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/refer', builder: (_, _) => const ReferScreen()),
    GoRoute(path: '/upload', builder: (_, _) => const UploadScreen()),
    GoRoute(
      path: '/premium',
      // `source` is the blocked verb that sent the user here (apply / share /
      // ringtone_set / feed / settings). Phase 4 forwards it to
      // AnalyticsService.
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
