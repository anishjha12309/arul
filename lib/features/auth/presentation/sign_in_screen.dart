import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../theme/arul_tokens.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';
import '../providers/auth_providers.dart';
import 'widgets/video_background.dart';

/// The wall's caption.
///
/// Google's own credential sheet lands ON this screen, drawn by GMS and unstyled by us: ~16sp
/// account rows under a ~22sp title. Beside it the panel's older 13.5/15/12 read a size small, so
/// the whole panel is set one step up (owner's call). Flat numbers on every phone — a translation
/// that outgrows its slot is handled where it happens, not by shrinking the screen.
const double _kCaptionSize = 15;

/// The pill's subtitle, one step under the title.
const double _kSubtitleSize = 13;

/// The pill's MINIMUM height at this type size. It still grows past it whenever the subtitle wraps.
const double _kPillMinHeight = 64;

/// The panel's corner and vertical padding, opened up with the type so the bigger lines are not
/// crowded against the edges. Horizontal padding stays at 18: every dp of it comes straight out of
/// the pill's text slot.
const double _kPanelRadius = 23;
const double _kPanelPadY = 25;

/// Sign-in.
///
/// This IS a wall, deliberately (owner's call) — every signed-out session lands here, no skip.
/// Browse and preview being free (§5) is about the MEDIA gate, not about reaching the feed unauthed.
/// **PHASE CONTRACT:** the screen AUTO-LAUNCHES a Google credential request on its FIRST FRAME,
/// and once more when the app RETURNS to this wall after an away stretch (never after a cancel on
/// the same foreground stretch) — the rule is [AuthController.noteAppLifecycle]'s, not the screen's.
/// That request is SHEET-FIRST — Credential Manager bottom sheet, then the button flow (SIWG guide).
/// The wall only works because a surface appears without a tap -> never a silent, no-UI check.
/// ONE visible Google surface per attempt -> the picker follows only when the sheet drew NOTHING.
/// A sheet run as a WARM-UP ahead of a picker stays forbidden — it appeared, hung and vanished.
/// The pill is the button flow — Google's fallback for a dismissed sheet, no accounts, or re-auth.
/// A tap therefore SKIPS the sheet.
/// **The pill is the ONLY tappable thing on the wall.** Google's sheet covers this screen, so any
/// second control is reached by dismissing the sheet first -> never add one. The language is the
/// REGION's on a first launch and is changed in Settings, never from here.
/// Generic "Continue with Google" copy, never a named identity — the account choice is Google's.
/// The background player is SHARED with the splash -> arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.debugOutcome});

  /// Renders the screen as if an attempt had just ended this way, without running one.
  /// The l10n and size matrices pump every outcome through here; nothing else may set it.
  @visibleForTesting
  final SignInOutcome? debugOutcome;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen>
    with WidgetsBindingObserver {
  bool _signingIn = false;

  /// What the last ended-without-a-session attempt actually did, or null while nothing has failed.
  ///
  /// A cancel stays TOAST-less — half of "cancels" are GMS-side aborts the user never chose.
  /// A silent bounce to an unchanged screen read as "nothing happened" -> the subtitle is the middle.
  /// One line for every cancel was the OTHER failure: "didn't go through, tap again" told a user
  /// whose Play services closed the window nothing they could act on. The line must be true of THIS
  /// attempt, so it is routed off [SignInOutcome] and never off a bool.
  /// NEVER auto-relaunch on a cancel — the Credential Manager guide forbids retrying the request,
  /// and a redrawn One Tap sheet is the fastest way to Google's 24 h suppression. That holds for the
  /// whole foreground stretch a cancel happened in. A RETURN is a different event: the person left
  /// the app and came back, so the wall gets one fresh automatic surface, gated by
  /// [AuthController.noteAppLifecycle] on an away stretch that began AFTER the cancel settled
  /// ([AuthController.returnAwayThreshold]) and on [AuthController.returnCooldown] since it.
  SignInOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _outcome = widget.debugOutcome;
    WidgetsBinding.instance.addObserver(this);
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

  void _initAutoLaunch() {
    BootTrace.mark('signIn screen: initState');
    // CONTRACT: auto-launch the credential request on the FIRST FRAME (initialize → sheet → button).
    // The pill below is the button flow on its own.
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
    final pending = auto
        ? notifier.autoSignIn(AuthProvider.google)
        : notifier.signIn(AuthProvider.google);
    // Auto-launch already spent.
    // A fast failure can settle on the splash with nothing awaiting it -> surface it NOW.
    // The contract is a message plus retry, never a silent bounce; a cancel stays quiet.
    if (pending == null) {
      final missed = notifier.takePendingAutoFailure();
      if (missed != null && mounted) {
        showArulToast(context, missed.message, kind: ToastKind.error);
        setState(() => _outcome = _outcomeForFailure(missed.kind));
      }
      return;
    }

    setState(() => _signingIn = true);
    try {
      final result = await pending;
      if (!mounted) return;
      switch (result) {
        case AuthSuccess():
          context.go('/browse');
        case AuthCancelled(:final outcome):
          // No toast, but not a silent bounce -> the subtitle says what this attempt did.
          _outcome = outcome;
        case AuthFailure(:final message, :final kind):
          // Localized-enough surface + retry (the pill), never a stuck spinner.
          showArulToast(context, message, kind: ToastKind.error);
          _outcome = _outcomeForFailure(kind);
      }
      // Handled live here -> drop the recorded copy, or a later mount replays a seen failure.
      notifier.takePendingAutoFailure();
    } finally {
      if (mounted) setState(() => _signingIn = false);
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
    final subtitle = _subtitleFor(l10n, _outcome);
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
            // Same shared player as splash; we paint our own scrim below.
            const VideoBackground(overlayOpacity: 0),

            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.signInScrim),
            ),

            // The wordmark is the only thing on bare artwork -> the only over-media shadow.
            // The splash keeps the eyebrow under it; the wall does NOT — the panel below now
            // carries the type, and a tracked rule of caps above it read as a third voice.
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
            Center(
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
                    // The only place the app narrates the wait -> it may claim only a wait it OWNS.
                    // Everything up to the credential happens under Google's surface.
                    ValueListenableBuilder<bool>(
                      valueListenable: SignInPhase.exchanging,
                      builder: (context, exchanging, _) => _SignInPill(
                        title: l10n.signInGoogle,
                        subtitle: exchanging
                            ? l10n.signInSubtitleExchanging
                            : subtitle,
                        onTap: _signingIn ? () {} : _onPillTap,
                        busy: _signingIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pill title's type. 19 w600 — the largest thing on the panel and the line Google's own sheet
/// is read beside.
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

/// What the pill says under its title, resolved in ONE place.
///
/// Every failed attempt gets the SAME line. The outcome still rides `AuthCancelled` into
/// `login_cancelled`, but the screen no longer explains it: a sentence naming Play services or
/// account settings, and a link out of the app, were three lines this audience cannot act on
/// (owner's call). The one thing any of them can do is tap again -> that is the whole message.
String _subtitleFor(AppLocalizations l10n, SignInOutcome? outcome) =>
    outcome == null ? l10n.signInSubtitleIdle : l10n.signInNudgeRetry;

/// The one-tap pill: r999, `rgba(20,9,12,.55)` fill, gold-50% border, solid gold on press,
/// [_kPillMinHeight] tall or taller.
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
      child: _pill(context),
    );
  }

  Widget _pill(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        ArulHaptics.tap();
        _setPressed(true);
      },
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Container(
        // A MINIMUM, not a height. A wrapped subtitle, or a script that sets ~40% taller per line
        // (Devanagari) at a large OS text size, does not fit a fixed box. The pill GROWS instead of
        // clipping, and only when the subtitle actually wraps.
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
            // The type is a fixed size and the LAYOUT absorbs a translation that outgrows its
            // slot — the ordinary way a shipped button behaves, not a screen that resizes itself.
            // The two lines absorb it differently, because their jobs differ:
            //   * the TITLE is a button label and must stay ONE line -> scaleDown.
            //   * the SUBTITLE is a sentence -> it WRAPS and the pill grows to hold it.
            // Neither ever truncates and neither is ellipsised.
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
                      // The budget the size matrix pins on the phones people hold: at most TWO
                      // lines at text scale 1.0 and THREE at 1.3, in all six scripts. The fourth is
                      // for the 320dp frame the l10n envelope gates on, where the slot is 140dp and
                      // wrapping is word-bounded — a Malayalam or Tamil sentence is four chunks
                      // there and no three lines can hold it. No ellipsis anywhere: nothing on this
                      // screen truncates, and a nudge half-read is not a nudge.
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
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: ArulTokens.gold,
                  ),
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
///
/// Two ordinary paints — [ArulTokens.mediaFillStrong] as the ground, [ArulTokens.silkDark] over it.
/// NOT a `BackdropFilter`: blur costs ~6–9ms of raster per frame at a usable sigma.
/// On budget SoCs that comes straight out of the video decoder's budget (ui-direction §Perf).
/// Stacked gradients cost nothing and read richer over full-bleed photography anyway.
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
///
/// The branding guidelines require the standard colour version, unchanged in size or colour.
/// "Create your own icon for the button" is listed under Don't.
/// `assets/images/google_g.webp` is Google's own `g-logo.png`, padded square, lossless at 96px.
/// The 20dp slot needs ≤80px even at 4x.
/// It sits on the pill's ivory disc — the guidelines' white-background requirement.
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
