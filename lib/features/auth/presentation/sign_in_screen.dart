import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/gopuram_mark.dart';
import '../../../theme/arul_tokens.dart';
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
/// The pill below is the fallback for a dismissed sheet, and (in this design
/// pass) a mock identity — no real auth wiring yet.
///
/// The background player is SHARED with the splash — the same live decoder
/// handed across the route — so arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  static const _mockName = 'Priya';
  static const _mockEmail = 'priya.raman@gmail.com';
  static const _caption = 'Sign in to begin your free trial';

  @override
  void initState() {
    super.initState();
    // TODO(auth-phase): AuthService.authenticate() auto-launches here on the
    // first frame (google_sign_in v7: instance -> initialize() ->
    // authenticate()). The pill is the fallback UI for a dismissed sheet.
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

            // README > Sign-in: 3-stop .28 → 0 (38–62%) → .72.
            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.signInScrim),
            ),

            // Top-center, top:96px.
            const Positioned(
              left: 0,
              right: 0,
              top: 96,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GopuramMark(size: 34, color: ArulTokens.gold),
                  SizedBox(height: 8),
                  Text('Arul', style: ArulTokens.wordmarkSignIn),
                ],
              ),
            ),

            // Bottom, inset 20px, bottom 28px, gap 14.
            Positioned(
              left: 20,
              right: 20,
              bottom: 28,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _caption,
                    textAlign: TextAlign.center,
                    style: ArulTokens.body.copyWith(
                      color: ArulTokens.ivory.withValues(alpha: 0.8),
                      shadows: ArulTokens.overMediaShadow,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SignInPill(
                    name: _mockName,
                    email: _mockEmail,
                    onTap: () => context.go('/browse'),
                  ),
                  const SizedBox(height: 14),
                  const _TermsPrivacyLine(),
                ],
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
    required this.name,
    required this.email,
    required this.onTap,
  });

  final String name;
  final String email;
  final VoidCallback onTap;

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
      onTapDown: (_) => _setPressed(true),
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
                    'Continue as ${widget.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ArulTokens.ivory,
                    ),
                  ),
                  Text(
                    widget.email,
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

/// 'Terms · Privacy', 11px, faint ivory, gold-85% links.
class _TermsPrivacyLine extends StatelessWidget {
  const _TermsPrivacyLine();

  static const _base = TextStyle(
    fontSize: 11,
    color: Color.fromRGBO(250, 245, 236, 0.5),
  );
  static const _link = TextStyle(
    fontSize: 11,
    color: Color.fromRGBO(212, 160, 23, 0.85),
  );

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: _base.copyWith(shadows: ArulTokens.overMediaShadow),
        children: const [
          TextSpan(text: 'Terms', style: _link),
          TextSpan(text: ' · '),
          TextSpan(text: 'Privacy', style: _link),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// Self-contained multicolor Google "G" mark — a CustomPainter pinwheel
/// approximation (four brand-colour ring arcs + the blue crossbar), so no
/// network asset and no new package is needed for a design-only pass.
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
