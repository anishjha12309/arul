import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin, typed Dart wrapper over the native Media3 ExoPlayer texture pool
/// (`FeedVideoPlugin` on the Android side).
///
/// This replaces the `media_kit` runtime for the wallpaper feed's live previews
/// and the sign-in background video. The whole design is **player + surface
/// REUSE**: [FeedVideoPlayerPool.create] makes a player that survives the whole
/// session, and [FeedVideoPlayer.open] swaps its media (setMediaItem + prepare
/// on the SURVIVING native ExoPlayer + surface) — never dispose+recreate per
/// swipe. That reuse is what keeps a swipe from churning a fresh Android
/// surface, which caused the `BLASTBufferQueue ... max frames` flood + settle
/// jank on budget MediaTek SoCs. Do not "simplify" by disposing per swap.
///
/// ## One channel subscription, shared by every pool ([_FeedVideoChannelHub])
///
/// The native [FeedVideoPlugin] exposes exactly ONE `MethodChannel` and ONE
/// broadcast `EventChannel`, with a single native `eventSink`. A Flutter
/// [EventChannel] supports only ONE active stream listener — a second
/// `receiveBroadcastStream().listen(...)` on the same channel triggers a native
/// `onListen` that **overwrites** the first listener's sink, and the losing
/// listener then receives NO `firstFrame` / `videoSize` / `error` events.
///
/// The app has TWO independent [FeedVideoPlayerPool] instances (the feed pool in
/// `VideoPreloadController` and the sign-in background pool in `VideoBackground`)
/// that can be alive at the same time. If each opened its own EventChannel
/// subscription, the second one to listen would steal the sink and strand the
/// other pool's cards on a permanent shimmer/dark-fill — this was the "only the
/// first live wallpaper renders" bug.
///
/// The fix: all pools share a single process-global [_FeedVideoChannelHub] that
/// owns the one MethodChannel and the one EventChannel subscription, plus a
/// global `Map<int, FeedVideoPlayer>` of every live handle across ALL pools.
/// Native `playerId`s are globally unique (native `nextPlayerId` is one shared
/// counter), so each tagged event is routed to the right handle regardless of
/// which pool created it. A [FeedVideoPlayerPool] is now a thin owner of just
/// the handles IT created, so its own [dispose] only tears down its own players.
class FeedVideoPlayerPool {
  FeedVideoPlayerPool._(this._hub);

  /// Production instance wired to the real, process-global channel hub. Named to
  /// match the native [FeedVideoPlugin] channel constants.
  factory FeedVideoPlayerPool() =>
      FeedVideoPlayerPool._(_FeedVideoChannelHub.instance);

  /// Test seam: inject fake channels. Each call builds a FRESH, isolated hub
  /// bound to the given channels (it does NOT touch the process-global
  /// singleton), so tests don't leak channel state into each other or into
  /// production code. Dispose the returned pool to tear the hub's subscription
  /// down.
  @visibleForTesting
  factory FeedVideoPlayerPool.withChannels(
    MethodChannel method,
    EventChannel events,
  ) => FeedVideoPlayerPool._(_FeedVideoChannelHub.forTesting(method, events));

  /// The shared channel hub (one MethodChannel + one EventChannel subscription
  /// for the whole process, or an isolated one under test).
  final _FeedVideoChannelHub _hub;

  /// Handles created by THIS pool, so [dispose] only releases its own players
  /// and never another pool's.
  final Set<FeedVideoPlayer> _own = {};

  bool _disposed = false;

  /// Creates a native ExoPlayer + its Flutter texture and returns a handle. The
  /// underlying player/surface live until [FeedVideoPlayer.dispose]. Returns
  /// null if the platform side is unavailable (e.g. headless widget test).
  Future<FeedVideoPlayer?> create() async {
    if (_disposed) return null;
    final res = await _hub.invokeCreate();
    if (res == null) return null;
    final playerId = (res['playerId'] as num).toInt();
    final textureId = (res['textureId'] as num).toInt();
    final handle = FeedVideoPlayer._(_hub, playerId, textureId);
    // Register on the shared hub (routes tagged events) and record local
    // ownership (so this pool's dispose only frees its own players).
    _hub.register(handle);
    _own.add(handle);
    return handle;
  }

  /// Disposes ALL native players THIS pool created (used on teardown). Individual
  /// reuse-pool releases go through [FeedVideoPlayer.dispose]. Does NOT touch
  /// players owned by another pool sharing the hub.
  Future<void> disposeAll() async {
    if (_disposed) return;
    final own = _own.toList();
    _own.clear();
    for (final h in own) {
      h._markDisposed();
      _hub.unregister(h.playerId);
    }
    for (final h in own) {
      await _hub.invokeMethod('dispose', {'playerId': h.playerId});
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disposeAll();
  }
}

/// Process-global owner of the one native MethodChannel + the one EventChannel
/// broadcast subscription, shared by every [FeedVideoPlayerPool]. Holds the
/// registry of ALL live handles across ALL pools and fans each tagged native
/// event out to the handle its `playerId` belongs to.
///
/// Because Flutter delivers one `onListen` per active stream and this is the
/// only subscriber in the whole process, native gets exactly one `onListen` and
/// one live sink — no second listener can clobber it.
class _FeedVideoChannelHub {
  _FeedVideoChannelHub(this._method, this._events) {
    _eventSub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {
        // A malformed platform event must never crash the feed; ignore it (the
        // per-card safety timer still reveals).
      },
    );
  }

  /// The one hub for real platform channels, created lazily on first use.
  static _FeedVideoChannelHub? _instance;
  static _FeedVideoChannelHub get instance =>
      _instance ??= _FeedVideoChannelHub(
        const MethodChannel('com.hsrapps.arul/feed_video'),
        const EventChannel('com.hsrapps.arul/feed_video_events'),
      );

  /// Test seam: a fresh, isolated hub bound to fake channels (never the
  /// singleton), so each test's channel state is isolated.
  factory _FeedVideoChannelHub.forTesting(
    MethodChannel method,
    EventChannel events,
  ) => _FeedVideoChannelHub(method, events);

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _eventSub;

  /// EVERY live handle across ALL pools, keyed by globally-unique native
  /// playerId, so a tagged event reaches its handle no matter which pool owns it.
  final Map<int, FeedVideoPlayer> _byId = {};

  void register(FeedVideoPlayer handle) => _byId[handle.playerId] = handle;

  void unregister(int playerId) => _byId.remove(playerId);

  Future<Map<String, dynamic>?> invokeCreate() async {
    try {
      return await _method.invokeMapMethod<String, dynamic>('create');
    } catch (_) {
      // No platform implementation (tests / unsupported host) — caller falls
      // back to shimmer-only.
      return null;
    }
  }

  Future<void> invokeMethod(String method, Map<String, dynamic> args) async {
    try {
      await _method.invokeMethod<void>(method, args);
    } catch (_) {
      // Stale/unknown playerId or transient platform error — the native side
      // treats these as no-ops; nothing to do here.
    }
  }

  /// Like [invokeMethod] but for a call that returns an int (e.g. a player's
  /// last-painted openId). Returns null when the platform side is unavailable or
  /// the id is stale, so callers can treat "unknown" distinctly from a value.
  Future<int?> invokeIntMethod(String method, Map<String, dynamic> args) async {
    try {
      return await _method.invokeMethod<int>(method, args);
    } catch (_) {
      return null;
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final playerId = (raw['playerId'] as num?)?.toInt();
    if (playerId == null) return;
    final handle = _byId[playerId];
    if (handle == null) return; // event for a since-disposed player
    handle._dispatch(raw);
  }

  /// Tears the subscription down. Only used by the test hub (the production
  /// singleton lives for the whole process).
  @visibleForTesting
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    _byId.clear();
  }
}

/// A handle to ONE native ExoPlayer + its Flutter texture. Reused across feed
/// indices via [open]; only [dispose] tears down the native player/surface.
class FeedVideoPlayer {
  FeedVideoPlayer._(this._hub, this.playerId, this.textureId);

  final _FeedVideoChannelHub _hub;

  /// Native, process-stable player id. Also the fan-out key for events.
  final int playerId;

  /// Flutter texture id the [Texture] widget renders.
  final int textureId;

  /// Highest `openId` we have asked the native side to open. The native openId
  /// is monotonic and incremented once per native `open()` — which is called
  /// exactly once per Dart [open] — so this stays in lockstep with it. A
  /// `firstFrame` event whose `openId` is BELOW this belongs to a since-swapped
  /// media and is dropped (deterministic staleness guard, complementing the
  /// Dart controller's own open-token).
  int _currentOpenId = 0;

  /// Flips true on the first `firstFrame` event matching the current [open].
  /// Reset to false at the start of each [open]. Per-handle so one card's
  /// readiness rebuilds only that card.
  final ValueNotifier<bool> firstFrame = ValueNotifier<bool>(false);

  /// Native video size once known (for BoxFit.cover scaling of the [Texture]).
  final ValueNotifier<Size?> videoSize = ValueNotifier<Size?>(null);

  /// Called with the `PlaybackException` error-code name (e.g.
  /// `ERROR_CODE_DECODER_INIT_FAILED`) when the CURRENT open's media fails
  /// natively; errors tagged with an older openId (a since-swapped media) are
  /// dropped before this fires. Set by the owning controller to drive its
  /// retry / decoder-budget adaptation; unset (sign-in background) the error
  /// just suppresses the force-reveal below.
  void Function(String codeName)? onError;

  /// Called with the decoder name + software flag when the native side reports
  /// which video decoder the current open actually initialized (Media3
  /// `onVideoDecoderInitialized`). A SOFTWARE decoder here means the SoC ran
  /// out of concurrent hardware sessions and ExoPlayer fell back SILENTLY (no
  /// error event fires) — the owning controller uses it as decoder-contention
  /// signal to shrink its window. Stale-guarded by openId like [onError].
  void Function(String name, bool isSoftware)? onDecoder;

  /// True once the current open has errored natively. Reset per [open]. Gates
  /// [forceFirstFrame]: revealing a card whose media never decoded paints a
  /// black texture — worse than the shimmer it would replace.
  bool _openErrored = false;

  bool _disposed = false;

  /// Swaps this player's media (native setMediaItem + prepare — surface kept).
  /// Resets [firstFrame] to false; it flips true again on the matching native
  /// `firstFrame` event. [url] may be a local absolute path, an https URL, or
  /// an `asset:///flutter_assets/...` URI.
  Future<void> open(
    String url, {
    required bool playWhenReady,
    bool looping = true,
  }) async {
    if (_disposed) return;
    firstFrame.value = false;
    _openErrored = false;
    // Bump in lockstep with the native openId (native increments its own
    // monotonic openId once per open()). A firstFrame from the PREVIOUS media,
    // which can fire around the setMediaItem swap, carries an openId below this
    // and is dropped in _dispatch.
    _currentOpenId++;
    await _hub.invokeMethod('open', {
      'playerId': playerId,
      'url': url,
      'playWhenReady': playWhenReady,
      'looping': looping,
    });
  }

  /// Synchronously hide the currently-shown frame the instant this player is
  /// reassigned to a new index, BEFORE the async [open] runs. A reused player's
  /// native texture still holds the PREVIOUS clip's last painted frame and its
  /// [firstFrame] flag is still true from that clip; [open] only resets the flag
  /// after an awaited disk-cache lookup, so without this the new card would
  /// render the old wallpaper at full opacity in that window. Resets only the
  /// first-frame flag (and the errored flag); it deliberately leaves [videoSize]
  /// alone (it persists across reused opens — a same-dimension clip may not
  /// re-emit onVideoSizeChanged) and does NOT bump [_currentOpenId] (that must
  /// stay in lockstep with the native open, so a late first-frame from the
  /// previous media is still dropped by the staleness guard, not mis-accepted).
  void resetForReassign() {
    if (_disposed) return;
    firstFrame.value = false;
    _openErrored = false;
  }

  /// Whether the native side has actually painted a frame for the CURRENT open
  /// (its `lastPaintedOpenId` has reached our [_currentOpenId]). The controller's
  /// reveal-timeout safety net uses this so it only reveals when the
  /// onRenderedFirstFrame EVENT was lost — not when the clip simply hasn't
  /// decoded yet. Force-revealing the latter on a reused player would flash the
  /// PREVIOUS clip's frozen frame (the "content repeats over cards" bug). Returns
  /// false if the query fails (treat as not-painted → keep the poster).
  Future<bool> hasPaintedCurrentOpen() async {
    if (_disposed) return false;
    final painted = await _hub.invokeIntMethod('paintedOpenId', {
      'playerId': playerId,
    });
    return painted != null && painted >= _currentOpenId;
  }

  /// Safety-net reveal: flip [firstFrame] true without a native event. The Dart
  /// controller calls this from its reveal-timeout timer so a stream that never
  /// emits onRenderedFirstFrame can't strand a card on a permanent shimmer.
  /// No-ops when the current open has ERRORED: its texture never painted, so
  /// revealing it would show a black card — the error path retries instead.
  void forceFirstFrame() {
    if (_disposed || _openErrored) return;
    firstFrame.value = true;
  }

  Future<void> play() => _hub.invokeMethod('play', {'playerId': playerId});

  Future<void> pause() => _hub.invokeMethod('pause', {'playerId': playerId});

  /// Stops playback, releasing the codec while KEEPING the native player and
  /// its surface (Media3 STATE_IDLE holds "only limited resources"; a later
  /// [open] re-prepares on the same surface). Used to hand a scarce decoder to
  /// a higher-priority index on codec-starved SoCs — never per scroll.
  Future<void> stop() => _hub.invokeMethod('stop', {'playerId': playerId});

  /// Releases the native ExoPlayer + its SurfaceProducer. Only ever called on
  /// pool release / teardown — never per scroll.
  Future<void> dispose() async {
    if (_disposed) return;
    _markDisposed();
    _hub.unregister(playerId);
    await _hub.invokeMethod('dispose', {'playerId': playerId});
  }

  void _markDisposed() {
    if (_disposed) return;
    _disposed = true;
    firstFrame.dispose();
    videoSize.dispose();
  }

  void _dispatch(Map<dynamic, dynamic> event) {
    if (_disposed) return;
    switch (event['event'] as String?) {
      case 'firstFrame':
        // We can't know the native openId returned by open() synchronously (the
        // MethodChannel call is async), so match against the highest openId we
        // asked for. The native side echoes its own monotonic openId which is
        // >= ours; a frame from a since-swapped media carries an older openId.
        final openId = (event['openId'] as num?)?.toInt();
        if (openId != null && openId >= _currentOpenId) {
          _currentOpenId = openId;
          firstFrame.value = true;
        }
      case 'videoSize':
        final w = (event['width'] as num?)?.toDouble();
        final h = (event['height'] as num?)?.toDouble();
        if (w != null && h != null && w > 0 && h > 0) {
          videoSize.value = Size(w, h);
        }
      case 'error':
        // Staleness-matched the same way as firstFrame: an error tagged with an
        // openId below the current open belongs to a since-swapped media — drop
        // it. A current-open error keeps the card on shimmer (never a black
        // force-reveal) and is surfaced to the controller, which retries /
        // shrinks the decoder window on budget SoCs.
        final openId = (event['openId'] as num?)?.toInt();
        if (openId == null || openId >= _currentOpenId) {
          _openErrored = true;
          onError?.call(
            event['codeName'] as String? ?? 'ERROR_CODE_UNSPECIFIED',
          );
        }
      case 'decoder':
        // Same staleness guard: a decoder report for a since-swapped media is
        // meaningless for the current open — drop it.
        final openId = (event['openId'] as num?)?.toInt();
        if (openId == null || openId >= _currentOpenId) {
          onDecoder?.call(
            event['name'] as String? ?? '',
            event['isSoftware'] == true,
          );
        }
    }
  }
}
