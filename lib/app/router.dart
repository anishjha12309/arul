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
import 'theme/motion.dart';
import 'theme/theme.dart';

/// Routes.
///
/// Splash decides imperatively: loading stays -> unauthed goes /sign-in -> authed goes /browse.
/// Wallpapers · Ringtones · Settings are always-alive dock BRANCHES -> Settings is never a push.
/// Their sub-screens (notifications, premium, refer, upload) stay top-level pushes OVER the shell.
/// Every push goes through [ArulPushPage] -> read its doc before writing a pageBuilder here: a
/// plain `CustomTransitionPage` opts the route out of predictive back.
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
      pageBuilder: (_, state) =>
          _push(state, const EnglishOnly(child: NotificationSettingsScreen())),
    ),
    GoRoute(
      path: '/refer',
      pageBuilder: (_, state) => _push(state, const ReferScreen()),
    ),
    // Whole-screen English (EnglishOnly doc): four upload keys are demoted.
    GoRoute(
      path: '/upload',
      pageBuilder: (_, state) =>
          _push(state, const EnglishOnly(child: UploadScreen())),
    ),
    // Privacy / Terms, read in-app.
    // Pushed OVER the shell -> the Settings branch's own dock does not paint across it.
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
      // THE premium route — paywall AND plan home in one screen, rendering the real subscription state.
      // `source` is the blocked verb that sent the user here: apply/share/ringtone_set/feed/settings.
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

/// The page every pushed route builds.
///
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

/// A pushed screen: the theme's page transition, with ONE branch of our own for reduced motion.
///
/// **Predictive back rides on [MaterialRouteTransitionMixin] and nothing else.** The theme's
/// `PredictiveBackPageTransitionsBuilder` is reached only through it, and that builder is what
/// mounts the observer Android's back gesture talks to — a route that supplies its own
/// `transitionsBuilder` (go_router's `CustomTransitionPage`) never mounts it, so the swipe still
/// pops but the page behind it no longer previews. Measured on Flutter 3.44: the pushed page sits
/// at dx 0 for the whole drag instead of riding out to 24.8. The same swap also silences the route
/// BELOW, because `canTransitionTo` refuses a next route that is neither this mixin nor a delegate.
/// So the shared-axis push stays the theme's `FadeForwardsPageTransitionsBuilder` — the slide+fade
/// Android 16 itself uses — and only its TIMING is ours.
class ArulPushPage<T> extends Page<T> {
  const ArulPushPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _ArulPushRoute<T>(page: this);
}

class _ArulPushRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _ArulPushRoute({required ArulPushPage<T> page}) : super(settings: page);

  ArulPushPage<T> get _page => settings as ArulPushPage<T>;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';

  /// The theme's builder asks for 450ms — Android 16's own number, standing in for springs Flutter
  /// stable does not have. The house's page-level reveal is [Motion.enter].
  /// Safe against the back gesture: the DRAG is driven by the gesture's own progress, not by this
  /// duration (the preview measures identically at 450 and at 300); only the commit settles sooner.
  @override
  Duration get transitionDuration => Motion.enter;

  @override
  Duration get reverseTransitionDuration => Motion.enter;

  /// Reduced motion: a plain fade, and the page under it holds still (see [_pushedDelegate]).
  /// Nothing translates, so a phone that turns battery saver on mid-session sees no re-layout.
  /// This branch is also the one place predictive back is given up — an unmounted observer is the
  /// price of not sliding — and the gesture still pops, the binding falls back to a plain pop.
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (context.reduceMotion) {
      return FadeTransition(
        opacity: animation.drive(CurveTween(curve: Motion.enterCurve)),
        child: child,
      );
    }
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }

  /// How the route BELOW this one animates out.
  ///
  /// A plain tear-off, never a closure: `didChangeNext` compares this against the lower route's own
  /// delegate by identity, and a fresh closure each read makes it adopt ours — which then suppresses
  /// the lower route's secondary animation and freezes the shell mid-push.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => _pushedDelegate;
}

/// The shell's outgoing slide, and its absence under reduced motion.
///
/// Returning [child] untouched is what holds the page below still; the animated arm is the theme
/// builder's own delegate, so a normal push looks exactly as it did before this page existed.
Widget? _pushedDelegate(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  bool allowSnapshotting,
  Widget? child,
) {
  if (context.reduceMotion) return child;
  return const FadeForwardsPageTransitionsBuilder().delegatedTransition!(
    context,
    animation,
    secondaryAnimation,
    allowSnapshotting,
    child,
  );
}
