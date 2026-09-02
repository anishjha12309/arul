import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme/tokens.dart';
import '../../../wallpapers/data/feed_video_player.dart';

/// Full-screen looping video background, playing `splash.mp4`.
///
/// Shows a solid dark colour until the first frame renders -> no blank-white flash on first paint.
/// Backed by the same Media3 texture pool as the feed's live previews -> ONE video stack in the app.
/// All mounts share ONE native player via [_SharedAuthVideoPlayer].
/// Recreating a MediaCodec per screen swap is slow on budget SoCs -> the fallback would sit visible.
/// Handing the live player across screens -> every screen after the first paints video immediately.
class VideoBackground extends StatefulWidget {
  const VideoBackground({super.key, this.overlayOpacity = 0.42});

  /// How dark the translucent veil on top of the video should be.
  /// 0.0 = no veil, 1.0 = fully black.
  final double overlayOpacity;

  @override
  State<VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<VideoBackground>
    with WidgetsBindingObserver {
  /// The video's own darkest region — if the two disagreed the reveal would pop.
  /// Still painted as the base layer -> any edge the poster's cover-fit leaves is never bare.
  static const _fallbackColor = ArulColors.ink;

  /// FRAME 0 of `splash.mp4`, bundled (512×912 WebP, ~15 KB in the APK).
  ///
  /// After the OS splash hands off, the Media3 decoder has produced no frame yet.
  /// The background was flat [_fallbackColor] until it did -> this is the shutter that covers it.
  /// Media3's guidance is to hold a placeholder and reveal the video only on the first frame.
  /// `PlayerView` does that with its own artwork; a raw [Texture] must supply it itself.
  /// It is frame 0 of the very file the texture plays -> no crossfade, the swap is imperceptible.
  static const _posterAsset = 'assets/images/splash_poster.webp';

  _SharedAuthVideoPlayer? _shared;
  FeedVideoPlayer? _player;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  /// Stop decoding while the app is off-screen.
  ///
  /// The ref count is held by the MOUNT, not by visibility -> backgrounding left `_refs == 1`.
  /// The player then decoded a looping video nobody could see — measured on device.
  /// This PAUSES and deliberately does NOT tear the decoder down.
  /// Teardown would free ~110MB of graphics memory, but a 20-run harness showed ZERO LMK kills.
  /// The cost is certain either way: the fallback colour flashes on every return from the picker.
  /// A Media3 pause keeps the decoder and the decoded frame -> resume is instant.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _shared?.pauseForBackground();
      case AppLifecycleState.resumed:
        _shared?.resumeFromBackground();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // `inactive` also fires for transient overlays -> pausing churns playback the user sees past.
        // `detached` is teardown.
        break;
    }
  }

  Future<void> _init() async {
    final shared = _SharedAuthVideoPlayer.acquire();
    _shared = shared;
    final player = await shared.player;
    // A null player means the platform is unavailable -> keep the fallback colour, never block.
    if (player == null || !mounted) return;
    _player = player;

    if (player.firstFrame.value) {
      // Shared-player handoff — the frame is already decoded -> paint at once, no fallback flash.
      setState(() => _ready = true);
    } else {
      // Reveal on the native first frame -> the solid fallback covers any decode delay.
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
    WidgetsBinding.instance.removeObserver(this);
    // Detach BEFORE release -> the last release lets the holder dispose the player and its notifiers.
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
        // Base colour: covers any edge the poster's cover-fit leaves bare.
        const ColoredBox(color: _fallbackColor),

        // The shutter stays MOUNTED under the texture, like the feed's live cards.
        // So a decoder that drops or restarts can never expose bare colour.
        const Image(
          image: AssetImage(_posterAsset),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),

        // A raw Texture does not cover-fit itself -> a FittedBox(cover) at the intrinsic size, clipped.
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

/// Ref-counted owner of the ONE background player every [VideoBackground] mount in auth shares.
///
/// Created on the first [acquire]; torn down shortly after the LAST mount releases.
/// A route replacement may dispose the old screen BEFORE the new one inits.
/// That ordering would churn the decoder -> the grace timer bridges it.
class _SharedAuthVideoPlayer {
  _SharedAuthVideoPlayer._();

  static _SharedAuthVideoPlayer? _instance;

  /// How long after the last release the player is kept alive — enough to bridge a route-swap gap.
  /// Short enough that the decoder is freed promptly once the feed takes over.
  static const _releaseGrace = Duration(seconds: 2);

  int _refs = 0;
  bool _dead = false;
  Timer? _teardown;
  FeedVideoPlayerPool? _pool;
  Future<FeedVideoPlayer?>? _player;

  /// Resolves to the shared player, or null when the platform side is unavailable.
  Future<FeedVideoPlayer?> get player => _player ?? Future.value();

  static _SharedAuthVideoPlayer acquire() {
    final holder = _instance ??= _SharedAuthVideoPlayer._();
    holder._teardown?.cancel();
    holder._teardown = null;
    holder._refs++;
    holder._player ??= holder._create();
    // Resume if a release-to-zero paused it — decoder and frame survive a pause, so it is instant.
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
      // Media3 DefaultDataSource plays a Flutter asset via `asset:///`, out of flutter_assets.
      // Looped and muted — the pool creates muted, so no audio focus is taken.
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

  /// Stop decode while off-screen. Keeps the decoder and frame -> [resumeFromBackground] is instant.
  /// Idempotent — every mounted [VideoBackground] calls it.
  void pauseForBackground() {
    final player = _player;
    if (player == null || _dead) return;
    unawaited(
      player.then((p) {
        if (!_dead) p?.pause();
      }),
    );
  }

  /// Resume after [pauseForBackground].
  /// The `_refs > 0` guard stops a mid-grace resume reviving a player about to be torn down.
  void resumeFromBackground() {
    final player = _player;
    if (player == null || _dead) return;
    unawaited(
      player.then((p) {
        if (!_dead && _refs > 0) p?.play();
      }),
    );
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
    // Disposing the pool mid-create leaks the native player it is about to register -> wait for it.
    // A real player pauses now and lives through the grace window, in case another screen mounts.
    // A null player tears down at once — a pending grace timer trips the test pending-timer check.
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
