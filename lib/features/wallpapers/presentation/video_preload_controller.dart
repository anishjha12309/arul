import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../data/models/wallpaper.dart';
import '../data/feed_video_player.dart';
import '../data/wallpaper_prefetch_service.dart';

/// How long the feed must rest on a page before its player is (re)assigned and
/// its media opened. A fast multi-page fling snaps PageView through intermediate
/// pages, firing onPageChanged for each; without this gate every passing page
/// would re-`open()` a player, churning demuxer/decoder work faster than it
/// settles. While settling we mount nothing new (shimmer only) and reassign no
/// players.
const Duration _settleDebounce = Duration(milliseconds: 160);

/// A live-video slot handed to the UI for one index: the native texture id its
/// card mounts a [Texture] widget with, the video's intrinsic size (for
/// BoxFit.cover scaling), plus a per-item first-frame flag.
///
/// [ready] is a [ValueListenable] (not a plain bool) so each card subscribes
/// only to ITS OWN first-frame flip — a readiness tick rebuilds just that one
/// card, never the whole feed (the key to jank-free scrolling with several live
/// players in flight).
class LiveVideoSlot {
  const LiveVideoSlot({
    required this.index,
    required this.playerId,
    required this.textureId,
    required this.videoSize,
    required this.ready,
  });

  /// Feed index this slot serves.
  final int index;

  /// Stable identity of the pooled player backing this slot. The card MUST key
  /// its [Texture] widget by this (not by [index]): the reuse pool reassigns a
  /// physical player to different indices over the session, so when the player
  /// serving an index changes, the card must rebind to the NEW player's
  /// textureId + notifiers. Keying by [playerId] forces a fresh element with the
  /// correct bindings; keying by [index] would leave a stale element pointing at
  /// the wrong (reassigned) player's texture.
  final int playerId;

  /// The native texture id the card renders via a [Texture] widget. Owned and
  /// lifecycle-managed by the reuse pool (survives reassignment).
  final int textureId;

  /// The backing video's intrinsic size once known, for BoxFit.cover scaling of
  /// the [Texture] (a raw [Texture] does not scale itself). Null until the
  /// native `videoSize` event arrives — while null the shimmer covers the card.
  final ValueListenable<Size?> videoSize;

  /// Per-item first-frame flag the card listens to in isolation.
  final ValueListenable<bool> ready;
}

/// One pooled native player: a [FeedVideoPlayer] handle (ExoPlayer + its Flutter
/// texture) plus the per-item bookkeeping that drives reveal.
///
/// **A pooled player is created ONCE and reused across feed indices** — its
/// native ExoPlayer, its Flutter [Texture], and the Android surface behind them
/// survive every scroll. Moving to a new index is a [FeedVideoPlayer.open]
/// (setMediaItem + prepare on the surviving player + surface), never a
/// dispose+recreate. This is the whole point of the reuse pool: recreating the
/// player per swipe allocated a fresh Android surface each time, and that
/// surface churn — not the decode — is what produced the settle-frame jank and
/// the `BLASTBufferQueue: acquireNextBuffer ... Already acquired max frames`
/// flood on budget MediaTek SoCs (each new surface renegotiates the display
/// refresh rate). Reuse keeps the surface alive, so a swipe is just a media swap.
class _PooledPlayer {
  _PooledPlayer({required this.handle});

  /// The native player handle. Its [FeedVideoPlayer.playerId] is the stable,
  /// process-unique identity surfaced to the UI as [LiveVideoSlot.playerId], so
  /// a card keys its [Texture] by the physical player (which survives
  /// reassignment) rather than by feed index.
  final FeedVideoPlayer handle;

  int get id => handle.playerId;

  /// Feed index this player currently serves, or -1 when idle (created but not
  /// yet assigned — e.g. a freed player waiting to be reassigned in the next
  /// [_reconcile]).
  int servingIndex = -1;

  /// Per-item first-frame flag, owned by the native handle (the card holds a
  /// reference via the slot). Reset to false before each new
  /// [FeedVideoPlayer.open] and flips true again when the native side reports
  /// the new media's first painted frame (onRenderedFirstFrame).
  ValueListenable<bool> get ready => handle.firstFrame;

  /// Native video size for BoxFit.cover scaling, owned by the native handle.
  ValueListenable<Size?> get videoSize => handle.videoSize;

  /// Bumped on every reassignment. A rapid fling can reassign the same player
  /// twice before the first [_setupAndOpen] finishes awaiting the disk-cache
  /// lookup; the stale in-flight setup checks this token and abandons so it
  /// can't open the wrong media onto a since-reassigned player.
  int openToken = 0;

  /// Decoder-error retries consumed by the CURRENT open (reset on every
  /// reassignment). The first error on an open gets a plain retry; a second
  /// error on the same open proves real codec starvation and demotes the
  /// session decoder budget.
  int retriesThisOpen = 0;

  /// True once the CURRENT open's silent software-decoder fallback has been
  /// acted on (reset on every reassignment), so one open can demote the
  /// session budget at most once even if the native side re-reports.
  bool swFallbackHandled = false;

  /// Safety-net timer: reveals the card even if the native `firstFrame` event
  /// never arrives (a driver/stream quirk), so a card can't strand on a
  /// permanent shimmer. With onRenderedFirstFrame this should rarely fire. Reset
  /// per open.
  Timer? _revealTimer;

  Future<void> dispose() async {
    _revealTimer?.cancel();
    // Releases the native ExoPlayer + its SurfaceProducer (frees the decoder AND
    // the Android surface) and disposes the handle's notifiers. Only ever called
    // from releaseDecoders / dispose — never per scroll.
    await handle.dispose();
  }
}

/// Drives the Shorts-style live-video previews over a small **fixed reuse pool**
/// of native Media3 ExoPlayer texture players, backed by a separate disk
/// byte-prefetcher.
///
/// **Two decoupled windows** — the key to fast previews on budget SoCs:
///   - **Data window** ([WallpaperPrefetchService], `_ahead` items): downloads
///     upcoming MP4 *bytes* to disk far ahead of the user. No player, no decoder
///     — just network + disk — so we can read many items ahead cheaply. By the
///     time a card becomes current its bytes are already local.
///   - **Decoder window** ([_keepBehind] behind, [_preloadAhead] ahead): the
///     only place real ExoPlayers (and thus hardware decoders + surfaces) exist.
///     Kept to **previous + current + next** (3 players) so a back-swipe lands on
///     a pre-decoded first frame just like a forward swipe (symmetric
///     scrolling). Each held decoder is a scarce resource on budget MediaTek
///     SoCs, and the live-wallpaper service permanently claims one once a live
///     wallpaper is applied — so 3 is the hard ceiling here.
///
/// **Reuse, not recreate** — the pool holds at most [_poolSize] `_PooledPlayer`s
/// for the whole session. On a page change [_reconcile] reassigns players to the
/// new window indices via [FeedVideoPlayer.open] (a media swap) instead of
/// disposing the player that scrolled out and constructing a new one for the
/// player that scrolled in. Recreating per swipe allocated a fresh native
/// surface each time, and that surface create/destroy churn is what caused the
/// settle-frame jank + the `BLASTBufferQueue ... max frames` flood on budget
/// MediaTek panels. Keeping the surfaces alive turns a swipe into just a media
/// swap. Players are disposed only on [releaseDecoders] (apply / background) and
/// [dispose] (never per scroll).
///
/// Strategy ("strict 1 playing, next pre-buffered, all from disk"):
///   - Players open the **prefetched local file** when present (instant first
///     frame, no network), falling back to the CDN URL only when the data window
///     hasn't reached the item yet (cold start / very first item).
///   - Only the CURRENT index plays. The windowed neighbours (previous and next)
///     are opened with `playWhenReady: false` so ExoPlayer decodes and paints
///     their first frame (instant swap on a swipe in either direction) but they
///     do not keep playing.
///   - A live item outside the window is served by no player (its card shows
///     shimmer), and its player has been reassigned to an in-window index.
///   - On background, every player is disposed ([releaseDecoders]) so the OEM
///     live-wallpaper chooser / our own wallpaper service can claim a decoder;
///     the pool re-creates lazily on resume.
class VideoPreloadController extends ChangeNotifier
    with WidgetsBindingObserver {
  VideoPreloadController({
    required this.cdnBaseUrl,
    required WallpaperPrefetchService prefetch,
    FeedVideoPlayerPool? pool,
  }) : _prefetch = prefetch, // ignore: prefer_initializing_formals
       _pool = pool ?? FeedVideoPlayerPool() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// CDN base used to build the public stream URL for live previews.
  final String cdnBaseUrl;

  /// Downloads upcoming live MP4 bytes to disk ahead of the decoder window so
  /// players open from a local file. Owns no decoders.
  ///
  /// **Injected, app-scoped, NOT owned by this controller** — it is the shared
  /// [wallpaperPrefetchServiceProvider] instance so the root warm prefetch
  /// (started during splash) and this controller's per-page prefetch share one
  /// in-flight queue. Therefore [dispose] must NOT dispose it (the provider
  /// does); doing so would kill prefetching for the next controller instance.
  final WallpaperPrefetchService _prefetch;

  /// The native player pool (channel wrapper). Owned by this controller: it is
  /// created per controller instance and torn down in [dispose].
  final FeedVideoPlayerPool _pool;

  // Decoder-window radius around the current index (live items within it get a
  // real player). keepBehind = 1 keeps the PREVIOUS item's player alive too, so
  // a back-swipe lands on an already-decoded first frame (instant, no shimmer)
  // exactly like a forward swipe — symmetric scrolling. Cost: at most
  // previous + current + next = 3 concurrent decoders. That's one more than the
  // budget-SoC-minimal 2, and is only affordable because players open from the
  // disk prefetch (not a cold network stream), only the current index plays
  // actively (the two neighbours sit paused on their first frame), AND the pool
  // reuses players across indices (no per-swipe surface/decoder churn). 3
  // concurrent ExoPlayer decoders is the ceiling on the lowest-end target SoC
  // (the live-wallpaper service permanently claims one once a live wallpaper is
  // applied), so re-verify deep-scroll stability on a real budget device.
  static const _keepBehind = 1;
  static const _preloadAhead = 1;

  /// Fixed maximum number of pooled players = the full window width
  /// (previous + current + next). The pool never grows past this; a page change
  /// reassigns existing players rather than allocating new ones.
  static const _poolSize = _keepBehind + 1 + _preloadAhead;

  /// **Adaptive decoder budget** — how many concurrent decoders the feed may
  /// hold, session-sticky (static: survives feed-screen remounts, resets on app
  /// restart so a device under transient pressure gets a fresh try).
  ///
  /// Starts at the full window ([_poolSize] = 3) so capable devices keep the
  /// exact previous+current+next pipeline. Budget SoCs cap concurrent hardware
  /// decoder instances (commonly at 2) below that; the 3rd `prepare()` then
  /// fails codec init (`ERROR_CODE_DECODER_INIT_FAILED`) and, before this
  /// budget existed, its card stayed a permanent black/shimmer. Capability
  /// APIs (getMaxSupportedInstances) lie in both directions, so instead of
  /// trusting them we **attempt-and-degrade**: a REPEATED decoder-class error
  /// on the same open demotes the budget by one ([_demoteBudget]) — dropping
  /// the previous-index slot first (back-swipe shimmers briefly), worst case
  /// current-only. Devices that never error never demote.
  static int _decoderBudget = _poolSize;

  /// Effective window radii under the current [_decoderBudget]:
  /// budget 3 → previous+current+next, 2 → current+next, 1 → current only.
  int get _effKeepBehind => _decoderBudget >= 3 ? _keepBehind : 0;
  int get _effPreloadAhead => _decoderBudget >= 2 ? _preloadAhead : 0;

  /// Delay before re-`open()`ing an errored media. Long enough for the codec
  /// the retry needs (freed via [FeedVideoPlayer.stop] on a neighbour, or by
  /// another app) to actually be released; short enough to beat the user's
  /// next glance.
  static const _errorRetryDelay = Duration(milliseconds: 250);

  /// Decoder-error retries allowed per open before giving up (the card stays
  /// on shimmer; the next reconcile — swipe or refresh — tries again fresh).
  static const _maxRetriesPerOpen = 2;

  /// Upper bound on how long a card holds its shimmer waiting for the first
  /// frame. With the native onRenderedFirstFrame event the reveal normally fires
  /// well before this; it exists purely so a driver/stream quirk that never
  /// emits a first frame can't strand the card on a permanent shimmer. The
  /// native handle's own [FeedVideoPlayer.firstFrame] flip is the primary path.
  static const _revealTimeout = Duration(milliseconds: 300);

  int _currentIndex = 0;
  List<Wallpaper> _wallpapers = const [];
  bool _disposed = false;
  bool _appPaused = false;

  /// True between a page change and the [_settleDebounce] firing. While set, no
  /// player is reassigned (the feed shows shimmer for not-yet-served indices) so
  /// a fast fling triggers no `open()` churn. Reconcile runs once the feed rests.
  bool _settling = false;
  Timer? _settleTimer;

  /// The fixed reuse pool. Grows lazily up to [_poolSize] as the window first
  /// needs players, then is reused for the session (only cleared by
  /// [releaseDecoders] / [dispose]). A player with `servingIndex == -1` is idle
  /// and available for reassignment.
  final List<_PooledPlayer> _pool_ = [];

  /// True while an async native `create()` is in flight for a would-be pool
  /// slot, so concurrent [_assignPlayer] calls (a fast fling) don't over-create
  /// beyond [_poolSize].
  int _creating = 0;

  // ─── Public API (unchanged surface for the screen) ───────────────────────────

  /// The slot serving [index], or null if that item is static / outside the
  /// current preload window / has no player assigned yet.
  ///
  /// Deliberately does NOT withhold the slot while [_settling]. The settle gate
  /// only debounces player *reassignment* (in [_reconcile]); it must not unmount
  /// a player that is ALREADY serving an in-window index. Dropping every slot on
  /// page-change tore down the just-landed card's texture for the settle window
  /// and remounted it after — and since that player's first frame was already
  /// decoded (its `ready` flag already true, shimmer already faded), the
  /// remounted texture flashed its dark `fill` for a frame or two before
  /// re-attaching: the live-scroll black blink. Keeping an in-window served slot
  /// mounted means a swipe onto a pre-decoded neighbour shows its (paused) frame
  /// continuously — no teardown, no blink. Indices with no serving player still
  /// return null (shimmer), so a fast fling past not-yet-assigned players is
  /// unaffected.
  LiveVideoSlot? slotForIndex(int index) {
    if (index < 0 || index >= _wallpapers.length) return null;
    if (_wallpapers[index].kind != WallpaperKind.live) return null;
    if (!_inWindow(index)) return null;
    final pooled = _playerServing(index);
    if (pooled == null) return null; // not assigned yet (reconcile is async)
    return LiveVideoSlot(
      index: index,
      playerId: pooled.id,
      textureId: pooled.handle.textureId,
      videoSize: pooled.videoSize,
      ready: pooled.ready,
    );
  }

  /// Call when the viewer opens, or the list changes (pagination, refresh).
  ///
  /// [initialIndex] must be the page the viewer is actually opening on. Without
  /// it the reconcile below runs against the PREVIOUS `_currentIndex` — 0 on a
  /// first open, or wherever the last viewer left off — so the pool opens and
  /// prefetches the wrong clips (up to three multi-megabyte downloads) before the
  /// settle debounce re-targets the real page ~160ms later. The reference never
  /// hit this: its pager WAS the home screen and always entered at page 0. A
  /// viewer you tap into at an arbitrary index is the new case.
  void setWallpapers(List<Wallpaper> wallpapers, {int? initialIndex}) {
    _wallpapers = wallpapers;
    if (initialIndex != null &&
        initialIndex >= 0 &&
        initialIndex < wallpapers.length) {
      _currentIndex = initialIndex;
    }
    _reconcile();
  }

  /// Detach from the surface that was showing video. Called by the viewer, and
  /// ONLY on the way out.
  ///
  /// The controller is app-scoped, so its list and index outlive the viewer —
  /// deliberately, because that is what survives the Android 12+ Activity recreate
  /// a wallpaper apply triggers. But it also means a stale, non-empty list sits
  /// here after the viewer pops, and the `resumed` lifecycle handler reconciles
  /// unconditionally. Background the app while on the GRID and come back, and the
  /// pool would create ExoPlayers and start playing a clip with no viewer on
  /// screen: decoders, battery and heat spent on something nobody can see.
  ///
  /// Clearing the list is what makes `resumed` a no-op unless a viewer is actually
  /// mounted — `_reconcile` already early-returns on an empty list.
  void detach() {
    _wallpapers = const [];
    _currentIndex = 0;
    unawaited(releaseDecoders());
  }

  /// Splash-gate hook: warm ONLY the first item's decoder and begin decoding so
  /// the branded splash can be held until the top live wallpaper has painted its
  /// first frame (no shimmer on reveal). Deliberately limited to a SINGLE decoder
  /// — not the usual previous/current/next window — so it's safe to call even
  /// while the sign-in background video still holds one, staying within the
  /// budget-SoC concurrent-decoder limit. The normal current±1 window takes over
  /// once the feed screen mounts and calls [setWallpapers] / [onPageChanged].
  ///
  /// Returns the first item's first-frame [ValueListenable] when a LIVE item is
  /// being warmed (the gate reveals when it flips true), or null when there's
  /// nothing to decode here — empty feed, app backgrounded, or a static first
  /// item (the gate reveals those via image decode instead).
  ValueListenable<bool>? prewarmFirst(List<Wallpaper> wallpapers) {
    if (_disposed || wallpapers.isEmpty || _appPaused) return null;
    _wallpapers = wallpapers;
    _currentIndex = 0;
    if (wallpapers.first.kind != WallpaperKind.live) return null;
    // Pull the look-ahead bytes to disk so this player (and the next one the feed
    // promotes on swipe) open from a local file rather than a cold stream.
    _prefetch.prefetchAround(wallpapers, 0);
    final existing = _playerServing(0);
    if (existing != null) return existing.ready;
    // Return a proxy notifier that mirrors the async-created player's first
    // frame, so the caller can subscribe synchronously even though native
    // create() is async. It resolves the moment the player is created + opened.
    return _assignPlayerReady(0, playWhenReady: true);
  }

  /// Disposes every pooled player immediately (apply / decoder-constrained
  /// platform action). The pool re-creates lazily as cards become active again.
  ///
  /// The returned future completes once every native player has finished its
  /// platform `dispose` (codec + surface actually freed — the native handler
  /// releases synchronously before replying). The apply flow AWAITS this right
  /// before the native wallpaper call so the OS chooser/engine deterministically
  /// finds the hardware decoders free; fire-and-forget call sites (lifecycle
  /// pause, screen dispose) just ignore the future.
  Future<void> releaseDecoders() async {
    if (_disposed) return;
    // Cancel any pending settle so the timer can't reassign a player right
    // after we've released them all (e.g. release fired during a fling).
    _settleTimer?.cancel();
    _settling = false;
    // Invalidate any player creation still in flight. Without this, a
    // `_pool.create()` that was awaiting when release ran lands AFTERWARDS, is
    // added to the pool we just emptied, and gets opened and played — holding a
    // hardware decoder that the apply flow has already promised the OS is free, or
    // running invisibly after the viewer closed. The post-create guard only
    // checked `_appPaused`, which catches backgrounding but NOT a release while
    // the app is foreground — and foreground release is now the common case
    // (viewer dispose, and the awaited release inside apply).
    _releaseEpoch++;
    final players = _pool_.toList();
    _pool_.clear();
    final disposals = [for (final p in players) p.dispose()];
    notifyListeners(); // cards re-read slotForIndex → shimmer
    await Future.wait(disposals);
  }

  /// Bumped by every [releaseDecoders]. A player creation snapshots this before
  /// it awaits and discards itself if the value moved while it was in flight.
  int _releaseEpoch = 0;

  /// Rebuilds the player window after an apply that kept the app FOREGROUND
  /// (in-place live swap, static apply, or a failed apply). [releaseDecoders]
  /// used to be reclaimed only by the resumed-lifecycle reconcile — which never
  /// fires when no chooser/backgrounding happened, stranding every live card on
  /// a permanent shimmer. No-op while backgrounded (the resume path owns that
  /// case) and idempotent when the pool is already serving (reconcile reassigns
  /// nothing).
  void reclaimDecoders() {
    if (_disposed || _appPaused) return;
    _reconcile();
  }

  /// Call whenever [PageView.onPageChanged] fires.
  ///
  /// The index is recorded immediately, but player reassignment is debounced by
  /// [_settleDebounce]: a fast multi-page fling fires this once per intermediate
  /// page, and re-`open()`ing a player for each would churn decoders. We instead
  /// enter the "settling" state — reassign nothing, pause what was playing — and
  /// only rebuild the window once the feed comes to rest.
  Future<void> onPageChanged(int index) async {
    if (_disposed) return;
    _currentIndex = index;

    // Enter settling: pause every player so nothing plays during the scroll,
    // then rebuild the feed subtree. Already-serving in-window cards keep their
    // slot (their Texture stays mounted, showing a paused frame — no teardown);
    // not-yet-served cards still read null and show shimmer. Player
    // *reassignment* is what's debounced, in the _reconcile below.
    final wasSettling = _settling;
    _settling = true;
    if (!_appPaused) _pauseAll();
    if (!wasSettling) notifyListeners(); // re-read slotForIndex

    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDebounce, () {
      if (_disposed) return;
      _settling = false;
      _reconcile();
    });
  }

  // ─── Window reconciliation ────────────────────────────────────────────────────

  bool _inWindow(int index) {
    final start = max(0, _currentIndex - _effKeepBehind);
    final end = min(_wallpapers.length - 1, _currentIndex + _effPreloadAhead);
    return index >= start && index <= end;
  }

  /// The pooled player currently serving [index], or null if none is.
  _PooledPlayer? _playerServing(int index) {
    for (final p in _pool_) {
      if (p.servingIndex == index) return p;
    }
    return null;
  }

  /// Recomputes player→index assignments to exactly match the window WITHOUT
  /// disposing players: players already serving an in-window live index stay put
  /// (their surface + decoded frame are preserved), players serving a stale
  /// index are freed and reassigned via [FeedVideoPlayer.open] to an in-window
  /// index that lacks one, and play state is set so ONLY the current index plays
  /// actively. New players are created only until the pool reaches [_poolSize].
  /// Notifies listeners so the feed's itemBuilder re-reads [slotForIndex].
  void _reconcile() {
    if (_disposed || _wallpapers.isEmpty) return;

    // Target set: the live indices inside the current window that deserve a
    // player (previous + current + next under the full decoder budget, shrunk
    // on codec-starved SoCs; clamped to the list, live-only).
    final start = max(0, _currentIndex - _effKeepBehind);
    final end = min(_wallpapers.length - 1, _currentIndex + _effPreloadAhead);
    final wanted = <int>[
      for (var i = start; i <= end; i++)
        if (_wallpapers[i].kind == WallpaperKind.live) i,
    ];

    // 1. Free any player whose current index left the window / is no longer
    //    live. Freeing = mark idle + pause; the player and its surface are KEPT
    //    for reassignment (no dispose → no surface churn).
    for (final p in _pool_) {
      final idx = p.servingIndex;
      final stillWanted =
          idx >= 0 &&
          idx < _wallpapers.length &&
          _wallpapers[idx].kind == WallpaperKind.live &&
          wanted.contains(idx);
      if (!stillWanted && idx != -1) {
        p.servingIndex = -1;
        unawaited(p.handle.pause());
      }
    }

    if (_appPaused) {
      notifyListeners();
      return;
    }

    // Drive the data window: pull upcoming live MP4s to disk (no decoders) so
    // the players (re)opened here, and the next item we promote on swipe, open
    // from a local file instead of a cold network stream.
    _prefetch.prefetchAround(_wallpapers, _currentIndex);

    // 2. Assign a player to every wanted index that doesn't already have one,
    //    reusing an idle player (open() = media swap) or creating a new one only
    //    while the pool is below _poolSize. Then set play state: current plays,
    //    windowed neighbours stay paused on their pre-decoded first frame.
    for (final i in wanted) {
      final existing = _playerServing(i);
      if (existing == null) {
        _assignPlayer(i, playWhenReady: i == _currentIndex);
      } else if (i == _currentIndex) {
        unawaited(existing.handle.play());
      } else {
        unawaited(existing.handle.pause());
      }
    }

    // Any player STILL idle here was wanted by no window index this pass — the
    // window shrank (decoder-budget demotion) or live items thinned out. A
    // paused player keeps its codec; stop() releases it (surface + player
    // survive for later reassignment) so an idle slot can't starve a wanted
    // one on codec-capped SoCs. Under the full budget every freed player is
    // reassigned in the loop above, so this is a no-op on healthy devices.
    // (Reused players get servingIndex synchronously in _assignPlayerAsync;
    // only a brand-new create() is still in flight here, and that player isn't
    // in _pool_ yet — so nothing wanted is ever stopped.)
    for (final p in _pool_) {
      if (p.servingIndex == -1) {
        p.openToken++; // abandon any in-flight setup/reveal for the old media
        unawaited(p.handle.stop());
      }
    }

    notifyListeners();
  }

  /// Assigns a pooled player to serve [index] and opens its media, returning the
  /// player's first-frame [ValueListenable] once assignment begins, or null if
  /// none is available / the app is paused. See [_assignPlayer].
  ValueListenable<bool>? _assignPlayerReady(
    int index, {
    required bool playWhenReady,
  }) {
    final existing = _playerServing(index);
    if (existing != null) return existing.ready;
    // Kick the async assignment and expose a proxy notifier that mirrors the
    // player's first frame as soon as it exists.
    final proxy = _FirstFrameProxy();
    unawaited(() async {
      final pooled = await _assignPlayerAsync(
        index,
        playWhenReady: playWhenReady,
      );
      if (pooled == null) {
        proxy.detach();
        return;
      }
      proxy.bind(pooled.ready);
    }());
    return proxy;
  }

  /// Fire-and-forget assignment used from [_reconcile].
  void _assignPlayer(int index, {required bool playWhenReady}) {
    unawaited(_assignPlayerAsync(index, playWhenReady: playWhenReady));
  }

  /// Assigns a pooled player to serve [index] and opens its media, REUSING an
  /// idle player when one exists and only creating a brand-new native player
  /// while the pool is under [_poolSize]. Returns the player, or null if none is
  /// available or the app is paused.
  ///
  /// This is the reuse hot path: for an idle player the native ExoPlayer +
  /// surface created on its first-ever assignment are kept; we just re-open new
  /// media on it. Only the very first [_poolSize] assignments of the session
  /// allocate a native surface.
  Future<_PooledPlayer?> _assignPlayerAsync(
    int index, {
    required bool playWhenReady,
  }) async {
    if (_appPaused || _disposed) return null;

    // Prefer an idle (already-created, unassigned) player — reuse its surface.
    _PooledPlayer? pooled;
    for (final p in _pool_) {
      if (p.servingIndex == -1) {
        pooled = p;
        break;
      }
    }

    // No idle player and room to grow → create a fresh native player (allocates
    // a surface, one-time cost per pool slot). _creating guards against a fling
    // over-creating past the cap while a create() is in flight. The cap is the
    // lower of the structural pool size and the adaptive decoder budget — once
    // the budget has been demoted there's no point allocating a player the
    // window will never use.
    if (pooled == null) {
      if (_pool_.length + _creating >= min(_poolSize, _decoderBudget)) {
        return null;
      }
      _creating++;
      // Snapshot the release epoch BEFORE awaiting, so we can tell whether a
      // release happened while this create was in flight.
      final epoch = _releaseEpoch;
      FeedVideoPlayer? handle;
      try {
        handle = await _pool.create();
      } finally {
        _creating--;
      }
      // The pool may have been released while create() awaited, or the app paused
      // — drop the freshly-created player instead of adding it to a pool that was
      // just emptied. The epoch check is what covers a release that happened while
      // the app stayed FOREGROUND (viewer dispose, the awaited release inside
      // apply); `_appPaused` alone only catches backgrounding, so without it a
      // late-landing player would hold a hardware decoder the apply flow had
      // already promised the OS was free.
      if (handle == null || _disposed || _appPaused || _releaseEpoch != epoch) {
        unawaited(handle?.dispose());
        return null;
      }
      pooled = _PooledPlayer(handle: handle);
      // Wire native playback errors (already staleness-filtered by openId in
      // the handle) into the retry / decoder-budget adaptation. The handle is
      // stable for the pooled player's whole life, so wire once here.
      final errPooled = pooled;
      handle.onError = (codeName) => _onPlayerError(errPooled, codeName);
      // Silent software-decoder fallback (no error fires — see the handle doc)
      // is the OTHER decoder-contention signal; same lifetime wiring.
      handle.onDecoder = (name, isSoftware) =>
          _onDecoderReported(errPooled, name, isSoftware);
      _pool_.add(pooled);
    }

    pooled.servingIndex = index;
    // New media on this player: reset the first-frame flag; the native
    // onRenderedFirstFrame event flips it true again once the new media paints.
    // (open() itself resets the handle's firstFrame notifier too.)
    final token = ++pooled.openToken;
    pooled.retriesThisOpen = 0;
    pooled.swFallbackHandled = false;

    // When the pool was EMPTY (post-releaseDecoders resume / reclaim), this
    // player was created by an async native create() that lands AFTER
    // _reconcile's own notifyListeners already fired — the feed is still
    // holding a null slot for this index and, with no later notify, the card
    // stays on shimmer forever while the video decodes invisibly (stuck
    // shimmer after background→resume; any swipe masked it by re-notifying).
    // Notify now that slotForIndex returns this player. Harmless duplicate on
    // the reused-player path.
    notifyListeners();

    // Safety net: reveal even if the native first-frame event never arrives
    // within _revealTimeout, so a driver/stream quirk can't strand this card on
    // a permanent shimmer.
    _armReveal(pooled, index, token);

    await _setupAndOpen(pooled, index, token, playWhenReady: playWhenReady);
    return pooled;
  }

  /// (Re)arms the shimmer-timeout reveal for [pooled]'s current open. Guarded
  /// by [token] + serving index so a since-reassigned player never reveals; the
  /// handle itself additionally refuses to force-reveal an ERRORED open (black
  /// texture — the error path retries instead).
  void _armReveal(_PooledPlayer pooled, int index, int token) {
    pooled._revealTimer?.cancel();
    pooled._revealTimer = Timer(_revealTimeout, () {
      if (_disposed ||
          pooled.openToken != token ||
          pooled.servingIndex != index) {
        return;
      }
      pooled.handle.forceFirstFrame();
    });
  }

  Future<void> _setupAndOpen(
    _PooledPlayer pooled,
    int index,
    int token, {
    required bool playWhenReady,
  }) async {
    // Guard: the list may have shrunk (refresh) between assignment and here.
    if (index < 0 || index >= _wallpapers.length) return;
    // Capture the network URL now — it's both the disk-cache key and the
    // streaming fallback.
    final url = _prefetch.urlFor(_wallpapers[index]);

    // Prefer the prefetched local file (instant first frame, no network round
    // trip). Falls back to the CDN URL when the data window hasn't reached this
    // item yet — ExoPlayer then streams it progressively (source is +faststart).
    final localPath = await _prefetch.cachedPathOrNull(url);

    // A rapid fling may have reassigned this player (or released the pool) while
    // we awaited the disk lookup. openToken changing means a newer open() owns
    // this player now — abandon so we don't stomp its media.
    if (_disposed ||
        pooled.openToken != token ||
        pooled.servingIndex != index ||
        _appPaused) {
      return;
    }

    // open() with playWhenReady=false so the first frame is decoded & painted
    // even for a paused neighbour; the current index passes true. Re-opening on
    // a reused player swaps the media without touching the surface. Looping so
    // the short preview repeats seamlessly.
    await pooled.handle.open(
      localPath ?? url,
      playWhenReady: playWhenReady,
      looping: true,
    );
  }

  // ─── Decoder-error adaptation (budget SoCs) ───────────────────────────────────

  /// The decoder-contention error class: codec init/query failures, decode
  /// failures, format-exceeds-capabilities and resources-reclaimed all share
  /// the `ERROR_CODE_DECODER_*` / `ERROR_CODE_DECODING_*` prefixes (Media3
  /// PlaybackException 4001–4006). Matched by NAME so we don't depend on the
  /// numeric values. Network/source errors are excluded — retrying those on a
  /// smaller window wouldn't help.
  static bool _isDecoderError(String codeName) =>
      codeName.startsWith('ERROR_CODE_DECODER') ||
      codeName.startsWith('ERROR_CODE_DECODING');

  /// Native playback error on the media [pooled] is currently serving.
  ///
  /// This is the budget-SoC self-tuning path (capable devices never enter it):
  ///   1. First decoder-class error on an open → plain retry after
  ///      [_errorRetryDelay]. If the failing index is the CURRENT one, the
  ///      farthest window neighbour is [FeedVideoPlayer.stop]ped first so the
  ///      visible card always wins a codec.
  ///   2. Second error on the SAME open → the SoC genuinely can't hold this
  ///      many concurrent decoders: demote the session [_decoderBudget] (the
  ///      window shrinks, previous-slot first) and retry once more.
  ///   3. [_maxRetriesPerOpen] exhausted → give up quietly; the card keeps its
  ///      shimmer (never a black reveal) and the next reconcile — a swipe or
  ///      refresh — starts fresh.
  void _onPlayerError(_PooledPlayer pooled, String codeName) {
    if (_disposed || _appPaused) return;
    final index = pooled.servingIndex;
    if (index < 0 || !_isDecoderError(codeName)) return;
    final token = pooled.openToken;

    if (pooled.retriesThisOpen >= _maxRetriesPerOpen) {
      debugPrint(
        'FeedVideo: giving up on index $index after $codeName '
        '(budget $_decoderBudget)',
      );
      return;
    }
    pooled.retriesThisOpen++;

    // A repeat failure on the same open = real codec starvation, not a blip.
    if (pooled.retriesThisOpen >= 2) {
      _demoteBudget('$codeName at index $index');
    }

    // The visible card must always win a decoder.
    if (index == _currentIndex) _stopFarthestFrom(index);

    debugPrint(
      'FeedVideo: $codeName on index $index — '
      'retry ${pooled.retriesThisOpen}/$_maxRetriesPerOpen '
      '(budget $_decoderBudget)',
    );

    Timer(_errorRetryDelay, () {
      if (_disposed ||
          _appPaused ||
          pooled.openToken != token ||
          pooled.servingIndex != index ||
          !_inWindow(index)) {
        return; // reassigned / released / demoted out of the window meanwhile
      }
      _armReveal(pooled, index, token);
      unawaited(
        _setupAndOpen(
          pooled,
          index,
          token,
          playWhenReady: index == _currentIndex && !_settling,
        ),
      );
    });
  }

  /// Frees the codec of the pooled player serving the index FARTHEST from
  /// [index] (never [index] itself): stop() releases the decoder but keeps the
  /// player + surface for reassignment. Its card returns to shimmer until a
  /// later reconcile re-serves it — the price of guaranteeing the current card
  /// renders on codec-starved SoCs.
  void _stopFarthestFrom(int index) {
    _PooledPlayer? victim;
    var best = 0;
    for (final p in _pool_) {
      if (p.servingIndex < 0 || p.servingIndex == index) continue;
      final d = (p.servingIndex - index).abs();
      if (d > best) {
        best = d;
        victim = p;
      }
    }
    if (victim == null) return;
    debugPrint(
      'FeedVideo: freeing decoder of neighbour index ${victim.servingIndex} '
      'for index $index',
    );
    victim.servingIndex = -1;
    victim.openToken++; // abandon its in-flight setup/reveal
    unawaited(victim.handle.stop());
    notifyListeners();
  }

  /// Shrinks the session decoder budget by one (floor 1 — the current card).
  /// Sticky for the session via the static [_decoderBudget]; reconciles so
  /// now-out-of-window players are freed and stopped immediately. Returns
  /// whether the budget actually changed (false at the floor) so callers can
  /// avoid acting on a no-op.
  bool _demoteBudget(String reason) {
    if (_decoderBudget <= 1) return false;
    _decoderBudget--;
    debugPrint(
      'FeedVideo: decoder budget demoted to $_decoderBudget ($reason)',
    );
    _reconcile();
    return true;
  }

  /// Native decoder report for [pooled]'s current open (see
  /// [FeedVideoPlayer.onDecoder]). A SOFTWARE decoder means ExoPlayer's
  /// decoder-fallback quietly downgraded because the SoC is out of concurrent
  /// hardware sessions — no [_onPlayerError] ever fires for this. Verified
  /// on-device 2026-07-06 (SD695): 3 pooled players vs a ~2-session hw budget
  /// left slots permanently on `c2.android.avc.decoder`, which costs
  /// battery/thermal AND renders gralloc stride padding as the green edge
  /// strip (flutter/flutter#174026). Policy:
  ///   - demote the session budget once per open (the shrunken window frees a
  ///     hw session; capable devices never report software, never demote);
  ///   - sw fallback alone never demotes below 2 (field data, SD695: fallback
  ///     is an occasional lottery loss even when the full window fits — and
  ///     since 128/32-aligned content renders CLEAN on the sw path, a
  ///     sw-decoded neighbour costs only battery, while budget 1 costs
  ///     preloading: every swipe shimmers. Real decoder ERRORS
  ///     ([_onPlayerError]) can still take the budget to 1);
  ///   - if the VISIBLE card is the one that landed on software, re-open it
  ///     after the demote so it re-initializes onto the freed hw decoder now
  ///     rather than on the next swipe. Only when the demote actually changed
  ///     the budget — a sw-only device (no hw h264 at all) settles at the
  ///     floor, no re-open loop.
  void _onDecoderReported(_PooledPlayer pooled, String name, bool isSoftware) {
    if (_disposed || _appPaused || !isSoftware) return;
    final index = pooled.servingIndex;
    if (index < 0 || pooled.swFallbackHandled) return;
    pooled.swFallbackHandled = true;

    if (_decoderBudget <= 2) {
      debugPrint(
        'FeedVideo: software decoder $name on index $index — tolerated '
        '(budget $_decoderBudget, sw-fallback floor is 2)',
      );
      return;
    }
    final demoted = _demoteBudget('software decoder $name at index $index');
    if (!demoted || index != _currentIndex) return;

    final token = pooled.openToken;
    Timer(_errorRetryDelay, () {
      if (_disposed ||
          _appPaused ||
          pooled.openToken != token ||
          pooled.servingIndex != index ||
          !_inWindow(index)) {
        return; // reassigned / released meanwhile
      }
      _armReveal(pooled, index, token);
      unawaited(
        _setupAndOpen(
          pooled,
          index,
          token,
          playWhenReady: index == _currentIndex && !_settling,
        ),
      );
    });
  }

  void _pauseAll() {
    for (final pooled in _pool_) {
      unawaited(pooled.handle.pause());
    }
  }

  // ─── App lifecycle ───────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
        _appPaused = true;
        _settleTimer?.cancel();
        _pauseAll();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Off-screen (e.g. the OEM live-wallpaper chooser opened over us).
        // Dispose every player so the chooser / our service can claim a decoder.
        _appPaused = true;
        unawaited(releaseDecoders());
      case AppLifecycleState.detached:
        _appPaused = true;
      case AppLifecycleState.resumed:
        _appPaused = false;
        // Clear any stale settling state (e.g. backgrounded mid-fling) so the
        // current card hands out its slot again.
        _settling = false;
        _reconcile();
    }
  }

  // ─── Dispose ─────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    // Do NOT dispose _prefetch: it is the shared app-scoped instance
    // (wallpaperPrefetchServiceProvider) and outlives this controller so a
    // remount keeps using the same disk cache + in-flight queue. The provider
    // disposes it.
    WidgetsBinding.instance.removeObserver(this);
    final players = _pool_.toList();
    _pool_.clear();
    for (final p in players) {
      unawaited(p.dispose());
    }
    unawaited(_pool.dispose());
    super.dispose();
  }
}

/// A proxy `ValueListenable<bool>` the splash gate can subscribe to
/// synchronously while the backing native player is still being created
/// asynchronously. Once [bind] is called it mirrors the real first-frame
/// notifier; [detach] resolves it to false if creation failed.
class _FirstFrameProxy extends ChangeNotifier implements ValueListenable<bool> {
  bool _value = false;
  ValueListenable<bool>? _source;
  VoidCallback? _listener;

  @override
  bool get value => _value;

  void bind(ValueListenable<bool> source) {
    _source = source;
    void listener() {
      _value = source.value;
      notifyListeners();
    }

    _listener = listener;
    source.addListener(listener);
    // Sync current value immediately (it may already be true).
    if (source.value != _value) {
      _value = source.value;
      notifyListeners();
    }
  }

  void detach() {
    final s = _source;
    final l = _listener;
    if (s != null && l != null) s.removeListener(l);
    _source = null;
    _listener = null;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
