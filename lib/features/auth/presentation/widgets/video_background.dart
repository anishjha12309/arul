import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme/tokens.dart';
import '../../../wallpapers/data/feed_video_player.dart';

/// Full-screen looping video background.
/// Uses [splash.mp4] from assets/images/.
///
/// Shows a solid dark colour until the first frame is rendered so there's
/// no blank-white flash on first paint.
///
/// Backed by the native Media3 ExoPlayer texture pool ([FeedVideoPlayerPool]) —
/// the same video runtime as the wallpaper feed's live previews, so the app
/// ships a single video stack (no media_kit / libmpv).
///
/// All mounts share ONE native player via [_SharedAuthVideoPlayer]: the auth
/// flow shows this background on several consecutive screens (splash → sign-in
/// → post-login splash), and releasing + recreating a MediaCodec per screen
/// swap is slow on budget SoCs — the background would sit on the solid
/// fallback while the fresh decoder inits. Handing the live player across
/// screens means every screen after the first paints video immediately.
class VideoBackground extends StatefulWidget {
  const VideoBackground({super.key, this.overlayOpacity = 0.42});

  /// How dark the translucent veil on top of the video should be.
  /// 0.0 = no veil, 1.0 = fully black.
  final double overlayOpacity;

  @override
  State<VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<VideoBackground> {
  /// The video's own darkest region. If this and the video disagree, the reveal
  /// pops — which is exactly what a splash must never do.
  static const _fallbackColor = ArulColors.ink;

  _SharedAuthVideoPlayer? _shared;
  FeedVideoPlayer? _player;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final shared = _SharedAuthVideoPlayer.acquire();
    _shared = shared;
    final player = await shared.player;
    // player == null: platform unavailable (e.g. a headless widget test) —
    // keep the solid fallback colour rather than blocking the screen on the
    // background video.
    if (player == null || !mounted) return;
    _player = player;

    if (player.firstFrame.value) {
      // Shared-player handoff from the previous screen: the frame is already
      // decoded — paint it right away, no fallback flash.
      setState(() => _ready = true);
    } else {
      // Reveal once the native first frame has painted, so the solid fallback
      // covers any decode delay.
      player.firstFrame.addListener(_onFirstFrame);
    }
  }

  void _onFirstFrame() {
    final player = _player;
    if (player != null && player.firstFrame.value && !_ready && mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    // Detach BEFORE release: once the last mount releases, the shared holder
    // may dispose the player (and its notifiers) after the grace period.
    _player?.firstFrame.removeListener(_onFirstFrame);
    _player = null;
    _shared?.release();
    _shared = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Fallback colour while the video's first frame is decoding.
        const ColoredBox(color: _fallbackColor),

        // Video fill — cover-crop to fill the screen. A raw Texture does not
        // cover-fit itself, so wrap it in a FittedBox(cover) sized to the video's
        // intrinsic size inside a ClipRect (matching the old BoxFit.cover).
        if (_ready && player != null)
          ValueListenableBuilder<Size?>(
            valueListenable: player.videoSize,
            builder: (context, size, child) {
              if (size == null || size.width <= 0 || size.height <= 0) {
                return const SizedBox.shrink();
              }
              return ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: Texture(textureId: player.textureId),
                  ),
                ),
              );
            },
          ),

        // Subtle darkening veil for legibility
        ColoredBox(
          color: Color.fromRGBO(0, 0, 0, widget.overlayOpacity.clamp(0, 1)),
        ),
      ],
    );
  }
}

/// Ref-counted owner of the ONE background player shared by every
/// [VideoBackground] mount in the auth flow.
///
/// The player + decoder are created on the first [acquire], survive route
/// swaps between screens (the next screen acquires before — or within the
/// grace window after — the previous one releases), and are torn down shortly
/// after the LAST mount releases (i.e. the user actually left the auth flow).
/// The grace timer exists because a route replacement may dispose the old
/// screen before the new one inits — without it that ordering would churn the
/// decoder, which is exactly what this class exists to prevent.
class _SharedAuthVideoPlayer {
  _SharedAuthVideoPlayer._();

  static _SharedAuthVideoPlayer? _instance;

  /// How long after the last release the native player is kept alive. Long
  /// enough to bridge any route-swap dispose→init gap; short enough that the
  /// decoder is freed promptly once the feed takes over.
  static const _releaseGrace = Duration(seconds: 2);

  int _refs = 0;
  bool _dead = false;
  Timer? _teardown;
  FeedVideoPlayerPool? _pool;
  Future<FeedVideoPlayer?>? _player;

  /// Resolves to the shared player, or null when the platform side is
  /// unavailable (headless widget tests).
  Future<FeedVideoPlayer?> get player => _player ?? Future.value();

  static _SharedAuthVideoPlayer acquire() {
    final holder = _instance ??= _SharedAuthVideoPlayer._();
    holder._teardown?.cancel();
    holder._teardown = null;
    holder._refs++;
    holder._player ??= holder._create();
    // Resume if a release-to-zero paused it — the decoder and decoded first
    // frame survive a Media3 pause, so this is instant.
    unawaited(
      holder._player!.then((p) {
        if (!holder._dead && holder._refs > 0) p?.play();
      }),
    );
    return holder;
  }

  Future<FeedVideoPlayer?> _create() async {
    try {
      final pool = FeedVideoPlayerPool();
      _pool = pool;
      final player = await pool.create();
      if (player == null) {
        await pool.dispose();
        _pool = null;
        return null;
      }
      // Media3 DefaultDataSource plays a Flutter asset via the asset:/// scheme
      // (resolved from the APK's flutter_assets/). Looped + muted (the pool
      // creates muted, no audio focus).
      await player.open(
        'asset:///flutter_assets/assets/video/splash.mp4',
        playWhenReady: true,
        looping: true,
      );
      return player;
    } catch (_) {
      // Native video unavailable — callers keep the solid fallback colour.
      return null;
    }
  }

  void release() {
    _refs--;
    if (_refs > 0) return;

    final player = _player;
    if (player == null) {
      // Never acquired to the point of creating — nothing native to keep.
      _teardownNow();
      return;
    }
    // Decide once create() settles (it may still be in flight — disposing the
    // pool mid-create would leak the native player it is about to register):
    // a real player pauses now (stop burning decode cycles) and lives through
    // the grace window in case the next auth screen is about to mount; a null
    // player (headless widget test) tears down immediately — a pending grace
    // timer would trip the test framework's pending-timer check.
    unawaited(
      player.then((p) {
        if (_dead || _refs > 0) return;
        if (p == null) {
          _teardownNow();
          return;
        }
        p.pause();
        _teardown?.cancel();
        _teardown = Timer(_releaseGrace, () {
          if (_refs == 0) _teardownNow();
        });
      }),
    );
  }

  void _teardownNow() {
    if (_dead) return;
    _dead = true;
    _teardown?.cancel();
    _teardown = null;
    _instance = null;
    final pool = _pool;
    _pool = null;
    _player = null;
    // Disposing the pool releases the native player + its texture.
    if (pool != null) unawaited(pool.dispose());
  }
}
