import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/deeplink/deep_link_parser.dart';
import '../core/deeplink/deep_link_target.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/legal/presentation/policy_screen.dart';
import '../features/premium/presentation/premium_screen.dart';
import '../features/ringtones/presentation/ringtones_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/status/presentation/status_screen.dart';
import '../features/upload/presentation/upload_screen.dart';
import '../features/wallpapers/presentation/feed_screen.dart';
import 'push_route.dart';
import 'shell/app_shell.dart';
import 'shell/shell_route_observer.dart';
import 'theme/theme.dart';

/// Every push goes through [ArulPushPage] -> read its doc before writing a pageBuilder here: a
/// plain `CustomTransitionPage` opts the route out of predictive back.
final router = GoRouter(
  initialLocation: '/',
  // A reel under a pushed screen must stop decoding and fall silent -> the shell is RouteAware.
  observers: [shellRouteObserver],
  // Incoming links — the installed half of every ad/share URL (docs/deep-links.md).
  // Meta's form has no path -> normalises to `/` -> redirect top-level, or it runs on every nav.
  // The PhonePe `arul://` return parses to nothing and resolves to `/` -> keep it that way.
  redirect: (_, state) {
    if (state.uri.scheme.isEmpty) return null;
    final request = parseDeepLinkUri(state.uri, source: DeepLinkSource.appLink);
    if (request != null) {
      final target = request.target;
      if (target != null) {
        // `/` rebuilds the shell -> the one on screen now must not take what the next one will show.
        ArulDeepLink.deferToNextShell();
        ArulDeepLink.requestTarget(target);
      }
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
    GoRoute(path: '/s/:id', redirect: (_, _) => '/'),
    StatefulShellRoute(
      // Not .indexedStack -> branches go through ArulBranchCrossfade -> a tab switch dissolves, never cuts.
      navigatorContainerBuilder: (_, navigationShell, children) =>
          ArulBranchCrossfade(
            currentIndex: navigationShell.currentIndex,
            children: children,
          ),
      builder: (_, _, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      // Indexed by `AppShell.*Branch` -> a new tab is one branch here, its constant and its dock item.
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
        // Always declared -> go_router's branch list is fixed; the remote flag hides the DOCK item.
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/status', builder: (_, _) => const StatusScreen()),
          ],
        ),
      ],
    ),
    // Pushed OVER the shell from the header gear -> the dock never paints across it.
    GoRoute(
      path: '/settings',
      pageBuilder: (_, state) => _push(state, const SettingsScreen()),
    ),
    GoRoute(
      path: '/upload',
      pageBuilder: (_, state) => _push(state, const UploadScreen()),
    ),
    // Pushed OVER the shell, like Settings that links to it.
    // Push it with `PolicyDoc.route`, never a literal path.
    GoRoute(
      path: '/policy/:doc',
      pageBuilder: (_, state) => _push(
        state,
        PolicyScreen(doc: PolicyDoc.fromSlug(state.pathParameters['doc'])),
      ),
    ),
    GoRoute(
      path: '/premium',
      // `ensurePremium` fires `${source}_blocked_premium` at the GATE before pushing -> never track here.
      // Sheets and dialogs inherit theme from the SCREEN's context, above anything its build wraps.
      // A Theme inside the screen left the UPI picker sheet dark -> pin LIGHT at the ROUTE level.
      pageBuilder: (_, state) => _push(
        state,
        Theme(
          data: ArulTheme.light(),
          child: PremiumScreen(
            source: state.uri.queryParameters['source'] ?? 'unknown',
          ),
        ),
      ),
    ),
  ],
);

/// go_router's own default page carries key, name, arguments and a restoration id -> a page built
/// here owes the same four, or a route silently loses its restoration scope.
ArulPushPage<void> _push(GoRouterState state, Widget child) =>
    ArulPushPage<void>(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: <String, String>{
        ...state.pathParameters,
        ...state.uri.queryParameters,
      },
      restorationId: state.pageKey.value,
      child: child,
    );
