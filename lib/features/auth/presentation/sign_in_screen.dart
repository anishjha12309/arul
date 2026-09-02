import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../theme/arul_tokens.dart';
import '../../legal/presentation/policy_screen.dart';
import '../domain/auth_service.dart';
import '../providers/auth_providers.dart';
import 'widgets/video_background.dart';

/// Sign-in.
///
/// This IS a wall, deliberately (owner's call) — every signed-out session lands here, no skip.
/// Browse and preview being free (§5) is about the MEDIA gate, not about reaching the feed unauthed.
/// **PHASE CONTRACT:** the screen AUTO-LAUNCHES a Google credential request on its FIRST FRAME.
/// That request is SHEET-FIRST — Credential Manager bottom sheet, then the button flow (SIWG guide).
/// The wall only works because a surface appears without a tap -> never a silent, no-UI check.
/// ONE visible Google surface per attempt -> the picker follows only when the sheet drew NOTHING.
/// A sheet run as a WARM-UP ahead of a picker stays forbidden — it appeared, hung and vanished.
/// The pill is the button flow — Google's fallback for a dismissed sheet, no accounts, or re-auth.
/// A tap therefore SKIPS the sheet.
/// Generic "Continue with Google" copy, never a named identity — the account choice is Google's.
/// The background player is SHARED with the splash -> arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  /// Warmth, not instruction and not a feature list — [_tagline] and the pill already do those jobs.
  /// A caption that restated either read as three lines saying one thing.
  /// Keep it SHORT — the silk panel leaves ~284pt on a 360dp phone, past which it wraps to two lines.
  /// It says nothing about the trial on purpose: that is a billing detail, stated on `/premium`.
  static const _caption = 'Bring the divine home';

  /// The splash's eyebrow, repeated so the two brand beats read as one handoff.
  /// Same string, same [ArulTokens.tagline] — change one and you must change the other.
  static const _tagline = 'DEVOTIONAL WALLPAPERS & RINGTONES';

  bool _signingIn = false;

  /// Once any attempt ends without a session, the pill's subtitle flips to a retry nudge.
  ///
  /// A cancel stays TOAST-less — half of "cancels" are GMS-side aborts the user never chose.
  /// A silent bounce to an unchanged screen read as "nothing happened" -> the subtitle is the middle.
  /// NEVER auto-relaunch on a cancel — the Credential Manager guide forbids retrying the request.
  bool _retryNudge = false;

  @override
  void initState() {
    super.initState();
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

  /// [auto] is the first-frame launch — it JOINS whatever the splash started, never a second picker.
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
        setState(() => _retryNudge = true);
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
        case AuthCancelled():
          // No toast, but not a silent bounce -> the subtitle flips to the retry nudge.
          _retryNudge = true;
        case AuthFailure(:final message):
          // Localized-enough surface + retry (the pill), never a stuck spinner.
          showArulToast(context, message, kind: ToastKind.error);
          _retryNudge = true;
      }
      // Handled live here -> drop the recorded copy, or a later mount replays a seen failure.
      notifier.takePendingAutoFailure();
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

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

            // Wordmark and tagline are the only things on bare artwork -> the only over-media shadows.
            // The scrim is only ~.29 this far down, which a bright sky walks straight through.
            Positioned(
              left: 0,
              right: 0,
              top: 112,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Arul',
                    textAlign: TextAlign.center,
                    style: ArulTokens.wordmarkSignIn.copyWith(
                      shadows: ArulTokens.overMediaShadow,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // At .42em the eyebrow measures ~364 and a 360dp phone breaks it over two lines.
                  // Two lines read as a heading, not a tracked rule of type -> shrink, never wrap.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _tagline,
                        maxLines: 1,
                        style: ArulTokens.tagline.copyWith(
                          shadows: ArulTokens.overMediaShadow,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Everything readable or tappable sits on the panel -> legibility ignores the frame behind.
            // The artwork above and below stays uncovered — the whole point of a video back there.
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _SilkPanel(
                  children: [
                    Text(
                      _caption,
                      textAlign: TextAlign.center,
                      style: ArulTokens.body.copyWith(
                        color: ArulTokens.ivory.withValues(alpha: 0.8),
                      ),
                    ),
                    // The only place the app narrates the wait -> it may claim only a wait it OWNS.
                    // Everything up to the credential happens under Google's surface.
                    ValueListenableBuilder<bool>(
                      valueListenable: SignInPhase.exchanging,
                      builder: (context, exchanging, _) => _SignInPill(
                        title: 'Continue with Google',
                        subtitle: exchanging
                            ? 'Signing you in…'
                            : _retryNudge
                            ? "Didn't go through? Tap to try again"
                            : 'Choose an account to get started',
                        onTap: _signingIn ? () {} : _onPillTap,
                        busy: _signingIn,
                      ),
                    ),
                    const _TermsPrivacyLine(),
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

/// The one-tap pill: 56px, r999, `rgba(20,9,12,.55)` fill, gold-50% border, solid gold on press.
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
    return GestureDetector(
      onTapDown: (_) {
        ArulHaptics.tap();
        _setPressed(true);
      },
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Container(
        height: ArulTokens.signInPillHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
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
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ArulTokens.ivory,
                    ),
                  ),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: ArulTokens.ivory.withValues(alpha: 0.6),
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
  const _SilkPanel({required this.children});

  final List<Widget> children;

  static final _radius = BorderRadius.circular(ArulTokens.cardRadius);

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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
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

/// 'Terms · Privacy', 11px, faint ivory, gold-85% links.
///
/// A [TapGestureRecognizer] must be owned and disposed by a stateful widget or it leaks.
/// So this is a Row of two tappable children, not one `Text.rich` with spans.
/// 11px glyphs are far too small to aim at -> the padding below is the TAP TARGET, not spacing.
class _TermsPrivacyLine extends StatelessWidget {
  const _TermsPrivacyLine();

  @override
  Widget build(BuildContext context) {
    // This sits on the silk panel, not the wallpaper -> a shadow on a solid ground reads as fuzz.
    return const Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _PolicyLink(label: 'Terms', doc: PolicyDoc.terms),
        Text(' · ', style: _policyBase),
        _PolicyLink(label: 'Privacy', doc: PolicyDoc.privacy),
      ],
    );
  }
}

const _policyBase = TextStyle(
  fontSize: 11,
  color: Color.fromRGBO(250, 245, 236, 0.5),
);
const _policyLink = TextStyle(
  fontSize: 11,
  color: Color.fromRGBO(212, 160, 23, 0.85),
);

/// One policy link, opening the in-app reader.
///
/// The same pages are linked from the Settings footer and named in the Play listing.
/// Three copies of a policy URL is how one goes stale -> the URLs come from [AppConfig]/[PolicyDoc].
class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.label, required this.doc});

  final String label;
  final PolicyDoc doc;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.tap(),
        // Pushed OVER this screen and popping back -> sign-in is never left behind in another app.
        // Safe mid-auth: the one-shot authenticate() already launched, and returning does not re-arm.
        onTap: () => context.push(doc.route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          child: Text(label, style: _policyLink),
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
