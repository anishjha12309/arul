import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme/motion.dart';
import '../../../../core/analytics/journey_stamps.dart';
import '../../../../core/perf/boot_trace.dart';
import '../../../wallpapers/data/feed_video_player.dart';

/// The poster's own clip, laid over the poster in the same frame.
class LaunchClipLayer extends StatefulWidget {
  const LaunchClipLayer({super.key, required this.source});

  /// A local file: the clip is never streamed before sign-in (launch-surface.md).
  final String source;

  /// Paints in the texture's place in tests, which have no decoder: the size matrix proves the clip
  /// lands on the poster's pixels, and its dumps show the clip's real first frame there.
  @visibleForTesting
  static Widget Function(String source)? debugStandIn;

  @override
  State<LaunchClipLayer> createState() => _LaunchClipLayerState();
}

class _LaunchClipLayerState extends State<LaunchClipLayer>
    with WidgetsBindingObserver {
  _SharedAuthVideoPlayer? _shared;
  FeedVideoPlayer? _player;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    if (LaunchClipLayer.debugStandIn != null) return;
    final shared = _SharedAuthVideoPlayer.acquire(
      widget.source,
      autoplay: false,
    );
    _shared = shared;
    final player = await shared.player;
    if (player == null || !mounted) return;
    setState(() => _player = player);
    if (player.firstFrame.value) {
      _show();
    } else {
      player.firstFrame.addListener(_onFirstFrame);
    }
  }

  void _onFirstFrame() {
    if (_player?.firstFrame.value ?? false) _show();
  }

  void _show() {
    if (_shown || !mounted) return;
    BootTrace.mark('launch clip: first frame, crossfading');
    JourneyStamps.noteWallClip('playing');
    setState(() => _shown = true);
  }

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
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player?.firstFrame.removeListener(_onFirstFrame);
    _player = null;
    _shared?.release();
    _shared = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final standIn = LaunchClipLayer.debugStandIn;
    if (standIn != null) return standIn(widget.source);
    final player = _player;
    if (player == null) return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: context.reduceMotion ? Duration.zero : Motion.imageFade,
      curve: Motion.settleCurve,
      onEnd: () {
        if (_shown) _shared?.start();
      },
      child: _CoverTexture(player),
    );
  }
}

/// A raw Texture does not cover-fit itself -> a FittedBox(cover) at the intrinsic size, clipped.
class _CoverTexture extends StatelessWidget {
  const _CoverTexture(this.player);

  final FeedVideoPlayer player;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Size?>(
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
    );
  }
}

/// Ref-counted owner of the ONE background player every auth mount shares.
class _SharedAuthVideoPlayer {
  _SharedAuthVideoPlayer._(this._source, this._started);

  static _SharedAuthVideoPlayer? _instance;

  /// How long after the last release the player is kept alive — enough to bridge a route-swap gap.
  /// Short enough that the decoder is freed promptly once the feed takes over.
  static const _releaseGrace = Duration(seconds: 2);

  String _source;

  /// Whether playback was asked for. A paused-open clip ([LaunchClipLayer]) holds still on its first
  /// frame until [start]; nothing may resume what never started.
  bool _started;

  int _refs = 0;
  bool _dead = false;
  Timer? _teardown;
  FeedVideoPlayerPool? _pool;
  Future<FeedVideoPlayer?>? _player;

  Future<FeedVideoPlayer?> get player => _player ?? Future.value();

  static _SharedAuthVideoPlayer acquire(String source, {bool autoplay = true}) {
    final holder = _instance ??= _SharedAuthVideoPlayer._(source, autoplay);
    holder._teardown?.cancel();
    holder._teardown = null;
    holder._refs++;
    if (holder._player != null && holder._source != source) {
      // One decoder for the auth screens, whatever they show -> swap the media, never add a player.
      holder._source = source;
      holder._started = autoplay;
      holder._player = holder._player!.then((p) async {
        await p?.open(source, playWhenReady: autoplay, looping: true);
        return p;
      });
    }
    holder._player ??= holder._create();
    // Resume if a release-to-zero paused it — decoder and frame survive a pause, so it is instant.
    unawaited(
      holder._player!.then((p) {
        if (!holder._dead && holder._refs > 0 && holder._started) p?.play();
      }),
    );
    return holder;
  }

  /// Starts a clip that was opened paused. Idempotent.
  void start() {
    final player = _player;
    if (_started || player == null || _dead) return;
    _started = true;
    unawaited(
      player.then((p) {
        if (!_dead && _refs > 0) p?.play();
      }),
    );
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
      // Looped and muted — the pool creates muted, so no audio focus is taken.
      await player.open(_source, playWhenReady: _started, looping: true);
      return player;
    } catch (_) {
      // Native video unavailable — callers keep the solid fallback colour.
      return null;
    }
  }

  /// Stop decode while off-screen. Keeps the decoder and frame -> [resumeFromBackground] is instant.
  /// Idempotent — every mounted [LaunchClipLayer] calls it.
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
        if (!_dead && _refs > 0 && _started) p?.play();
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
    if (pool != null) unawaited(pool.dispose());
  }
}
