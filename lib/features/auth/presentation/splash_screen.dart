import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/gopuram_mark.dart';
import '../../../theme/arul_tokens.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import 'widgets/video_background.dart';

/// The brand beat.
///
/// The OS splash (Android 12+ SplashScreen API) hands off to this, both painted
/// on the same ink ([ArulTokens.darkSurface]), so there is no seam and no white
/// flash. The video's own darkest tone IS that ink — if they disagreed the
/// reveal would pop, which is the one thing a splash must never do.
///
/// It is not dead time: the catalog fetch starts here, so the grid's first
/// frame usually already has data. The background player is SHARED with the
/// sign-in screen ([VideoBackground]'s ref-counted singleton) — the same
/// decoder, handed across the route — so moving between them never re-inits a
/// MediaCodec, which on a budget SoC would drop the background back to a flat
/// colour for a beat. This screen paints `overlayOpacity: 0` and draws its own
/// scrim + hairline loader on top, per the design handoff.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _tagline = 'SOUTH INDIAN WALLPAPERS';
  static const _transparentGold = Color.fromRGBO(212, 160, 23, 0);

  late final AnimationController _hairlineController;

  @override
  void initState() {
    super.initState();
    _hairlineController = AnimationController(
      vsync: this,
      duration: ArulTokens.hairlineLoop,
    )..repeat();

    // Warm the catalog while the wordmark is on screen.
    ref.read(catalogProvider);
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) context.go('/sign-in');
    });
  }

  @override
  void dispose() {
    _hairlineController.dispose();
    super.dispose();
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
            // Video paints edge-to-edge; the veil is our own scrim below, so no
            // built-in overlay from VideoBackground competes with it.
            const VideoBackground(overlayOpacity: 0),

            // README > Splash: 180deg .25 → 0 @35% → 0 @55% → .82.
            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.splashBottomScrim),
            ),

            // Bottom-centered column, bottom:64, gap 10.
            Positioned(
              left: 0,
              right: 0,
              bottom: 64,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GopuramMark(size: 44, color: ArulTokens.gold),
                  const SizedBox(height: 10),
                  const Text('Arul', style: ArulTokens.wordmarkSplash),
                  const SizedBox(height: 10),
                  const Text(_tagline, style: ArulTokens.tagline),
                  const SizedBox(height: 14),
                  _buildHairlineLoader(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 120×2px gold hairline with a sliding gradient, 1.6s linear loop. No
  /// spinner — README > Splash is explicit about that.
  Widget _buildHairlineLoader() {
    return SizedBox(
      width: ArulTokens.hairlineWidth,
      height: ArulTokens.hairlineHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: AnimatedBuilder(
          animation: _hairlineController,
          builder: (context, _) {
            // CSS: background-size 200% 100%, sliding one full tile width per
            // loop — reproduced as a translate of a double-wide gradient bar
            // across the clipped 120px window.
            final dx =
                -ArulTokens.hairlineWidth +
                _hairlineController.value * (ArulTokens.hairlineWidth * 2);
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Container(
                width: ArulTokens.hairlineWidth * 2,
                height: ArulTokens.hairlineHeight,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _transparentGold,
                      ArulTokens.gold,
                      ArulTokens.gold,
                      _transparentGold,
                    ],
                    stops: [0.0, 0.4, 0.6, 1.0],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
