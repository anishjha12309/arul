import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../wallpapers/presentation/wallpaper_tile.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../../wallpapers/providers/wallpaper_prefetch_provider.dart';
import '../domain/auth_service.dart';
import '../providers/auth_providers.dart';
import 'widgets/video_background.dart';

/// The launch screen.
///
/// The OS splash hands off to this, both painted on the same ink -> no seam, no white flash.
/// The video's darkest tone IS that ink — if they disagreed the reveal would pop.
/// On screen for exactly as long as the work takes, never a frame longer — see [_decideRoute].
/// The catalog fetch and the media warm both start here -> the reel's first frame usually has data.
/// The background player is SHARED with sign-in ([VideoBackground]'s ref-counted singleton).
/// The same decoder crosses the route -> no MediaCodec re-init, which on a budget SoC flattens it.
/// This screen paints `overlayOpacity: 0` and draws its own scrim and hairline loader on top.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _tagline = 'DEVOTIONAL WALLPAPERS & RINGTONES';
  static const _transparentGold = Color.fromRGBO(212, 160, 23, 0);

  /// How many leading feed thumbnails to warm once the catalog lands.
  ///
  /// Mirrors the prefetch service's window at index 0 (items 0..15) — the same soon-to-be-seen set.
  /// Thumbs past the in-memory LRU still land on DISK -> a later scroll re-decodes, never re-downloads.
  /// AUTHED SESSIONS ONLY -> a signed-out session gets [_preAuthThumbWarmCount] and NO MP4 bytes.
  /// The full warm (16 clips × 2–5 MB) fought the token mint and POST /auth/login -> a 7–8 s login.
  /// Post-login the feed's own VideoPreloadController re-runs `prefetchAround` -> nothing is lost.
  static const _thumbWarmCount = 16;

  /// The signed-out slice — the first screenful of posters, so the post-login feed shows real art.
  /// A few hundred KB, which cannot crowd the auth calls.
  static const _preAuthThumbWarmCount = 4;

  /// The warm-up runs once per splash, on the first catalog data to land — disk snapshot or drain.
  bool _mediaWarmed = false;

  late final AnimationController _hairlineController;

  @override
  void initState() {
    super.initState();
    _hairlineController = AnimationController(
      vsync: this,
      duration: ArulTokens.hairlineLoop,
    )..repeat();

    // Open the API connection now -> POST /auth/login, moments away, pays no DNS, TLS or cold start.
    // Never awaited, never retried, never able to fail anything (ApiClient.warmUp).
    BootTrace.mark('splash: API warm-up fired');
    unawaited(
      ref
          .read(apiClientProvider)
          .warmUp()
          .then((_) => BootTrace.mark('splash: API warm-up settled')),
    );

    // Warm the catalog while the wordmark is up, then the first screenful of feed media.
    ref.listenManual(catalogProvider, fireImmediately: true, (_, next) {
      if (next case AsyncData(:final value) when value.isNotEmpty) {
        unawaited(_warmFeedMedia(value));
      }
    });
    _decideRoute();
  }

  /// Warm the caches the reel will read first, in parallel with the auth seed:
  ///
  ///  • LIVE bytes, authed only — `prefetchAround(items, 0)` on the app-scoped service the feed's
  ///    controller also pumps, so the two share one queue and never double-download;
  ///    bytes ONLY, no player and no decoder is touched here;
  ///  • Posters — decoded at the SAME width the tiles use ([WallpaperTile.decodeWidthFor], part of
  ///    the cache key), so the feed's first paint is a repaint, not a refetch.
  ///
  /// The catalog can land from disk BEFORE the stored-session verdict.
  /// Deciding off the unseeded state gives every RETURNING user the narrow warm -> await the seed.
  Future<void> _warmFeedMedia(List<Wallpaper> items) async {
    if (_mediaWarmed) return;
    _mediaWarmed = true;

    if (AppConfig.hasBackend) {
      await ref
          .read(authServiceProvider)
          .initialized
          .timeout(const Duration(seconds: 6), onTimeout: () {});
    }
    // Screen already gone (the catalog landed after routing) -> skip; both paths re-warm on their own.
    if (!mounted) return;

    final authed =
        !AppConfig.hasBackend ||
        ref.read(authServiceProvider).currentState.isAuthenticated;
    if (authed) {
      ref.read(wallpaperPrefetchServiceProvider).prefetchAround(items, 0);
    }
    final thumbCount = authed ? _thumbWarmCount : _preAuthThumbWarmCount;

    // Fire the poster warm NOW, while this screen is certainly mounted.
    //
    // The splash routes away within a frame of the seed settling -> a post-frame callback warms NOTHING.
    // That handed the reel a cold image cache on exactly the launch this was meant to speed up.
    // Only the MediaQuery lookup needed the deferral, and the await above already passed `initState`.
    // `precacheImage` reads the context once, synchronously, to build its ImageConfiguration.
    // The decode belongs to the app-scoped cache -> it completes whatever happens to this screen.
    // A define-less build has no await ahead of it and may still be inside `initState`.
    // So that one case keeps the deferral — the lookup would throw there.
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.postFrameCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _warmPosters(items, thumbCount);
      });
      return;
    }
    _warmPosters(items, thumbCount);
  }

  /// Decode the first [count] posters at the tiles' own width -> the reel's first paint is a repaint.
  void _warmPosters(List<Wallpaper> items, int count) {
    final decodeWidth = WallpaperTile.decodeWidthFor(context);
    for (final w in items.take(count)) {
      precacheImage(
        // resizeIfNeeded is what CachedNetworkImage does with memCacheWidth -> warms the entry used.
        ResizeImage.resizeIfNeeded(
          decodeWidth,
          null,
          CachedNetworkImageProvider(w.posterUrl(AppConfig.cdnBaseUrl)),
        ),
        context,
        // Never throws into the framework — the tile keeps its own fallback ladder regardless.
        onError: (_, _) {},
      );
    }
  }

  /// Wait for the stored-session check to finish, then route IMMEDIATELY.
  ///
  /// Sampling `currentState` on a timer raced the secure-storage read and bounced returning users.
  /// Awaiting [AuthService.initialized], bounded, is the fix — and the only thing this screen waits on.
  /// There is NO fixed brand beat (owner's call): the 1800ms one measured as pure dead time.
  /// The auth seed settles ~375ms in and the catalog is warm by then -> the splash sat idle ~1.4s.
  /// It owned most of the cold start and most of the first-content gap.
  /// Do NOT re-add a floor — a longer brand moment must come from critical-path work, not a timer.
  Future<void> _decideRoute() async {
    BootTrace.mark('splash: _decideRoute start');
    if (AppConfig.hasBackend) {
      // Wait for the seed, but never hang the splash if it stalls.
      await ref
          .read(authServiceProvider)
          .initialized
          .timeout(const Duration(seconds: 6), onTimeout: () {});
      BootTrace.mark('splash: auth seed settled');

      // No stored session -> ask Google NOW, not at the sign-in screen's first frame a route away.
      // The picker landed 2.9s after launch against a peer's 1.25s, nearly all of it waiting here.
      // The picker is a system Activity that covers us -> the route below still runs underneath.
      // Fired BEFORE that route -> the sign-in screen's auto-launch finds it in flight, stands down.
      // That is what keeps the contract of EXACTLY ONE picker per sign-in (edge-cases.md §Auth).
      // NEVER before the seed resolves — an already-signed-in user may be behind it.
      // Showing THEM a picker is a worse bug than being a second slower.
      if (AppConfig.googleAuthConfigured &&
          !ref.read(authServiceProvider).currentState.isAuthenticated) {
        BootTrace.mark('splash: no session → auto sign-in from splash');
        unawaited(
          ref
                  .read(authControllerProvider.notifier)
                  .autoSignIn(AuthProvider.google) ??
              Future<void>.value(),
        );
      }
    }
    if (!mounted) return;
    final authed =
        AppConfig.hasBackend &&
        ref.read(authServiceProvider).currentState.isAuthenticated;
    BootTrace.mark('splash: routing to ${authed ? '/browse' : '/sign-in'}');
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
            // Video paints edge-to-edge -> our own scrim below, no built-in overlay competing.
            const VideoBackground(overlayOpacity: 0),

            // Spec > Splash: 180deg .25 → 0 @35% → 0 @55% → .82.
            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.splashBottomScrim),
            ),

            // Bottom-centred column, bottom 64, gap 10 — the wordmark carries the brand alone.
            Positioned(
              left: 0,
              right: 0,
              bottom: 64,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Arul', style: ArulTokens.wordmarkSplash),
                  const SizedBox(height: 10),
                  // Shrinks, never wraps — see the twin in sign_in_screen.dart.
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _tagline,
                        maxLines: 1,
                        style: ArulTokens.tagline,
                      ),
                    ),
                  ),
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

  /// 120×2px gold hairline with a sliding gradient, 1.6s linear loop. No spinner — the spec is firm.
  Widget _buildHairlineLoader() {
    return SizedBox(
      width: ArulTokens.hairlineWidth,
      height: ArulTokens.hairlineHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: AnimatedBuilder(
          animation: _hairlineController,
          builder: (context, _) {
            // CSS `background-size: 200% 100%` sliding one tile per loop -> a double-wide bar moved.
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
