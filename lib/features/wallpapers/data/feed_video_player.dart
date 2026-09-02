import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin, typed Dart wrapper over the native Media3 ExoPlayer texture pool
/// (`FeedVideoPlugin` on the Android side) — the wallpaper feed's live previews
/// and the sign-in background video.
///
/// Player + surface REUSE is the whole design -> [FeedVideoPlayerPool.create] makes a session-long
/// player and [FeedVideoPlayer.open] swaps its media (setMediaItem + prepare on the SURVIVING native
/// player + surface) -> never dispose+recreate per swipe, never "simplify" to a per-swap dispose.
/// A fresh Android surface per swipe floods `BLASTBufferQueue ... max frames` and settle jank on
/// budget MediaTek SoCs -> reuse is what avoids it.
/// Native [FeedVideoPlugin] holds ONE MethodChannel, ONE broadcast EventChannel and ONE `eventSink`,
/// and Flutter allows ONE active stream listener -> a second `receiveBroadcastStream().listen(...)`
/// overwrites the first sink and the loser gets NO `firstFrame` / `videoSize` / `error` -> every
/// pool shares one process-global [_FeedVideoChannelHub].
/// Two pools are alive at once (the feed's in `VideoPreloadController`, sign-in's in
/// `VideoBackground`) -> per-pool subscriptions stranded the other pool's cards on a permanent
/// poster/dark-fill (the "only the first live wallpaper renders" bug).
/// The hub also holds every live handle across ALL pools, and native `playerId`s are globally unique
/// (one shared `nextPlayerId`) -> a tagged event reaches its handle whichever pool created it.
/// A pool owns only the handles IT created -> its [dispose] never tears down another pool's players.
class FeedVideoPlayerPool {
  FeedVideoPlayerPool._(this._hub);

  /// Production instance wired to the real, process-global channel hub.
  factory FeedVideoPlayerPool() =>
      FeedVideoPlayerPool._(_FeedVideoChannelHub.instance);

  /// Pays the CDN handshake up front, from the SAME native HTTP stack the player will use — see
  /// `FeedVideoPlugin.warmConnection`.
  ///
  /// Fire and forget -> a failure only means the eventual open pays the handshake itself.
  /// The caller (the entitlement provider) warms it long before any player exists -> static and
  /// pool-free.
  static Future<void> warmConnection(String url) => _FeedVideoChannelHub
      .instance
      .invokeMethod('warmConnection', {'url': url});

  /// Test seam: inject fake channels.
  ///
  /// Each call builds a FRESH hub on those channels and never touches the process-global singleton
  /// -> tests cannot leak channel state into each other or into production. Dispose the returned
  /// pool to tear the hub's subscription down.
  @visibleForTesting
  factory FeedVideoPlayerPool.withChannels(
    MethodChannel method,
    EventChannel events,
  ) => FeedVideoPlayerPool._(_FeedVideoChannelHub.forTesting(method, events));

  /// The shared channel hub — one MethodChannel + one EventChannel subscription for the whole
  /// process, or an isolated one under test.
  final _FeedVideoChannelHub _hub;

  /// Handles created by THIS pool -> [dispose] releases only these, never another pool's.
  final Set<FeedVideoPlayer> _own = {};

  bool _disposed = false;

  /// Creates a native ExoPlayer + its Flutter texture and returns a handle.
  ///
  /// The player and surface live until [FeedVideoPlayer.dispose] -> null means the platform side is
  /// unavailable (e.g. a headless widget test) -> the caller falls back to poster-only.
  /// [audio] opts the native player into real [AudioAttributes], audio focus and volume 1 -> a
  /// preview that ducked the user's music while they only browsed would be a bug -> the feed and the
  /// auth background stay false; the paywall's onboarding voiceover is the one caller passing true.
  Future<FeedVideoPlayer?> create({bool audio = false}) async {
    if (_disposed) return null;
    final res = await _hub.invokeCreate(audio: audio);
    if (res == null) return null;
    final playerId = (res['playerId'] as num).toInt();
    final textureId = (res['textureId'] as num).toInt();
    // The pool can be disposed mid-create (a back press on the paywall's first frame) -> the native
    // player already exists -> returning or dropping it strands a decoder holding audio focus that
    // nothing owns any more.
    if (_disposed) {
      await _hub.invokeMethod('dispose', {'playerId': playerId});
      return null;
    }
    final handle = FeedVideoPlayer._(_hub, playerId, textureId);
    // Hub registration routes tagged events; local ownership keeps dispose to this pool's players.
    _hub.register(handle);
    _own.add(handle);
    return handle;
  }

  /// Disposes ALL native players THIS pool created (teardown) -> a single reuse-pool release goes
  /// through [FeedVideoPlayer.dispose] -> never touches another pool's players on the shared hub.
  Future<void> disposeAll() async {
    if (_disposed) return;
    await _releaseOwned();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // NOT disposeAll(): `_disposed` is already true -> its own guard returns before releasing
    // anything -> every native player leaks. Silent while every caller was muted (the decoder just
    // ran on), audible once the paywall's onboarding clip gained sound — leaving /premium kept the
    // voiceover playing over whatever screen came next.
    await _releaseOwned();
  }

  /// Releases every native player THIS pool created -> callable in either state, since the two
  /// public entry points differ only in whether the pool stays usable afterwards.
  Future<void> _releaseOwned() async {
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
}

/// Process-global owner of the one native MethodChannel and the one EventChannel broadcast
/// subscription, shared by every [FeedVideoPlayerPool].
///
/// Holds the registry of ALL live handles across ALL pools -> each tagged native event fans out to
/// the handle its `playerId` belongs to.
/// The only subscriber in the process -> native sees exactly one `onListen` and one live sink -> no
/// second listener can clobber it.
class _FeedVideoChannelHub {
  _FeedVideoChannelHub(this._method, this._events) {
    _eventSub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {
        // A malformed platform event must never crash the feed -> swallow it; the per-card
        // safety timer still reveals.
      },
    );
  }

  /// The one hub for real platform channels, created lazily on first use.
  static _FeedVideoChannelHub? _instance;
  static _FeedVideoChannelHub get instance =>
      _instance ??= _FeedVideoChannelHub(
        const MethodChannel('com.hsrutility.arul/feed_video'),
        const EventChannel('com.hsrutility.arul/feed_video_events'),
      );

  /// Test seam: a fresh hub on fake channels, never the singleton -> per-test channel isolation.
  factory _FeedVideoChannelHub.forTesting(
    MethodChannel method,
    EventChannel events,
  ) => _FeedVideoChannelHub(method, events);

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _eventSub;

  /// EVERY live handle across ALL pools, keyed by the globally-unique native playerId -> a tagged
  /// event reaches its handle whichever pool owns it.
  final Map<int, FeedVideoPlayer> _byId = {};

  void register(FeedVideoPlayer handle) => _byId[handle.playerId] = handle;

  void unregister(int playerId) => _byId.remove(playerId);

  Future<Map<String, dynamic>?> invokeCreate({bool audio = false}) async {
    try {
      return await _method.invokeMapMethod<String, dynamic>('create', {
        'audio': audio,
      });
    } catch (_) {
      // No platform implementation (tests / unsupported host) -> caller falls back to poster-only.
      return null;
    }
  }

  Future<void> invokeMethod(String method, Map<String, dynamic> args) async {
    try {
      await _method.invokeMethod<void>(method, args);
    } catch (_) {
      // Stale/unknown playerId or a transient platform error -> native treats both as no-ops.
    }
  }

  /// Like [invokeMethod] but for a call returning an int (e.g. a player's last-painted openId).
  ///
  /// Null when the platform side is unavailable or the id is stale -> callers can tell "unknown"
  /// apart from a value.
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

  /// Called when the CURRENT open played to its end. Only a non-looping open
  /// can reach it — a looping player re-enters buffering instead. Unset for
  /// every looping caller (the feed, the auth background); the paywall's
  /// onboarding clip uses it to report that the pitch was watched through.
  void Function()? onEnded;

  /// Called with the decoder name + software flag when the native side reports
  /// which video decoder the current open actually initialized (Media3
  /// `onVideoDecoderInitialized`). A SOFTWARE decoder here means the SoC ran
  /// out of concurrent hardware sessions and ExoPlayer fell back SILENTLY (no
  /// error event fires) — the owning controller uses it as decoder-contention
  /// signal to shrink its window. Stale-guarded by openId like [onError].
  void Function(String name, bool isSoftware)? onDecoder;

  /// True once the current open has errored natively. Reset per [open]. Gates
  /// [forceFirstFrame]: revealing a card whose media never decoded paints a
  /// black texture — worse than the poster it would replace.
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
  /// emits onRenderedFirstFrame can't strand a card on its poster.
  /// No-ops when the current open has ERRORED: its texture never painted, so
  /// revealing it would show a black card — the error path retries instead.
  void forceFirstFrame() {
    if (_disposed || _openErrored) return;
    firstFrame.value = true;
  }

  Future<void> play() => _hub.invokeMethod('play', {'playerId': playerId});

  Future<void> pause() => _hub.invokeMethod('pause', {'playerId': playerId});

  /// Runtime mute / unmute, 0..1. Only meaningful on a player created with
  /// `audio: true` — a muted-by-construction player never took audio focus, so
  /// raising its volume changes nothing the user can hear.
  Future<void> setVolume(double volume) =>
      _hub.invokeMethod('setVolume', {'playerId': playerId, 'volume': volume});

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
          // Reveal mark, readable in profile (and in a DIAG release): the
          // moment a live card's texture actually painted. The baseline harness
          // times cold start → first content from this line, and it answers
          // "nothing is moving" triage (a missing line = never decoded;
          // present = decoded and faded in). Release builds are silent by
          // design — triage this on profile, not on a Play install.
          debugPrint('FeedVideo: first frame revealed player $playerId');
        }
      case 'ended':
        // Non-looping opens only (a looping player never reaches STATE_ENDED).
        // Staleness-matched like firstFrame so a swap cannot deliver the
        // previous clip's ending.
        final openId = (event['openId'] as num?)?.toInt();
        if (openId == null || openId >= _currentOpenId) onEnded?.call();
      case 'videoSize':
        final w = (event['width'] as num?)?.toDouble();
        final h = (event['height'] as num?)?.toDouble();
        if (w != null && h != null && w > 0 && h > 0) {
          videoSize.value = Size(w, h);
        }
      case 'error':
        // Staleness-matched the same way as firstFrame: an error tagged with an
        // openId below the current open belongs to a since-swapped media — drop
        // it. A current-open error keeps the card on its poster (never a black
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
