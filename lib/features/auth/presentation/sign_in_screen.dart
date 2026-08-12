import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../theme/arul_tokens.dart';
import '../domain/auth_service.dart';
import '../providers/auth_providers.dart';
import 'widgets/video_background.dart';

/// Sign-in.
///
/// It does NOT block the app. Browse and preview are free, so making a
/// wallpaper app demand an account before it will show you a single wallpaper
/// is a good way to be uninstalled. Sign-in exists for the things that
/// genuinely need identity — entitlement, uploads, a collection that survives
/// a new phone — and the user reaches it when they reach for one of those.
///
/// PHASE CONTRACT — do not redesign this away: the real screen AUTO-LAUNCHES
/// the FULL Google `authenticate()` on its first frame (google_sign_in v7:
/// instance → initialize() → authenticate()). It must never be swapped to
/// lightweight/silent auth; that was tried and rejected on retention grounds.
///
/// Nor may lightweight auth run AHEAD of it as a warm-up — that was tried too,
/// and measured on device (2026-08-11): `attemptLightweightAuthentication()`
/// puts up a real Credential Manager bottom sheet on Android, so the user saw
/// a drawer appear, hang, and vanish before the actual picker. ONE picker per
/// sign-in. See `ApiAuthService._signInWithGoogle`.
///
/// The pill below is the fallback for a dismissed sheet — a generic
/// "Continue with Google" retry affordance (never a named identity: the
/// account choice belongs to Google's own sheet).
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

  @override
  void initState() {
    super.initState();
    BootTrace.mark('signIn screen: initState');
    // CONTRACT: auto-launch the FULL Google `authenticate()` on the first
    // frame (google_sign_in v7: instance → initialize() [done in main()] →
    // authenticate()). NEVER lightweight/silent auth — retention decision.
    // The pill below is the fallback for a dismissed sheet.
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
    // Auto-launch already spent: leave the pill as the retry affordance.
    if (pending == null) return;

    setState(() => _signingIn = true);
    try {
      final result = await pending;
      if (!mounted) return;
      switch (result) {
        case AuthSuccess():
          context.go('/browse');
        case AuthCancelled():
          break; // sheet dismissed — the pill remains as the retry affordance
        case AuthFailure(:final message):
          // Localized-enough surface + retry (the pill), never a stuck spinner.
          showArulToast(context, message, kind: ToastKind.error);
      }
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
                    _SignInPill(
                      title: 'Continue with Google',
                      subtitle: 'Choose an account to get started',
                      onTap: _signingIn ? () {} : _onPillTap,
                      busy: _signingIn,
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
        _PolicyLink(label: 'Terms', url: AppConfig.termsUrl),
        Text(' · ', style: _policyBase),
        _PolicyLink(label: 'Privacy', url: AppConfig.privacyUrl),
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

/// One policy link, opening in the browser.
///
/// The URLs come from [AppConfig] (dart-define overridable, defaulting to the
/// canonical company pages) — never spelled here, because the SAME pages are
/// linked from the Settings footer and named in the Play listing, and three
/// copies of a policy URL is how one of them goes stale.
class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.tap(),
        // Fire-and-forget, mirroring the Settings footer: a device with no
        // browser must not throw into the sign-in tree over a policy link —
        // this screen is mid-auth and has nowhere useful to surface it.
        onTap: () => unawaited(
          launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          ).catchError((_) => false),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          child: Text(label, style: _policyLink),
        ),
      ),
    );
  }
}

/// Self-contained multicolor Google "G" mark — a CustomPainter pinwheel
/// approximation (four brand-colour ring arcs + the blue crossbar), so no
/// network asset and no new package is needed.
class _GoogleGMark extends StatelessWidget {
  const _GoogleGMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  static const _red = Color(0xFFEA4335);
  static const _blue = Color(0xFF4285F4);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final strokeWidth = radius * 0.44;
    final ringRadius = radius - strokeWidth / 2;
    final rect = Rect.fromCircle(center: center, radius: ringRadius);

    void arc(double startDeg, double sweepDeg, Color color) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        rect,
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        paint,
      );
    }

    // Angles measured clockwise from the positive x-axis (east = 0°).
    arc(-90, 70, _red); // top → upper-right
    arc(-20, 110, _blue); // upper-right → lower-right
    arc(90, 100, _green); // bottom → lower-left
    arc(190, 80, _yellow); // left → top

    // The crossbar: the ring's right-middle segment, filled solid blue.
    final barPaint = Paint()..color = _blue;
    canvas.drawRect(
      Rect.fromLTWH(
        center.dx - strokeWidth * 0.15,
        center.dy - strokeWidth / 2,
        radius - center.dx + strokeWidth * 0.15,
        strokeWidth,
      ),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(_GoogleGPainter oldDelegate) => false;
}
