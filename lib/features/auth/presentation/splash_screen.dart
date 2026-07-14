import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../wallpapers/presentation/wallpaper_tile.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../../wallpapers/providers/wallpaper_prefetch_provider.dart';
import '../providers/auth_providers.dart';
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

  /// How many leading feed thumbnails to warm once the catalog lands. Mirrors
  /// the reference prefetch service's data window at index 0 (`_behind`=1 +
  /// self + `_ahead`=15 → items 0..15): the same set of soon-to-be-seen items,
  /// warmed as images instead of MP4 bytes. Thumbs beyond the in-memory cache's
  /// LRU still land in the DISK image cache, so a later scroll re-decodes
  /// locally instead of re-downloading.
  static const _thumbWarmCount = 16;

  /// The warm-up runs once per splash, on the first catalog data to land
  /// (immediately from the disk snapshot on a warm start, or when the network
  /// drain finishes on a cold one).
  bool _mediaWarmed = false;

  late final AnimationController _hairlineController;

  @override
  void initState() {
    super.initState();
    _hairlineController = AnimationController(
      vsync: this,
      duration: ArulTokens.hairlineLoop,
    )..repeat();

    // Warm the catalog while the wordmark is on screen, and — the moment it
    // resolves — the first screenful of feed media (reference app.dart's warm
    // prefetch, relocated to the splash it describes).
    ref.listenManual(catalogProvider, fireImmediately: true, (_, next) {
      if (next case AsyncData(:final value) when value.isNotEmpty) {
        _warmFeedMedia(value);
      }
    });
    _decideRoute();
  }

  /// Warm the caches the reel will read first, while the brand beat plays:
  ///
  ///  • LIVE bytes: `prefetchAround(items, 0)` on the app-scoped
  ///    [WallpaperPrefetchService] — the same instance the feed's video
  ///    controller pumps, so the two share one in-flight queue and never
  ///    double-download. Bytes only; NO player, NO decoder is touched here.
  ///  • Thumbnails: decode the first [_thumbWarmCount] posters into the shared
  ///    image cache at the SAME decode width the tiles/posters use
  ///    ([WallpaperTile.decodeWidthFor] — memCacheWidth is part of the cache
  ///    key), so the feed's first paint is a repaint, not a refetch.
  void _warmFeedMedia(List<Wallpaper> items) {
    if (_mediaWarmed) return;
    _mediaWarmed = true;

    ref.read(wallpaperPrefetchServiceProvider).prefetchAround(items, 0);

    // Post-frame: the listener can fire synchronously inside initState (a
    // warm keepAlive catalog), where the MediaQuery lookup below is illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final decodeWidth = WallpaperTile.decodeWidthFor(context);
      for (final w in items.take(_thumbWarmCount)) {
        precacheImage(
          // resizeIfNeeded is exactly what CachedNetworkImage does with
          // memCacheWidth, so this warms the entry the reel actually renders.
          ResizeImage.resizeIfNeeded(
            decodeWidth,
            null,
            CachedNetworkImageProvider(w.thumbUrl(AppConfig.cdnBaseUrl)),
          ),
          context,
          // Never throws into the framework; the tile keeps its own fallback
          // ladder regardless.
          onError: (_, _) {},
        );
      }
    });
  }

  /// Hold the brand beat AND wait for the auth service to finish its stored-
  /// session check before deciding where to go. Sampling `currentState` on a
  /// fixed timer raced the encrypted secure-storage read on cold start and
  /// bounced returning users to sign-in ("session didn't persist"); awaiting
  /// [AuthService.initialized] (bounded) fixes that while keeping the beat.
  Future<void> _decideRoute() async {
    const minBeat = Duration(milliseconds: 1800);
    final beat = Future<void>.delayed(minBeat);
    if (AppConfig.hasBackend) {
      // Wait for the seed, but never hang the splash if it stalls.
      await ref
          .read(authServiceProvider)
          .initialized
          .timeout(const Duration(seconds: 6), onTimeout: () {});
    }
    await beat;
    if (!mounted) return;
    final authed =
        AppConfig.hasBackend &&
        ref.read(authServiceProvider).currentState.isAuthenticated;
    context.go(authed ? '/browse' : '/sign-in');
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
