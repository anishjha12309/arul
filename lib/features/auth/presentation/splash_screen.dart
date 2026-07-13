import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../app/theme/tokens.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import 'widgets/video_background.dart';

/// The brand beat.
///
/// The OS splash (Android 12+ SplashScreen API) hands off to this, both painted
/// on the same ink, so there is no seam and no white flash. The video's own
/// darkest tone IS that ink — if they disagreed the reveal would pop, which is
/// the one thing a splash must never do.
///
/// It is not dead time: the catalog fetch starts here, so the grid's first frame
/// usually already has data. And the background player is SHARED with the sign-in
/// screen — the same decoder, handed across the route — so moving between them
/// never re-inits a MediaCodec, which on a budget SoC would drop the background
/// back to a flat colour for a beat.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Warm the catalog while the wordmark is on screen.
    ref.read(catalogProvider);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) context.go('/browse');
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // A heavier veil than sign-in uses: nothing here competes with the
          // wordmark, and the clip should read as atmosphere, not as content.
          const VideoBackground(overlayOpacity: 0.5),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Motion.enter,
              curve: Motion.enterCurve,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - t)),
                  child: child,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.appName,
                    style: theme.textTheme.displayMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: Gap.md),
                  Container(width: 44, height: 2, color: ArulColors.gold),
                  const SizedBox(height: Gap.lg),
                  Text(
                    l10n.appTagline,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                      letterSpacing: 2.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
