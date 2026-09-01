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
/// This IS a wall, deliberately (owner's call, confirmed 2026-08-23): every
/// signed-out session lands here from the splash and there is no skip
/// affordance. Browse/preview being free (CLAUDE.md §5) is about the MEDIA
/// gate — public keys, no entitlement needed — not about reaching the feed
/// without an account.
///
/// PHASE CONTRACT — do not redesign this away: the real screen AUTO-LAUNCHES a
/// Google credential request on its first frame, and that request is
/// SHEET-FIRST (Google's SIWG guide: Credential Manager bottom sheet, then the
/// button flow). It must never become a silent/no-UI check that leaves the
/// user looking at a dead screen — the wall only works because a surface
/// appears without a tap.
///
/// ONE visible Google surface per attempt: the picker follows the sheet only
/// when the sheet drew NOTHING. A sheet run as a warm-up AHEAD of a picker is a
/// different thing and stays forbidden (measured 2026-08-11: a drawer that
/// appeared, hung and vanished, then the picker). See
/// `ApiAuthService.resolveGoogleCredential`.
///
/// The pill below is the button flow — Google's own fallback for a dismissed
/// sheet, no Google accounts, or accounts needing re-auth. A tap therefore
/// SKIPS the sheet. Generic "Continue with Google" copy, never a named
/// identity: the account choice belongs to Google's own surface.
///
/// The background player is SHARED with the splash — the same live decoder
/// handed across the route — so arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  /// Warmth, not instruction, and not a feature list — both jobs are already
  /// taken on this screen: [_tagline] above says what the app holds, and the
  /// pill below says "Choose an account to get started". A caption that
  /// restated either read as three lines saying one thing.
  ///
  /// Keep it SHORT. The silk panel leaves ~284pt on a 360dp phone, so anything
  /// past that wraps to two lines — which is what retired the previous copy.
  /// It says nothing about the trial on purpose: that is a billing detail, and
  /// `/premium` is where it is stated properly.
  static const _caption = 'Bring the divine home';

  /// The splash's eyebrow, repeated here so the two brand beats read as one
  /// screen handing off to the next. Same string, same [ArulTokens.tagline] —
  /// change one and you must change the other.
  static const _tagline = 'DEVOTIONAL WALLPAPERS & RINGTONES';

  bool _signingIn = false;

  /// Once any attempt ends without a session, the pill's subtitle flips to a
  /// retry nudge. The cancel outcome stays TOAST-less (the user may genuinely
  /// have closed the sheet, and the field data says half of "cancels" are
  /// GMS-side aborts the user never chose — 2026-08-31 diagnosis), but a
  /// silent bounce back to an unchanged screen read as "nothing happened":
  /// the subtitle is the quiet middle ground. Never auto-relaunch on a
  /// cancel — the Credential Manager troubleshooting guide forbids it
  /// ("don't automatically retry the request").
  bool _retryNudge = false;

  @override
  void initState() {
    super.initState();
    BootTrace.mark('signIn screen: initState');
    // CONTRACT: auto-launch the Google credential request on the first frame
    // (v7: instance → initialize() [done in main()] → sheet, then button).
    // The pill below is the button flow on its own.
    // The guard is defensive: both defines are always set in shipped builds.
    // In a define-less local run there is nothing to authenticate against, so
    // auto-launch is skipped and the pill passes through to the feed.
    if (AppConfig.hasBackend && AppConfig.googleAuthConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        BootTrace.mark('signIn screen: first frame → auto-launch');
        _signIn(auto: true);
      });
    }
  }

  /// [auto] = the first-frame launch, which must JOIN whatever the splash
  /// already started rather than open a second picker, and must do nothing at
  /// all if that one attempt has already been spent and dismissed.
  /// [auto] = false is the pill, which may always start a fresh attempt.
  Future<void> _signIn({bool auto = false}) async {
    if (_signingIn) return;
    final notifier = ref.read(authControllerProvider.notifier);
    final pending = auto
        ? notifier.autoSignIn(AuthProvider.google)
        : notifier.signIn(AuthProvider.google);
    // Auto-launch already spent. If it failed while still on the splash (a
    // fast failure can settle before this screen mounts, with nothing awaiting
    // it), surface it NOW — the contract is a message + retry, never a silent
    // bounce. A cancel stays quiet as always; either way the pill remains.
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
          // No toast — but not a silent bounce either: the pill's subtitle
          // flips to the retry nudge (rebuilt by the finally below).
          _retryNudge = true;
        case AuthFailure(:final message):
          // Localized-enough surface + retry (the pill), never a stuck spinner.
          showArulToast(context, message, kind: ToastKind.error);
          _retryNudge = true;
      }
      // This screen just handled the result live — drop the recorded copy so
      // a later mount can't replay a failure the user already saw.
      notifier.takePendingAutoFailure();
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  void _onPillTap() {
    if (!AppConfig.hasBackend || !AppConfig.googleAuthConfigured) {
      // Defensive: unreachable in shipped builds (both defines are always
      // set). Kept for define-less local runs — browse/preview are free and
      // there is no Worker to exchange a token with, so pass through.
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

            // The wordmark + tagline are the only things left floating on bare
            // artwork, so they are the only things that need the over-media
            // shadow — the scrim is only ~.29 this far down, which a bright sky
            // (Murugan, Ayyappan) walks straight through.
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
                  // Shrinks, never wraps: at .42em the eyebrow measures ~364
                  // and a 360dp phone would break it over two lines, which
                  // reads as a heading rather than a tracked rule of type.
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

            // The silk panel, centred. Everything the user must read or tap
            // lives on it, so legibility stops depending on which frame of the
            // wallpaper loop happens to be behind it — and the artwork above
            // and below is left uncovered, which is the whole point of putting
            // a video back there.
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
                    // The subtitle is the only place the app narrates the
                    // wait, and it may only claim a wait it OWNS: everything
                    // up to the credential happens under Google's surface.
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

/// The one-tap pill: 56px, r999, `rgba(20,9,12,.55)` fill, gold-50% border
/// (solid gold on press).
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

  /// While a sign-in is in flight: the trailing arrow becomes a spinner so the
  /// Worker-verify round-trip after the Google picker isn't dead-silent.
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
/// Two ordinary paints, deliberately — [ArulTokens.mediaFillStrong] as an
/// opaque-enough ground, [ArulTokens.silkDark] over it for the maroon→gold
/// weave the premium cards already use. NOT a `BackdropFilter`: blur costs
/// ~6–9ms of raster per frame at a usable sigma, which on the budget SoCs this
/// app targets would come straight out of the video decoder's budget — the
/// same rule that keeps glassmorphism off the dock (docs/ui-direction.md
/// §Perf, `ArulScrims`). Stacked gradients cost nothing and, over full-bleed
/// photography, read richer anyway.
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
/// A Row of two tappable children rather than one `Text.rich` with
/// [TapGestureRecognizer] spans: a recognizer has to be owned and disposed by a
/// stateful widget or it leaks, and separate children also let each link carry
/// its own opaque hit area — 11px glyphs are far too small to aim at, so the
/// padding below is the tap target, not spacing.
class _TermsPrivacyLine extends StatelessWidget {
  const _TermsPrivacyLine();

  @override
  Widget build(BuildContext context) {
    // No over-media shadow: this now sits on the silk panel, not on the
    // wallpaper, and a drop shadow on a solid ground just reads as fuzz.
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
/// The URLs come from [AppConfig] via [PolicyDoc] (dart-define overridable,
/// defaulting to the canonical company pages) — never spelled here, because the
/// SAME pages are linked from the Settings footer and named in the Play
/// listing, and three copies of a policy URL is how one of them goes stale.
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
        // Pushed OVER this screen, mirroring the Settings footer, and popping
        // straight back to it — sign-in never gets left behind in another app.
        // Safe mid-auth: the one-shot authenticate() has already been launched
        // from the first frame, and coming back does not re-arm it.
        onTap: () => context.push(doc.route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          child: Text(label, style: _policyLink),
        ),
      ),
    );
  }
}

/// The Google "G" — Google's OWN asset, never a redraw. The branding
/// guidelines ("required for app verification") say the G in a custom Sign in
/// with Google button "must be the standard color version … you can't change
/// the size or color" and list "create your own icon for the button" under
/// Don't. `assets/images/google_g.webp` is `developers.google.com/identity/
/// images/g-logo.png` (the image the build-a-custom-button guide itself uses),
/// padded to square so nothing stretches, re-encoded lossless at 96px — the
/// 20dp slot needs ≤80px even at 4x. It sits on the pill's ivory disc, which
/// is the guidelines' white-background requirement.
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
