import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_hairline_loader.dart';
import '../../../app/widgets/arul_spinner.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../theme/arul_tokens.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';
import '../providers/auth_providers.dart';
import 'widgets/launch_backdrop.dart';

const double _kCaptionSize = 15;

const double _kSubtitleSize = 13;

/// The pill's MINIMUM height at this type size. It still grows past it whenever the subtitle wraps.
const double _kPillMinHeight = 64;

const double _kPanelRadius = 23;
const double _kPanelPadY = 25;

/// This IS a wall, deliberately (owner's call) — every signed-out session lands here, no skip.
/// Generic "Continue with Google" copy, never a named identity — the account choice is Google's.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({
    super.key,
    this.debugOutcome,
    this.debugWaitingForInternet = false,
  });

  /// Renders the screen as if an attempt had just ended this way, without running one.
  /// The l10n and size matrices pump every outcome through here; nothing else may set it.
  @visibleForTesting
  final SignInOutcome? debugOutcome;

  /// Renders the wait line of a launch held for the network, for the same two matrices.
  @visibleForTesting
  final bool debugWaitingForInternet;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen>
    with WidgetsBindingObserver {
  bool _signingIn = false;

  /// What the last ended-without-a-session attempt actually did, or null while nothing has failed.
  /// A cancel stays TOAST-less — half of "cancels" are GMS-side aborts the user never chose.
  SignInOutcome? _outcome;

  /// The first frame's own `_signIn` has answered: joined an attempt, or found none to run. Until
  /// then the wall shows nothing, or a splash-started attempt flashed the box before hiding it.
  late bool _decided;

  @override
  void initState() {
    super.initState();
    _outcome = widget.debugOutcome;
    _decided = !(AppConfig.hasBackend && AppConfig.googleAuthConfigured);
    WidgetsBinding.instance.addObserver(this);
    _watchConnectivity();
    _initAutoLaunch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The wall's lifecycle feed. The DECISION is the controller's — this only supplies transitions
  /// and joins whatever it re-arms, so the toast and the route stay on [_signIn] alone.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (ref.read(authControllerProvider.notifier).noteAppLifecycle(state)) {
      unawaited(_signIn(auto: true));
    }
  }

  /// The wall's connectivity feed, beside the lifecycle one and with the same contract: it reports
  /// readings, the controller owns the rule, and the screen joins whatever that re-arms.
  void _watchConnectivity() {
    // listenManual reports CHANGES only -> a wall that mounts already offline must record that
    // itself, or the link coming back is not a transition and the reconnect never fires.
    if (_knownOffline) {
      ref.read(authControllerProvider.notifier).noteConnectivity(online: false);
    }
    ref.listenManual(isOnlineProvider, (_, next) {
      final online = next.value;
      if (online == null) return;
      if (ref
          .read(authControllerProvider.notifier)
          .noteConnectivity(online: online)) {
        unawaited(_signIn(auto: true));
      }
    });
  }

  void _initAutoLaunch() {
    BootTrace.mark('signIn screen: initState');
    // The guard is defensive — both defines are always set in shipped builds.
    // A define-less run has nothing to authenticate against -> skip it, the pill passes through.
    if (AppConfig.hasBackend && AppConfig.googleAuthConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        BootTrace.mark('signIn screen: first frame → auto-launch');
        _signIn(auto: true);
      });
    }
  }

  /// [auto] is the first-frame launch, or the one a return re-armed — it JOINS whatever the splash
  /// started, never a second picker.
  /// It does nothing at all once that one attempt has been spent and dismissed.
  /// [auto] false is the pill, which may always start a fresh attempt.
  Future<void> _signIn({bool auto = false}) async {
    if (_signingIn) return;
    final notifier = ref.read(authControllerProvider.notifier);
    if (!auto && _knownOffline && !await _linkUpNow()) {
      if (!mounted) return;
      // Offline, Google's picker only fails (`[16] Account reauth failed`) -> park the tap; the link
      // coming back opens the picker by itself.
      notifier.holdTapForNetwork();
      setState(() => _decided = true);
      return;
    }
    if (!mounted) return;
    final pending = auto
        ? notifier.autoSignIn(AuthProvider.google, offline: _knownOffline)
        : notifier.signIn(AuthProvider.google);
    // Auto-launch already spent, or HELD for the network.
    // A fast failure can settle on the splash with nothing awaiting it -> surface it NOW.
    // The contract is a message plus retry, never a silent bounce; a cancel stays quiet.
    if (pending == null) {
      final missed = notifier.takePendingAutoFailure();
      if (!mounted) return;
      if (missed != null) {
        showArulToast(
          context,
          authFailureText(AppLocalizations.of(context), missed.kind),
          kind: ToastKind.error,
        );
        _outcome = _outcomeForFailure(missed.kind);
      }
      // A held launch swaps the subtitle for the wait line; the rebuild picks it up.
      setState(() => _decided = true);
      return;
    }

    setState(() {
      _signingIn = true;
      _decided = true;
    });
    var succeeded = false;
    try {
      final result = await pending;
      if (!mounted) return;
      switch (result) {
        case AuthSuccess():
          succeeded = true;
          context.go('/browse');
        case AuthCancelled(:final outcome):
          _outcome = outcome;
        case AuthFailure(:final kind):
          showArulToast(
            context,
            authFailureText(AppLocalizations.of(context), kind),
            kind: ToastKind.error,
          );
          _outcome = _outcomeForFailure(kind);
      }
      // Handled live here -> drop the recorded copy, or a later mount replays a seen failure.
      notifier.takePendingAutoFailure();
    } finally {
      // A success keeps the hairline running while the route leaves -> the box never returns on the way out.
      if (mounted && !succeeded) setState(() => _signingIn = false);
    }
  }

  /// True only on a KNOWN `none` transport reading. Loading or errored is online, exactly as the
  /// provider seeds it: the sheet is held only when the phone certainly has no network.
  bool get _knownOffline => ref.read(isOnlineProvider).value == false;

  /// A fresh transport read for a tap the stream calls offline -> a stale stream can never leave the
  /// pill parked on a phone that has its network back. A failed read proves nothing: go.
  Future<bool> _linkUpNow() async {
    try {
      final results = await ref.read(connectivityProvider).checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  /// A visible failure already toasted its own message; the screen shows the same retry line as any
  /// other outcome, so this only classifies for `login_cancelled` — `noPlayServices` is the one
  /// failure with no provider to ask, and the toast is where that is said.
  SignInOutcome _outcomeForFailure(AuthFailureKind kind) =>
      kind == AuthFailureKind.noPlayServices
      ? SignInOutcome.noProvider
      : SignInOutcome.backedOutQuick;

  void _onPillTap() {
    if (!AppConfig.hasBackend || !AppConfig.googleAuthConfigured) {
      // Unreachable in shipped builds — both defines are always set.
      // For define-less runs: browse is free and there is no Worker to exchange with -> pass through.
      context.go('/browse');
      return;
    }
    _signIn();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final waiting =
        widget.debugWaitingForInternet ||
        (!_signingIn &&
            ref.read(authControllerProvider.notifier).heldForNetwork);
    final subtitle = _subtitleFor(l10n, _outcome, waiting: waiting);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Always-dark surface: status/nav icons stay light in both themes.
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0x00000000),
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ArulTokens.darkSurface,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Same backdrop as the splash (shared player, or the regional poster); our own scrim below.
            const LaunchBackdrop(),

            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.signInScrim),
            ),

            // The wordmark is the only thing on bare artwork -> the only over-media shadow.
            // The scrim is only ~.29 this far down, which a bright sky walks straight through.
            Positioned(
              left: 0,
              right: 0,
              top: 112,
              child: Text(
                'Arul',
                textAlign: TextAlign.center,
                style: ArulTokens.wordmarkSignIn.copyWith(
                  shadows: ArulTokens.overMediaShadow,
                ),
              ),
            ),

            // Everything readable or tappable sits on the panel -> legibility ignores the frame behind.
            // The artwork above and below stays uncovered — the whole point of a video back there.
            _FadeGate(
              shown: wallShowsBox(decided: _decided, inFlight: _signingIn),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _SilkPanel(
                    key: kSignInPanelKey,
                    children: [
                      // Warmth, not instruction and not a feature list — the eyebrow and the pill
                      // already do those jobs, and a caption restating either read as three lines
                      // saying one thing. It says nothing about the trial on purpose: a billing
                      // detail, stated on `/premium`.
                      Text(
                        l10n.signInCaption,
                        textAlign: TextAlign.center,
                        style: ArulTokens.body.copyWith(
                          fontSize: _kCaptionSize,
                          color: ArulTokens.ivory.withValues(alpha: 0.8),
                        ),
                      ),
                      _SignInPill(
                        title: l10n.signInGoogle,
                        subtitle: subtitle,
                        onTap: _signingIn ? () {} : _onPillTap,
                        busy: _signingIn,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // The splash's hairline, on the splash's spot, for the WHOLE attempt: under Google's
            // screens too, so the gaps between them never read as a dead wall.
            Positioned(
              left: 0,
              right: 0,
              bottom: 64,
              child: _FadeGate(
                shown: _signingIn,
                child: const Center(child: ArulHairlineLoader()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The box shows only while no attempt runs: a pill aimed at through Google's sheet closed the
/// sheet (sign-in-wall.md), and the waits between Google's screens read as the splash's hairline.
@visibleForTesting
bool wallShowsBox({required bool decided, required bool inFlight}) =>
    decided && !inFlight;

class _FadeGate extends StatefulWidget {
  const _FadeGate({required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  State<_FadeGate> createState() => _FadeGateState();
}

class _FadeGateState extends State<_FadeGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    value: widget.shown ? 1 : 0,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 120),
  );

  @override
  void didUpdateWidget(_FadeGate old) {
    super.didUpdateWidget(old);
    if (widget.shown == old.shown) return;
    if (widget.shown) {
      _fade.forward();
    } else {
      _fade.reverse();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  // TickerMode stops a hidden hairline's loop; it resumes the moment the gate opens.
  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.shown,
    child: ExcludeSemantics(
      excluding: !widget.shown,
      child: TickerMode(
        enabled: widget.shown,
        child: FadeTransition(opacity: _fade, child: widget.child),
      ),
    ),
  );
}

const TextStyle kSignInTitleStyle = TextStyle(
  fontSize: 17,
  fontWeight: FontWeight.w600,
  color: ArulTokens.ivory,
);

/// The silk panel — the one surface the wall puts anything on, and what the size matrix measures.
@visibleForTesting
const Key kSignInPanelKey = Key('signIn.panel');

/// The pill's title box. Its CONSTRAINTS are the real slot; a child wider than the box it was given
/// is a title the safety net had to scale, which the size matrix forbids at text scale 1.0.
@visibleForTesting
const Key kSignInTitleKey = Key('signIn.pill.title');

/// The pill's subtitle line. The size matrix lays it out at its own constraints and counts lines:
/// at most two at text scale 1.0 and three at 1.3, in every language, never a truncation.
@visibleForTesting
const Key kSignInSubtitleKey = Key('signIn.pill.subtitle');

/// The wait line outranks both others: while the launch is held, nothing has been tried yet, and the
/// sheet opens by itself the moment the network is back. It says only that — never a fix to make.
String _subtitleFor(
  AppLocalizations l10n,
  SignInOutcome? outcome, {
  bool waiting = false,
}) => waiting
    ? l10n.signInSubtitleOffline
    : outcome == null
    ? l10n.signInSubtitleIdle
    : l10n.signInNudgeRetry;

class _SignInPill extends StatefulWidget {
  const _SignInPill({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// In flight the trailing arrow becomes a spinner -> the post-picker Worker verify is not silent.
  final bool busy;

  @override
  State<_SignInPill> createState() => _SignInPillState();
}

class _SignInPillState extends State<_SignInPill> {
  static const _pillFill = Color.fromRGBO(20, 9, 12, 0.55);

  bool _pressed = false;

  void _setPressed(bool v) => setState(() => _pressed = v);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      identifier: 'arul_signin_pill',
      button: true,
      label: '${widget.title}. ${widget.subtitle}',
      onTap: widget.busy ? null : widget.onTap,
      // Without this the title's own auto-merged tap node and this one both carry the action —
      // the wall's "pill is the ONLY tappable thing" contract catches a second stop otherwise.
      excludeSemantics: true,
      child: _pill(context),
    );
  }

  Widget _pill(BuildContext context) {
    return GestureDetector(
      // In flight the pill is inert: no dip, no haptic, no second attempt from a repeat tap. The
      // spinner in the trailing slot is the whole answer to a finger that lands here.
      onTapDown: widget.busy
          ? null
          : (_) {
              ArulHaptics.tap();
              _setPressed(true);
            },
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.busy ? null : widget.onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: _kPillMinHeight),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: _pillFill,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          border: Border.all(
            color: _pressed ? ArulTokens.gold : ArulTokens.goldBorder50,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: ArulTokens.ivory,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const _GoogleGMark(size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    key: kSignInTitleKey,
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      style: kSignInTitleStyle,
                    ),
                  ),
                  Semantics(
                    container: true,
                    identifier: 'arul_signin_subtitle',
                    label: widget.subtitle,
                    excludeSemantics: true,
                    child: Text(
                      widget.subtitle,
                      key: kSignInSubtitleKey,
                      maxLines: 4,
                      style: TextStyle(
                        fontSize: _kSubtitleSize,
                        color: ArulTokens.ivory.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: ArulSpinner(
                  size: 20,
                  strokeWidth: 2.2,
                  color: ArulTokens.gold,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(
                  Icons.arrow_forward,
                  size: 22,
                  color: ArulTokens.gold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The silk panel: the one surface everything readable or tappable sits on.
/// Two ordinary paints — [ArulTokens.mediaFillStrong] as the ground, [ArulTokens.silkDark] over it.
class _SilkPanel extends StatelessWidget {
  const _SilkPanel({super.key, required this.children});

  final List<Widget> children;

  static final _radius = BorderRadius.circular(_kPanelRadius);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArulTokens.mediaFillStrong,
        borderRadius: _radius,
        border: Border.all(color: ArulTokens.goldBorder40, width: 1),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: ArulTokens.silkDark,
          borderRadius: _radius,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: _kPanelPadY,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 13),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The Google "G" — Google's OWN asset, NEVER a redraw.
/// The branding guidelines require the standard colour version, unchanged in size or colour.
/// "Create your own icon for the button" is listed under Don't.
class _GoogleGMark extends StatelessWidget {
  const _GoogleGMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/google_g.webp',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    );
  }
}

/// The wall's failure toast in the app's language. Exhaustive: a new kind without a line is a
/// compile error, never a silent English fallback.
@visibleForTesting
String authFailureText(AppLocalizations l10n, AuthFailureKind kind) =>
    switch (kind) {
      AuthFailureKind.noPlayServices => l10n.authErrorNoPlayServices,
      AuthFailureKind.networkError => l10n.authErrorNetwork,
      AuthFailureKind.tokenExchangeFailed => l10n.authErrorTokenExchange,
      AuthFailureKind.serverError => l10n.authErrorServer,
      AuthFailureKind.unknown => l10n.authErrorIncomplete,
    };
