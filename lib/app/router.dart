import 'package:go_router/go_router.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/premium/presentation/manage_subscription_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/referral/presentation/refer_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import '../features/wallpapers/presentation/feed_screen.dart';

/// Routes.
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
    GoRoute(path: '/browse', builder: (_, _) => const FeedScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/refer', builder: (_, _) => const ReferScreen()),
    GoRoute(path: '/upload', builder: (_, _) => const UploadScreen()),
    GoRoute(
      path: '/premium',
      // `source` is the blocked verb that sent the user here (apply / share /
      // feed / settings). Phase 4 forwards it to AnalyticsService.
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
