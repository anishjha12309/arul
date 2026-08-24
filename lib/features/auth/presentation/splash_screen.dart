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
/// The OS splash (Android 12+ SplashScreen API) hands off to this, both painted
/// on the same ink ([ArulTokens.darkSurface]), so there is no seam and no white
/// flash. The video's own darkest tone IS that ink — if they disagreed the
/// reveal would pop, which is the one thing a splash must never do.
///
/// It is on screen for exactly as long as the work takes and not one frame
/// longer — see [_SplashScreenState._decideRoute] for the beat that used to be
/// here and why it is gone. The catalog fetch and the media warm both start
/// here, so the reel's first frame usually already has data. The background
/// player is SHARED with the
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
  static const _tagline = 'DEVOTIONAL WALLPAPERS & RINGTONES';
  static const _transparentGold = Color.fromRGBO(212, 160, 23, 0);

  /// How many leading feed thumbnails to warm once the catalog lands. Mirrors
  /// the reference prefetch service's data window at index 0 (`_behind`=1 +
  /// self + `_ahead`=15 → items 0..15): the same set of soon-to-be-seen items,
  /// warmed as images instead of MP4 bytes. Thumbs beyond the in-memory cache's
  /// LRU still land in the DISK image cache, so a later scroll re-decodes
  /// locally instead of re-downloading.
  ///
  /// AUTHED SESSIONS ONLY. A signed-out session gets [_preAuthThumbWarmCount]
  /// and NO MP4 bytes: the full warm (up to 16 clips × 2–5 MB, 3 concurrent)
  /// used to start the moment the catalog landed and then fight the sign-in's
  /// own network calls — Google's token mint, Firebase, POST /auth/login —
  /// for the same pipe, which is where the 7–8 s first login came from
  /// (device 2026-08-18). Post-login the feed's own VideoPreloadController
  /// re-runs `prefetchAround` on mount, so nothing is lost — only deferred
  /// past the moment the user is watching a spinner.
  static const _thumbWarmCount = 16;

  /// The signed-out slice of the warm: the first screenful of posters, so the
  /// feed the user lands on after sign-in shows real wallpapers instantly
  /// (owner's call, 2026-08-18: "3–4 should be there"), at a bandwidth cost —
  /// a few hundred KB — that cannot crowd the auth calls.
  static const _preAuthThumbWarmCount = 4;

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

    // Open the connection to the API host now, so POST /auth/login — which is
    // moments away — doesn't pay DNS + TLS + Worker cold start itself. Never
    // awaited, never retried, never able to fail anything (ApiClient.warmUp).
    BootTrace.mark('splash: API warm-up fired');
    unawaited(
      ref
          .read(apiClientProvider)
          .warmUp()
          .then((_) => BootTrace.mark('splash: API warm-up settled')),
    );

    // Warm the catalog while the wordmark is on screen, and — the moment it
    // resolves — the first screenful of feed media (reference app.dart's warm
    // prefetch, relocated to the splash it describes).
    ref.listenManual(catalogProvider, fireImmediately: true, (_, next) {
      if (next case AsyncData(:final value) when value.isNotEmpty) {
        unawaited(_warmFeedMedia(value));
      }
    });
    _decideRoute();
  }

  /// Warm the caches the reel will read first, in parallel with the auth seed:
  ///
  ///  • LIVE bytes (authed sessions only): `prefetchAround(items, 0)` on the
  ///    app-scoped [WallpaperPrefetchService] — the same instance the feed's
  ///    video controller pumps, so the two share one in-flight queue and never
  ///    double-download. Bytes only; NO player, NO decoder is touched here.
  ///  • Posters: decode the first [_thumbWarmCount] posters (signed-out:
  ///    [_preAuthThumbWarmCount]) into the shared image cache at the SAME
  ///    decode width the tiles/posters use ([WallpaperTile.decodeWidthFor] —
  ///    memCacheWidth is part of the cache key), so the feed's first paint is
  ///    a repaint, not a refetch.
  ///
  /// Awaits the auth seed first: the catalog can land (disk snapshot) before
  /// the stored-session verdict, and deciding off the not-yet-seeded state
  /// would give every RETURNING user the narrow signed-out warm.
  Future<void> _warmFeedMedia(List<Wallpaper> items) async {
    if (_mediaWarmed) return;
    _mediaWarmed = true;

    if (AppConfig.hasBackend) {
      await ref
          .read(authServiceProvider)
          .initialized
          .timeout(const Duration(seconds: 6), onTimeout: () {});
    }
    // Screen already gone (the catalog landed after we routed): skip. The
    // authed path re-warms via the feed's own controller; the signed-out path
    // loads its posters when the feed builds them — a slow catalog was the
    // bottleneck anyway.
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
    // It used to run in a post-frame callback that bailed on `!mounted`, which
    // was free when a fixed 1800ms beat guaranteed the splash outlived it. With
    // the beat gone the splash routes away within a frame of the seed settling,
    // so that callback would find itself unmounted and warm NOTHING — handing
    // the reel a cold image cache on exactly the launch this change was meant
    // to speed up. The work itself never needed the delay; only the MediaQuery
    // lookup did, and by here we are past `initState` (the `initialized` await
    // above always yields) so the lookup is legal.
    //
    // `precacheImage` reads the context once, synchronously, to build its
    // ImageConfiguration; the decode it starts is owned by the app-scoped image
    // cache and completes regardless of what happens to this screen.
    //
    // The one path with no await ahead of it is a define-less build
    // ([AppConfig.hasBackend] false), which could still be inside `initState`;
    // there the lookup would throw, so that case alone keeps the old deferral.
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

  /// Decode the first [count] posters into the shared image cache at the same
  /// width the tiles render them at, so the reel's first paint is a repaint.
  void _warmPosters(List<Wallpaper> items, int count) {
    final decodeWidth = WallpaperTile.decodeWidthFor(context);
    for (final w in items.take(count)) {
      precacheImage(
        // resizeIfNeeded is exactly what CachedNetworkImage does with
        // memCacheWidth, so this warms the entry the reel actually renders.
        ResizeImage.resizeIfNeeded(
          decodeWidth,
          null,
          CachedNetworkImageProvider(w.posterUrl(AppConfig.cdnBaseUrl)),
        ),
        context,
        // Never throws into the framework; the tile keeps its own fallback
        // ladder regardless.
        onError: (_, _) {},
      );
    }
  }

  /// Wait for the auth service to finish its stored-session check, then route
  /// IMMEDIATELY. Sampling `currentState` on a fixed timer raced the encrypted
  /// secure-storage read on cold start and bounced returning users to sign-in
  /// ("session didn't persist"); awaiting [AuthService.initialized] (bounded)
  /// is what fixes that, and it is the only thing this screen waits on.
  ///
  /// There is NO fixed brand beat any more (owner's call, 2026-08-24). It was
  /// `Future.delayed(1800ms)` started here, and it was measured on device as
  /// pure dead time: the auth seed settles ~375ms after `main()` entry and the
  /// catalog is already warm by then, so the splash sat idle for the remaining
  /// ~1.4s. It owned most of the cold start and most of the first-content gap
  /// — both budgets in memory `arul-growth-metrics` (which keeps the measured
  /// numbers) missed for that reason alone. Do not re-add a floor here: if the brand moment needs
  /// more time, it has to come from work that is actually on the critical path,
  /// not from a timer.
  Future<void> _decideRoute() async {
    BootTrace.mark('splash: _decideRoute start');
    if (AppConfig.hasBackend) {
      // Wait for the seed, but never hang the splash if it stalls.
      await ref
          .read(authServiceProvider)
          .initialized
          .timeout(const Duration(seconds: 6), onTimeout: () {});
      BootTrace.mark('splash: auth seed settled');

      // No stored session — ask Google NOW rather than at the sign-in screen's
      // first frame, which is a further route away.
      //
      // This is the whole latency fix: measured on device the account picker
      // landed 2.9s after launch, against a competitor's 1.25s, and nearly all
      // of the difference was this call waiting its turn. The picker is a
      // system Activity that covers us, so it stays off the critical path: the
      // route below runs underneath it either way. Fired BEFORE that route on
      // purpose — the sign-in screen's own auto-launch then finds an attempt
      // already in flight and stands down, which is what keeps the contract of
      // EXACTLY ONE account picker per sign-in (docs/edge-cases.md §Auth).
      //
      // NOT fired before the seed resolves: until the stored-session check
      // comes back, an already-signed-in user might be behind it, and showing
      // THEM an account picker is a worse bug than being a second slower.
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
            // Video paints edge-to-edge; the veil is our own scrim below, so no
            // built-in overlay from VideoBackground competes with it.
            const VideoBackground(overlayOpacity: 0),

            // Spec > Splash: 180deg .25 → 0 @35% → 0 @55% → .82.
            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.splashBottomScrim),
            ),

            // Bottom-centered column, bottom:64, gap 10. The gopuram mark that
            // used to head this stack is gone — the wordmark grew to carry the
            // brand alone, and the loader keeps its 64px anchor, so the block
            // simply reads shorter from the top.
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

  /// 120×2px gold hairline with a sliding gradient, 1.6s linear loop. No
  /// spinner — Spec > Splash is explicit about that.
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
