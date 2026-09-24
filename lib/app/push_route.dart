import 'package:flutter/material.dart';

import 'theme/motion.dart';

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
    with MaterialRouteTransitionMixin<T>, _ArulPushMotion<T> {
  _ArulPushRoute({required ArulPushPage<T> page}) : super(settings: page);

  ArulPushPage<T> get _page => settings as ArulPushPage<T>;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

/// [ArulPushPage]'s route for an IMPERATIVE push — a screen that belongs to the one below it and
/// has no URL of its own (the paywall's return page). Same motion, same predictive back, because
/// both share [_ArulPushMotion]; go_router pops it like any pageless route.
class ArulPushRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T>, _ArulPushMotion<T> {
  ArulPushRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  bool get maintainState => true;
}

/// The timing, the reduced-motion branch and the outgoing delegate every Arul push shares.
mixin _ArulPushMotion<T> on MaterialRouteTransitionMixin<T> {
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
