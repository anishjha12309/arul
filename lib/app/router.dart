import 'package:go_router/go_router.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import '../features/wallpapers/presentation/browse_screen.dart';

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
    GoRoute(path: '/browse', builder: (_, _) => const BrowseScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/upload', builder: (_, _) => const UploadScreen()),
    GoRoute(
      path: '/premium',
      // `source` is the blocked verb that sent the user here (apply / share /
      // feed / settings). Phase 4 forwards it to AnalyticsService.
      builder: (_, state) => PremiumScreen(
        source: state.uri.queryParameters['source'] ?? 'unknown',
      ),
    ),
  ],
);
